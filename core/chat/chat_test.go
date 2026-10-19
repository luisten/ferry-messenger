package chat

// The engine on P0's captures (testdata/ig_*.json, docs/PLAN-core.md P0): Instagram's threads, messages and deltas
// become the rooms and events the apps show, one rule per test (the port of the app's IGAdapterTests). Tests that
// the app's own halves need also write the engine's output as golden files (FerryTests/Fixtures/engine_*.json),
// which FerryTests' EngineTests read: `go test ./chat -update` rewrites them, and their diffs are reviewed like code.

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "rewrite the golden files in FerryTests/Fixtures")

const tamo, kivo = "17841400000000301", "17841400000000302"

func fixture(t *testing.T, name string, v any) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "testdata", name+".json"))
	if err == nil {
		err = json.Unmarshal(b, v)
	}
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
}

// golden compares the engine's output with FerryTests/Fixtures/engine_<name>.json, or writes it with -update.
func golden(t *testing.T, name string, v any) {
	t.Helper()
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", " ")
	if err := enc.Encode(v); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join("..", "..", "FerryTests", "Fixtures", "engine_"+name+".json")
	if *update {
		if err := os.WriteFile(path, b.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	if want, err := os.ReadFile(path); err != nil || !bytes.Equal(want, b.Bytes()) {
		t.Errorf("%s isn't what the engine makes now: run `go test ./chat -update` and review the diff", path)
	}
}

type loginCapture struct {
	Account string          `json:"account"`
	Viewer  json.RawMessage `json:"viewer"`
	Mailbox json.RawMessage `json:"mailbox"`
}

type viewer struct {
	Username     string `json:"username"`
	FullName     string `json:"full_name"`
	ProfilePic   string `json:"profile_pic_url"`
	Professional bool   `json:"is_professional_account"`
}

func login(t *testing.T, name string) (loginCapture, viewer) {
	var l loginCapture
	var v viewer
	fixture(t, name, &l)
	if err := json.Unmarshal(l.Viewer, &v); err != nil {
		t.Fatal(err)
	}
	return l, v
}

// dm is the dummies' DM as the mailbox listed it.
func dm(t *testing.T, name string) Thread {
	l, _ := login(t, name)
	threads, _, err := Mailbox(l.Mailbox)
	if err != nil || len(threads) == 0 {
		t.Fatalf("%s: no thread (%v)", name, err)
	}
	return threads[0]
}

// thread is the DM after P0's script, as `GetThread` returned it (tamoveska's side).
func thread(t *testing.T) Thread {
	var raw json.RawMessage
	fixture(t, "ig_thread_tamo", &raw)
	th, err := ReadThread(raw)
	if err != nil || th == nil {
		t.Fatal(err)
	}
	return *th
}

type captured struct {
	Kind   string          `json:"kind"`
	Delta  json.RawMessage `json:"delta"`
	Thread string          `json:"thread"`
	Typing struct {
		SenderID       int64 `json:"sender_id"`
		ActivityStatus int   `json:"activity_status"`
	} `json:"typing"`
}

// deltas is P0's run as tamoveska's socket delivered it.
func deltas(t *testing.T) []json.RawMessage {
	var events []captured
	fixture(t, "ig_events_tamo", &events)
	var out []json.RawMessage
	for _, e := range events {
		if e.Kind == "Delta" {
			out = append(out, e.Delta)
		}
	}
	return out
}

func typename(raw json.RawMessage) string {
	var d struct {
		Typename string `json:"__typename"`
	}
	_ = json.Unmarshal(raw, &d)
	return d.Typename
}

func firstDelta(t *testing.T, kind string) json.RawMessage {
	for _, d := range deltas(t) {
		if typename(d) == kind {
			return d
		}
	}
	t.Fatalf("no %s", kind)
	return nil
}

func lastDelta(t *testing.T, kind string) json.RawMessage {
	all := deltas(t)
	for _, d := range slices.Backward(all) {
		if typename(d) == kind {
			return d
		}
	}
	t.Fatalf("no %s", kind)
	return nil
}

// with is a delta with some fields changed.
func with(t *testing.T, raw json.RawMessage, change func(map[string]any)) json.RawMessage {
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	change(m)
	b, _ := json.Marshal(m)
	return b
}

func deltaMessage(t *testing.T, raw json.RawMessage) Message {
	var d delta
	if err := json.Unmarshal(raw, &d); err != nil || d.Message == nil {
		t.Fatalf("no message: %v", err)
	}
	return *d.Message
}

func chats(account string, v viewer) *Chats {
	c := New(account)
	c.Name, c.Avatar = v.FullName, v.ProfilePic
	return c
}

func stateOf(env Envelope, typ string) map[string]any {
	for _, e := range env.Update.State.Events {
		if e.Type == typ {
			return e.Content
		}
	}
	return nil
}

func channel(env Envelope) map[string]any { return obj(stateOf(env, "m.bridge")["channel"]) }

func bases(events []Event) []Event {
	var out []Event
	for _, e := range events {
		if e.isBase() {
			out = append(out, e)
		}
	}
	return out
}

func updates(envs []Envelope) []JoinedRoom {
	var out []JoinedRoom
	for _, e := range envs {
		if e.Update != nil {
			out = append(out, *e.Update)
		}
	}
	return out
}

func TestLoginAndAccount(t *testing.T) {
	for _, name := range []string{"tamo", "kivo"} {
		l, v := login(t, "ig_login_"+name)
		threads, next, err := Mailbox(l.Mailbox)
		if err != nil {
			t.Fatal(err)
		}
		c := chats(l.Account, v)
		var rooms []Envelope
		for _, th := range threads {
			rooms = append(rooms, c.Thread(th))
		}
		golden(t, "login_"+name, map[string]any{"login": map[string]any{"account": l.Account, "viewer": l.Viewer, "next": next}, "rooms": rooms})
	}
	l, v := login(t, "ig_login_tamo")
	if l.Account != tamo || v.Username != "tamoveska" || v.Professional {
		t.Errorf("tamoveska: %s %+v", l.Account, v)
	}
	l, v = login(t, "ig_login_kivo")
	if l.Account != kivo || v.Username != "kivostudio" || v.FullName != "Kivo Studio" || !v.Professional {
		t.Errorf("kivostudio: %s %+v", l.Account, v)
	}
}

// One Instagram thread seen by both dummies is two chats, each in its own account's scope (as `split_portals`).
func TestTheDummiesDMIsOneChatPerAccount(t *testing.T) {
	_, tv := login(t, "ig_login_tamo")
	_, kv := login(t, "ig_login_kivo")
	a := chats(tamo, tv).Thread(dm(t, "ig_login_tamo"))
	b := chats(kivo, kv).Thread(dm(t, "ig_login_kivo"))
	if a.Room == b.Room || a.Room != RoomID(tamo, "1700000000000301") {
		t.Errorf("rooms %s, %s", a.Room, b.Room)
	}
	if channel(a)["fi.mau.receiver"] != tamo || channel(b)["fi.mau.receiver"] != kivo {
		t.Error("receivers")
	}
	if stateOf(a, "m.bridge")["com.beeper.room_type"] != "dm" || channel(a)["id"] != kivo { // the other person, our other account
		t.Errorf("DM: %v", stateOf(a, "m.bridge"))
	}
	if stateOf(a, "m.room.name")["name"] != "Kivo Studio" || stateOf(b, "m.room.name")["name"] != "Tamo Veska" {
		t.Error("names")
	}
	if has(channel(a), inboxFolderKey) || has(channel(a), "com.beeper.message_request") {
		t.Errorf("not Chats: %v", channel(a))
	}
}

// Names and @handles come with the thread: no profile lookups, no localparts.
func TestPeopleCarryNamesAndHandles(t *testing.T) {
	env := chats(tamo, viewer{}).Thread(dm(t, "ig_login_tamo"))
	if p := env.Profiles[User(kivo)]; p.Handle != "kivostudio" || p.Name != "Kivo Studio" {
		t.Errorf("profile %+v", p)
	}
	if url, _ := stateOf(env, "m.room.avatar")["url"].(string); !strings.HasPrefix(url, "https://scontent.example.invalid/") {
		t.Errorf("avatar %q", url) // the contact's picture, a CDN link
	}
	var members []string
	for _, e := range env.Update.State.Events {
		if e.Type == "m.room.member" {
			members = append(members, *e.StateKey)
		}
	}
	if !slices.Equal(members, []string{Me, User(kivo)}) {
		t.Errorf("members %v", members)
	}
}

// Instagram's folders (P0): `system_folder` PENDING/SPAM is a request, `folder` GENERAL is General.
func TestRequestsAndGeneralComeFromTheFolders(t *testing.T) {
	th := dm(t, "ig_login_kivo")
	if th.Folder != "PRIMARY" || has(channel(New(kivo).Thread(th)), inboxFolderKey) {
		t.Errorf("Primary: %q", th.Folder)
	}
	th.Folder = "GENERAL"
	general := New(kivo).Thread(th)
	th.Folder, th.SystemFolder = "PRIMARY", "PENDING"
	pending := New(kivo).Thread(th)
	th.SystemFolder = "SPAM"
	spam := New(kivo).Thread(th)
	if channel(general)[inboxFolderKey] != "GENERAL" || channel(pending)["com.beeper.message_request"] != true ||
		channel(spam)["com.beeper.message_request"] != true || has(channel(general), "com.beeper.message_request") {
		t.Error("folders")
	}
	golden(t, "folders_kivo", map[string]Envelope{"general": general, "pending": pending, "spam": spam})
}

// `GetThread` answers with no tab (P0's thread capture): a re-read of a General chat keeps it in General.
func TestARereadKeepsTheTab(t *testing.T) {
	reread := thread(t)
	if reread.Folder != "" {
		t.Fatalf("folder %q", reread.Folder)
	}
	listed := dm(t, "ig_login_tamo")
	listed.Folder = "GENERAL"
	c := New(tamo)
	c.Thread(listed)
	if channel(c.Thread(reread))[inboxFolderKey] != "GENERAL" {
		t.Error("the re-read moved it to Chats")
	}
	if has(channel(New(tamo).Thread(reread)), inboxFolderKey) { // a new thread: Instagram's default
		t.Error("a new thread is General")
	}
	listed.Folder = "PRIMARY" // a listing always wins
	if has(channel(c.Thread(listed)), inboxFolderKey) {
		t.Error("the listing didn't win")
	}
}

// Unread: the newest message is someone else's and newer than our read watermark, or the chat is marked unread.
func TestUnreadIsAnIncomingMessagePastOurWatermark(t *testing.T) {
	th := thread(t)
	if New(tamo).Thread(th).Update.UnreadNotifications.NotificationCount != 0 { // the newest is our own
		t.Error("tamoveska: unread")
	}
	if New(kivo).Thread(th).Update.UnreadNotifications.NotificationCount != 1 { // kivostudio's watermark is older
		t.Error("kivostudio: read")
	}
	th.MarkedAsUnread = true
	if New(tamo).Thread(th).Update.UnreadNotifications.NotificationCount != 1 {
		t.Error("marked unread: read")
	}
}

func TestTheThreadReducesToItsMessages(t *testing.T) {
	env := New(tamo).Thread(thread(t))
	golden(t, "thread_tamo", map[string]Envelope{"tamo": env, "kivo": New(kivo).Thread(thread(t))})
	events := env.Update.Timeline.Events
	messages := bases(events)
	if len(messages) != 17 {
		t.Fatalf("%d messages", len(messages))
	}
	back := messages[16]
	if back.Content["body"] != "P0 capture: back" || back.Sender != Me || has(back.Content, "m.relates_to") {
		// Instagram sends `replied_to_message_id: ""` on every message that isn't a reply
		t.Errorf("back: %v", back)
	}
	edited := messages[15]
	edits := slices.IndexFunc(events, func(e Event) bool { return e.replaces() == edited.EventID })
	reaction := slices.IndexFunc(events, func(e Event) bool { return e.Type == "m.reaction" })
	if edited.Sender != User(kivo) || edits < 0 || reaction < 0 || events[reaction].Sender != Me ||
		obj(events[reaction].Content["m.relates_to"])["key"] != "😂" {
		t.Errorf("the edited reply: %v", edited)
	}
	if len(env.Related) != 1 || env.Related[0].Unsigned.RedactedBecause == nil { // its target was unsent: no quote
		t.Errorf("related %v", env.Related)
	}
	kinds := map[string]bool{}
	for _, m := range messages {
		kinds[m.Content["msgtype"].(string)] = true
	}
	if !kinds["m.audio"] || !kinds["m.video"] || !kinds["m.notice"] {
		t.Errorf("kinds %v", kinds)
	}
}

// "Reacted 😂 to your message" is a log entry for a reaction the message already shows: no row, no unread.
func TestReactionLogEntriesAreNotRows(t *testing.T) {
	th := thread(t)
	log := th.SlideMessages.Edges[0]
	log.Node.ID, log.Node.ContentType, log.Node.SenderFBID, log.Node.TimestampMS = "mid.reactionlog", "REACTION_LOG_XMAT", kivo, "1792172900000"
	th.SlideMessages.Edges = slices.Insert(slices.Clone(th.SlideMessages.Edges), 0, log) // newest first
	env := New(tamo).Thread(th)
	if slices.ContainsFunc(env.Update.Timeline.Events, func(e Event) bool { return e.EventID == "mid.reactionlog" }) {
		t.Error("the log entry is a row")
	}
	if env.Update.UnreadNotifications.NotificationCount != 0 {
		t.Error("unread")
	}
}

// Our own messages carry the offline threading ID we sent with, which clears the local echo.
func TestOwnMessagesCarryTheirOfflineThreadingID(t *testing.T) {
	messages := bases(New(tamo).Thread(thread(t)).Update.Timeline.Events)
	if back := messages[len(messages)-1]; back.Unsigned == nil || back.Unsigned.TransactionID == "" {
		t.Error("our last message has no transaction ID")
	}
	for _, m := range messages {
		if m.Sender != Me && m.Unsigned != nil {
			t.Errorf("theirs has one: %v", m)
		}
	}
}

// P0's send answer names the message, which the local echo's "sent" state keeps (`AppModel.deliver`).
func TestSendAnswerNamesTheMessage(t *testing.T) {
	var responses struct {
		Send json.RawMessage `json:"send"`
	}
	fixture(t, "ig_responses", &responses)
	if id := SentID(responses.Send); id != "mid.$cAAAy8NQIKzyndxflxGhRdKarJRAq" {
		t.Errorf("id %q", id)
	}
}

func TestOlderPagesPrependUntilTheStart(t *testing.T) {
	c := New(tamo)
	id := c.Thread(thread(t)).Room
	_, cursor, err := c.Older(id)
	if err != nil || cursor == "" || cursor == StartToken {
		t.Fatalf("cursor %q (%v)", cursor, err)
	}
	oldest := bases(c.rooms[id].events)[0].OriginServerTS
	var raw json.RawMessage
	fixture(t, "ig_older_tamo", &raw)
	older, err := OlderThread(raw)
	if err != nil {
		t.Fatal(err)
	}
	p := c.Prepend(id, cursor, older)
	golden(t, "older_tamo", map[string]MessagesPage{"page": p})
	if n := len(bases(c.rooms[id].events)); n <= 17 || bases(c.rooms[id].events)[0].OriginServerTS >= oldest {
		t.Errorf("%d messages after the page", n)
	}
	if p.End != "" || c.rooms[id].prevBatch != "" { // that page is the rest of the dummies' DM: nothing older
		t.Errorf("end %q", p.End)
	}
	if n := len(p.Chunk); n == 0 || p.Chunk[0].OriginServerTS < p.Chunk[n-1].OriginServerTS {
		t.Error("the chunk isn't newest first")
	}

	last := thread(t)
	last.SlideMessages.PageInfo.HasNextPage = false
	if New(tamo).Thread(last).Update.Timeline.PrevBatch != StartToken { // nothing older: the chat's start
		t.Error("no start token")
	}
}

// A GIF from the other dummy (live, after P7: Instagram turned an uploaded GIF into one): its WebP, marked so the
// card plays it; this one came with no still preview.
func TestAGIFIsAnAnimatedImage(t *testing.T) {
	var e captured
	fixture(t, "ig_event_gif_kivo", &e)
	c := New(kivo)
	c.Thread(dm(t, "ig_login_kivo"))
	out, reread := c.Delta(e.Delta)
	if reread != "" || len(updates(out)) != 1 {
		t.Fatalf("%v, reread %q", out, reread)
	}
	live := updates(out)[0].Timeline.Events
	info := obj(live[0].Content["info"])
	if live[0].Content["msgtype"] != "m.image" || live[0].Content["url"] != "https://scontent.example.invalid/v/g001.webp" ||
		info["mimetype"] != "image/webp" || info["w"] != 240.0 || info["h"] != 240.0 || has(info, "thumbnail_url") || info["fi.mau.gif"] != true {
		t.Errorf("GIF %v", live[0].Content)
	}

	// The mailbox's copy (live): no media, still a GIF, so the inbox says so; opening the chat reads the rest.
	bare := deltaMessage(t, e.Delta)
	bare.Content = map[string]any{"animated_media": nil}
	mailbox := messageEvents(bare, kivo)
	if has(mailbox[0].Content, "url") || obj(mailbox[0].Content["info"])["fi.mau.gif"] != true {
		t.Errorf("bare GIF %v", mailbox[0].Content)
	}
	golden(t, "event_gif_kivo", map[string][]Event{"live": live, "mailbox": mailbox})
}

// Three photos sent at once from the Instagram app (live 2026-10-18): one message with every photo, in order, so it
// keeps one menu, one row of reactions and one unsend. Ferry showed only the first.
func TestPhotosSentTogetherAreOneMessageWithAll(t *testing.T) {
	var photos Message
	fixture(t, "ig_message_photos_tamo", &photos)
	thread := messageEvents(photos, tamo)
	album := arr(thread[0].Content[albumKey])
	if len(thread) != 1 || thread[0].Content["url"] != "https://scontent.example.invalid/v/f040.jpg" || len(album) != 3 {
		t.Fatalf("photos %v", thread)
	}
	for i, item := range album {
		if want := "https://scontent.example.invalid/v/f0" + strconv.Itoa(40+2*i) + ".jpg"; obj(item)["url"] != want || obj(item)["msgtype"] != "m.image" {
			t.Errorf("item %d %v", i, item)
		}
	}

	// The mailbox's copy (live): no attachments, still a photo, and no album to stack.
	bare := photos
	bare.Content = map[string]any{"attachments": nil}
	mailbox := messageEvents(bare, tamo)
	if mailbox[0].Content["msgtype"] != "m.image" || has(mailbox[0].Content, albumKey) {
		t.Errorf("bare %v", mailbox[0].Content)
	}

	// Photos and videos together (upstream's `ordered_photo_video_attachments`, not seen live): each item says which.
	mixed := photos
	mixed.ContentType = "MULTIMEDIA" // a guess; the content's field decides
	mixed.Content = map[string]any{"ordered_photo_video_attachments": []any{
		arr(photos.Content["attachments"])[0],
		map[string]any{"__typename": "XFBSlideVideoAttachment", "attachment_cdn_url": "https://scontent.example.invalid/v/f046.mp4",
			"preview_cdn_url": "https://scontent.example.invalid/v/f047.jpg", "preview_width": 360.0, "preview_height": 640.0},
	}}
	both := messageEvents(mixed, tamo)
	if items := arr(both[0].Content[albumKey]); len(items) != 2 || obj(items[1])["msgtype"] != "m.video" ||
		obj(obj(items[1])["info"])["thumbnail_url"] != "https://scontent.example.invalid/v/f047.jpg" {
		t.Errorf("mixed %v", both[0].Content)
	}
	golden(t, "message_photos_tamo", map[string][]Event{"thread": thread, "mailbox": mailbox, "mixed": both})
}

// Instagram's own lines (upstream's `SlideMessageAdminText`, `text_fragments`; none captured: a group needs three
// people) and content the app doesn't know are lines across the thread, never a bubble saying "not supported".
func TestChatEventsAndUnknownContentAreLines(t *testing.T) {
	message := func(id, sender, typ string, content map[string]any, ms int64) []Event {
		body, _ := content["text_body"].(string)
		return messageEvents(Message{ID: id, SenderFBID: sender, ContentType: typ, TimestampMS: strconv.FormatInt(ms, 10),
			Content: content, TextBody: body}, tamo)
	}
	renamed := map[string]any{"text_fragments": []any{
		map[string]any{"plaintext": "Kivo", "link_fragment": map[string]any{"uri": "instagram://user?username=kivostudio"}},
		map[string]any{"plaintext": " named the group Weekend", "link_fragment": nil},
	}}
	events := slices.Concat(
		message("mid.1", kivo, "TEXT", map[string]any{"text_body": "hi"}, 1_000),
		message("mid.1b", kivo, "TEXT", map[string]any{"text_body": "there"}, 1_100),
		message("mid.2", kivo, "ACTION_LOG", renamed, 2_000), // a made-up type: the content's fields decide
		message("mid.3", kivo, "SOMETHING_NEW", map[string]any{"__typename": "SlideMessageSomethingNewContent"}, 3_000),
		message("mid.4", kivo, "POLL_XMAT", map[string]any{"__typename": "SlideMessagePollContent"}, 4_000), // a guess at a poll
		message("mid.5", tamo, "TEXT", map[string]any{"text_body": "mine"}, 5_000),
		message("mid.6", tamo, "ACTION_LOG", map[string]any{"text_fragments": []any{map[string]any{"plaintext": "You left the group"}}}, 6_000),
		message("mid.7", tamo, "ACTION_LOG", map[string]any{"text_fragments": []any{}}, 7_000), // nothing to say: can't show it
	)
	var got []string
	for _, e := range events {
		got = append(got, nonEmpty(func() string { s, _ := e.Content[unsupportedKey].(string); return s }(), e.Content["msgtype"].(string)))
	}
	want := []string{"m.text", "m.text", "m.notice", "a message Ferry can't show", "a poll", "m.text", "m.notice", "a message Ferry can't show"}
	if !slices.Equal(got, want) || events[2].Content["body"] != "Kivo named the group Weekend" || events[2].Content[eventKey] != true {
		t.Errorf("kinds %v, %v", got, events[2].Content)
	}
	golden(t, "chat_events", map[string][]Event{"events": events})
}

func TestLiveMessagesReadsAndReceipts(t *testing.T) {
	c := New(tamo)
	snap := c.Thread(thread(t))
	id := snap.Room
	r := c.rooms[id]
	all := []Envelope{snap}
	step := func(raw json.RawMessage) []Envelope {
		out, reread := c.Delta(raw)
		if reread != "" {
			t.Fatalf("%s re-reads", typename(raw))
		}
		all = append(all, out...)
		return out
	}
	incoming := firstDelta(t, "SlideUQPPNewMessage")
	step(incoming)
	if r.unread != 1 || r.lastMessage().EventID != deltaMessage(t, incoming).ID {
		t.Error("their message isn't unread and newest")
	}
	step(firstDelta(t, "SlideUQPPMarkRead"))
	if r.unread != 0 { // read here or on another device
		t.Error("still unread")
	}
	own := lastDelta(t, "SlideUQPPNewMessage")
	j := updates(step(own))[0]
	if j.Timeline.Events[0].Unsigned.TransactionID != deltaMessage(t, own).OfflineThreadingID || j.UnreadNotifications.NotificationCount != 0 {
		t.Errorf("our message %v", j)
	}
	// kivostudio read it on another device three minutes later: "Seen" on our message.
	seen := updates(step(lastDelta(t, "SlideUQPPReadReceipt")))
	if len(seen) != 1 || obj(obj(seen[0].Ephemeral.Events[0].Content[deltaMessage(t, own).ID])["m.read"])[User(kivo)] == nil {
		t.Errorf("seen %v", seen)
	}
	golden(t, "live_tamo", map[string][]Envelope{"live": all})
}

// P0's run replayed live on tamoveska's chat as the mailbox had it before: kivostudio's text and its reply (with the
// quoted message), our ❤️ then 😂, the edit, the unsend, our "Seen", our reply and their "Seen".
func TestP0RunReplaysLive(t *testing.T) {
	c := New(tamo)
	all := []Envelope{c.Thread(dm(t, "ig_login_tamo"))}
	id := all[0].Room
	var sent []string
	for _, d := range deltas(t) {
		if typename(d) == "SlideUQPPNewMessage" {
			sent = append(sent, deltaMessage(t, d).ID)
		}
		out, reread := c.Delta(d)
		if reread != "" { // both reaction deletes name the ❤️ added in this run
			t.Fatalf("%s re-reads", typename(d))
		}
		all = append(all, out...)
	}
	golden(t, "events_tamo", map[string][]Envelope{"replay": all})
	r := c.rooms[id]
	if len(sent) != 3 || !slices.ContainsFunc(r.events, func(e Event) bool { return e.Type == "m.room.redaction" && e.Content["redacts"] == sent[0] }) {
		t.Error("the first message isn't unsent")
	}
	reply := r.event(sent[1])
	if reply == nil || r.currentContent(reply)["body"] != "P0 capture: a reply, edited" {
		t.Errorf("the reply %v", reply)
	}
	related := slices.IndexFunc(all, func(e Envelope) bool { return len(e.Related) > 0 && e.Related[0].EventID == sent[0] })
	if related < 0 || all[related].Related[0].Unsigned != nil { // the quoted message came with the reply
		t.Error("no quote")
	}
	if r.lastMessage().EventID != sent[2] || r.unread != 0 {
		t.Error("ours isn't last, or the chat is unread")
	}
	// Our "Seen" (`SlideUQPPMarkRead`) moved our own m.read to their reply: where a "New messages" line would start.
	if r.readUpTo != 1_792_172_798_127 {
		t.Errorf("our m.read at %d", r.readUpTo)
	}
}

// Opening a chat sends "Seen" and re-reads the thread at once. kivostudio's watermark in this capture sits before
// tamoveska's "back", so for kivostudio this read says unread: the dot came back after reading (mostly in groups).
// How far this engine knows we've read (`MarkRead` moves our m.read) keeps it read; marked unread still wins.
func TestAReadThatCrossedOurSeenKeepsTheChatRead(t *testing.T) {
	th := thread(t)
	back := th.SlideMessages.Edges[0].Node
	c := New(kivo)
	stale := c.Thread(th)
	if stale.Update.UnreadNotifications.NotificationCount != 1 {
		t.Fatal("read")
	}
	// Our own watermark is our m.read, on the newest message at or before it (kivostudio's "On-device spike test").
	if c.rooms[stale.Room].readUpTo != 1_792_115_019_051 {
		t.Errorf("our m.read at %d", c.rooms[stale.Room].readUpTo)
	}
	out, long, ms, err := c.MarkRead(stale.Room, back.ID)
	if err != nil || long != th.ThreadID || ms != back.ms() || updates(out)[0].UnreadNotifications.NotificationCount != 0 {
		t.Fatalf("mark read: %v %q %d %v", out, long, ms, err)
	}
	if _, long, _, _ := c.MarkRead(stale.Room, back.ID); long != "" {
		t.Error("a second Seen for the same message")
	}
	if c.Thread(th).Update.UnreadNotifications.NotificationCount != 0 {
		t.Error("the re-read says unread")
	}
	th.MarkedAsUnread = true
	if c.Thread(th).Update.UnreadNotifications.NotificationCount != 1 {
		t.Error("marked unread lost")
	}
	if _, _, _, err := c.MarkRead("!debug-fixture", back.ID); err != ErrUnknownRoom {
		t.Error("a room the engine didn't make")
	}
}

// A reply and an emoji reaction to tamoveska's story, sent by kivostudio from the Instagram app (live 2026-10-19,
// `ig_story_replies_kivo`: the thread's copies and both sides' mailbox copies). The thread's copy is the story plus
// what was sent (`xma_text_body`) and Instagram's line about it; Ferry showed only the story. The mailbox's copy has
// `xma: null` and the text in `text_body`, and its snippet already says "You: ", which the inbox said again.
func TestStoryRepliesAndReactionsKeepWhatWasSent(t *testing.T) {
	var copies struct {
		Thread          []Message `json:"thread"`
		MailboxSender   []Message `json:"mailbox_sender"`
		MailboxReceiver []Message `json:"mailbox_receiver"`
	}
	fixture(t, "ig_story_replies_kivo", &copies)
	events := func(messages []Message, account string) []Event {
		var out []Event
		for _, m := range messages {
			e := messageEvents(m, account)
			if len(e) != 1 {
				t.Fatalf("%d events for one message", len(e))
			}
			out = append(out, e...)
		}
		return out
	}
	thread := events(copies.Thread, kivo)
	for i, want := range []string{"😢", "Droopy"} {
		c := thread[i].Content
		if c[shareTextKey] != want || !has(c, "com.beeper.unresolved_media") || !strings.HasPrefix(c["formatted_body"].(string), "<blockquote>") {
			t.Errorf("story %d: %v", i, c)
		}
	}
	if !strings.Contains(thread[1].Content["formatted_body"].(string), "<strong>tamoveska</strong>") {
		t.Errorf("author: %v", thread[1].Content["formatted_body"])
	}
	sender, receiver := events(copies.MailboxSender, kivo), events(copies.MailboxReceiver, tamo)
	if sender[1].Content["body"] != "Droopy" || sender[1].Content["msgtype"] != "m.text" || receiver[0].Content["body"] != "😢" {
		t.Errorf("mailbox %v %v", sender, receiver)
	}

	// Any other share's mailbox copy (`xma: null`, no text) is Instagram's snippet, which names the sender itself.
	bare := copies.MailboxSender[0]
	bare.TextBody, bare.IGDSnippet = "", "You sent an attachment."
	bareEvents := messageEvents(bare, kivo)
	if bareEvents[0].Content["body"] != "You sent an attachment." || bareEvents[0].Content[eventKey] != true {
		t.Errorf("bare %v", bareEvents[0].Content)
	}

	// An expired story (not captured): its notice, then what was sent.
	expired := messageEvents(Message{ID: "mid.expired", SenderFBID: kivo, ContentType: "MONTAGE_SHARE_XMA", TimestampMS: "1792386924500",
		Content: map[string]any{"xma": map[string]any{"title_text": "Story unavailable"}, "xma_text_body": "Droopy"}}, kivo)
	if c := expired[0].Content; c["msgtype"] != "m.notice" || c["body"] != "Story unavailable" || c[shareTextKey] != "Droopy" {
		t.Errorf("expired %v", c)
	}
	golden(t, "story_replies_kivo", map[string][]Event{"thread": thread, "mailbox_sender": sender, "mailbox_receiver": receiver,
		"bare": bareEvents, "expired": expired})
}

// Their newest message makes the chat unread; when they unsend it and ours is newest again, it's read.
func TestUnsendingTheUnreadMessageReadsTheChat(t *testing.T) {
	c := New(tamo)
	id := c.Thread(thread(t)).Room
	incoming := firstDelta(t, "SlideUQPPNewMessage")
	c.Delta(incoming)
	if c.rooms[id].unread != 1 {
		t.Fatal("read")
	}
	unsend := with(t, firstDelta(t, "SlideUQPPDeleteMessage"), func(m map[string]any) { m["message_id"] = deltaMessage(t, incoming).ID })
	if _, reread := c.Delta(unsend); reread != "" || c.rooms[id].unread != 0 || c.rooms[id].lastMessage().Sender != Me {
		t.Error("still unread after the unsend")
	}
}

// Primary ↔ General on Instagram, live: the raw move deltas Ferry captured (spike S5) move the chat here.
func TestMovesBetweenPrimaryAndGeneral(t *testing.T) {
	c := New(kivo)
	id := c.Thread(dm(t, "ig_login_kivo")).Room
	var moves []json.RawMessage
	fixture(t, "deltas_s5_ig_move_thread", &moves)
	for i, want := range []bool{true, false} {
		if out, reread := c.Delta(moves[i]); reread != "" || len(out) != 1 || c.rooms[id].isGeneral() != want {
			t.Errorf("move %d: general %v", i, c.rooms[id].isGeneral())
		}
	}
}

// A request accepted, or a thread deleted, on another device.
func TestFolderChangesAndDeletesFromElsewhere(t *testing.T) {
	c := New(tamo)
	id := c.Thread(thread(t)).Room
	read := firstDelta(t, "SlideUQPPMarkRead")
	if _, reread := c.Delta(with(t, read, func(m map[string]any) { m["__typename"] = "SlideUQPPUpdateThreadFolder" })); reread != "1700000000000301" {
		t.Error("a folder change doesn't re-read")
	}
	out, _ := c.Delta(with(t, read, func(m map[string]any) { m["__typename"] = "SlideUQPPDeleteThread" }))
	if len(out) != 1 || out[0].Kind != "RoomRemoved" || out[0].Room != id || c.Has(id) {
		t.Errorf("delete %v", out)
	}
	// A message in a thread this engine doesn't have: a new chat, read in full.
	if _, reread := New(tamo).Delta(firstDelta(t, "SlideUQPPNewMessage")); reread != "1700000000000301" {
		t.Error("a new chat isn't read")
	}
}

// N1: a search result is a contact by FBID (someone we've never messaged gets the app's draft chat).
func TestSearchResults(t *testing.T) {
	contacts, err := Contacts([]byte(`{"xfb_combinedIGSearchQuery":{"search_messenger_contact_v2":[{"interop_messaging_user_fbid":"17841400000000999","username":"sample.person","full_name":"Sample Person","pk":"4200000999","profile_pic_url":"https://scontent.example.invalid/v/f099.jpg","is_verified":false},{"username":"no.fbid"}]}}`))
	if err != nil || len(contacts) != 1 {
		t.Fatalf("%v %v", contacts, err)
	}
	if c := contacts[0]; c.ID != "17841400000000999" || c.Name != "Sample Person" || !slices.Equal(c.Identifiers, []string{"instagram:sample.person"}) {
		t.Errorf("%+v", c)
	}
}

// Shares (Instagram's XMA, shaped like P0's raw captures, with fictional authors): the bridge's content shapes, so
// the cards read them as before.
func TestSharesBecomeTheBridgesShapes(t *testing.T) {
	message := func(xma map[string]any) Message {
		return Message{ID: "mid.share", ContentType: "MESSAGE_INLINE_SHARE", SenderFBID: kivo, TimestampMS: "1792172900000",
			Content: map[string]any{"xma": xma}}
	}
	preview := map[string]any{"url": "https://scontent.example.invalid/v/f101.jpg", "width": 1080.0, "height": 1920.0}
	reelXMA := map[string]any{"header_title_text": "sample.travels", "preview_image": preview,
		"target_url": "https://www.instagram.com/reel/DSampleRl01/", "target_id": "3400000000000000001"}
	reel := messageEvents(message(reelXMA), tamo)
	if c := reel[0].Content; c["msgtype"] != "m.video" || !has(c, "com.beeper.unresolved_media") || c["formatted_body"] != "<strong>sample.travels</strong>" ||
		obj(c["info"])["thumbnail_url"] != preview["url"] {
		t.Errorf("reel %v", c)
	}
	post := messageEvents(message(map[string]any{"header_title_text": "sample.photos", "preview_image": preview, "title_text": "Golden hour",
		"target_url": "https://www.instagram.com/p/DSamplePo01/", "target_id": "3400000000000000002"}), tamo)
	if c := post[0].Content; c["msgtype"] != "m.image" || c["url"] != preview["url"] || has(c, "com.beeper.unresolved_media") ||
		!strings.HasSuffix(c["formatted_body"].(string), "<p>Golden hour</p>") {
		t.Errorf("post %v", c)
	}
	link := messageEvents(message(map[string]any{"target_url": "https://example.com/article", "title_text": "An article", "preview_image": preview}), tamo)
	if p := obj(arr(link[0].Content["com.beeper.linkpreviews"])[0]); link[0].Content["msgtype"] != "m.text" || p["og:title"] != "An article" {
		t.Errorf("link %v", link[0].Content)
	}
	expired := messageEvents(message(map[string]any{"caption_body_text": "Story unavailable", "eyebrow_text": "Shared a story"}), tamo)
	if expired[0].Content["body"] != "Story unavailable" {
		t.Errorf("expired %v", expired[0].Content)
	}

	// "Load video": the hidden edit swaps the card to the reel itself.
	c := New(tamo)
	id := c.Thread(thread(t)).Room
	share, _ := json.Marshal(map[string]any{"__typename": "SlideUQPPNewMessage", "thread_fbid": "1700000000000301", "message": message(reelXMA)})
	c.Delta(share)
	target, targetID, err := c.Unresolved(id, "mid.share")
	if err != nil || target != "https://www.instagram.com/reel/DSampleRl01/" || targetID != "3400000000000000001" {
		t.Fatalf("%q %q %v", target, targetID, err)
	}
	out, err := c.Resolved(id, "mid.share", Resolved{URL: "https://scontent.example.invalid/v/f102.mp4", Video: true, Width: 720, Height: 1280, Duration: 12.5})
	if err != nil {
		t.Fatal(err)
	}
	resolved := updates(out)[0].Timeline.Events
	now := obj(resolved[0].Content["m.new_content"])
	if now["url"] != "https://scontent.example.invalid/v/f102.mp4" || obj(now["info"])["duration"] != 12_500.0 || has(now, "com.beeper.unresolved_media") ||
		resolved[0].Content["com.beeper.dont_render_edited"] != true || now["formatted_body"] != "<strong>sample.travels</strong>" {
		t.Errorf("resolved %v", resolved[0].Content)
	}
	if _, _, err := c.Unresolved(id, "mid.share"); err == nil {
		t.Error("loads again")
	}
	golden(t, "shares", map[string][]Event{"reel": reel, "post": post, "link": link, "expired": expired, "resolved": resolved})
}

// A delete for a reaction this window never saw added (one from before this launch) re-reads the thread.
func TestUnknownReactionDeleteRereadsTheThread(t *testing.T) {
	c := New(tamo)
	c.Thread(thread(t))
	unknown := with(t, firstDelta(t, "SlideUQPPDeleteReaction"), func(m map[string]any) { obj(m["reaction"])["log_message_id"] = "mid.unknown" })
	if _, reread := c.Delta(unknown); reread != "1700000000000301" {
		t.Error("no re-read")
	}
	if _, reread := c.Delta(with(t, unknown, func(m map[string]any) { m["__typename"] = "SlideUQPPParticipantJoin" })); reread != "1700000000000301" {
		t.Error("a member joined: no re-read")
	}
}

// Our local echo's ID is what Instagram's web client sends (`GenerateEpochID`): the time, a counter, 42. The P0
// capture app's own sends came back with theirs.
func TestOfflineThreadingIDs(t *testing.T) {
	const ms = 1_792_172_845_304
	id, _ := strconv.ParseInt(OfflineThreadingID(ms, 3), 10, 64)
	if id>>22 != ms || (id>>12)&0x3FF != 3 || id&0xFFF != 42 {
		t.Errorf("%d", id)
	}
	if OfflineThreadingID(ms, 1) == OfflineThreadingID(ms, 2) {
		t.Error("same ID twice")
	}
	echoed, _ := strconv.ParseInt(deltaMessage(t, lastDelta(t, "SlideUQPPNewMessage")).OfflineThreadingID, 10, 64)
	if echoed&0xFFF != 42 {
		t.Errorf("echoed %d", echoed)
	}
}

func TestTypingFillsAndClears(t *testing.T) {
	th := thread(t)
	// A second person, as in a group (no group on the dummies).
	th.Users = append(th.Users, IGUser{ID: "4200000101", FBID: "17841400000000101", Username: "sample.friend"})
	c := New(tamo)
	id := c.Thread(th).Room
	r := c.rooms[id]
	kivoID, otherID := int64(4200000302), int64(4200000101)
	other := User("17841400000000101")

	// The notice names the thread by its long ID and the person by their Instagram user ID (P0).
	var events []captured
	fixture(t, "ig_events_tamo", &events)
	notice := events[slices.IndexFunc(events, func(e captured) bool { return e.Kind == "TypingNotification" })]
	if notice.Thread != th.ThreadID || notice.Typing.SenderID != kivoID || notice.Typing.ActivityStatus != 1 {
		t.Fatalf("notice %+v", notice)
	}
	out, timer := c.Typing(notice.Thread, notice.Typing.SenderID, true)
	if len(out) != 1 || timer == nil || !slices.Equal(r.typing, []string{User(kivo)}) {
		t.Fatalf("typing %v", r.typing)
	}
	c.Typing(th.ThreadID, kivoID, false)
	if len(r.typing) != 0 || c.TypingTimeout(*timer) != nil { // stopped: the old timer does nothing
		t.Error("still typing")
	}
	// In a group, notices come one person at a time: each starts and stops on their own.
	c.Typing(th.ThreadID, kivoID, true)
	_, first := c.Typing(th.ThreadID, otherID, true)
	_, again := c.Typing(th.ThreadID, otherID, true) // a repeat notice doesn't add them twice, and holds longer
	if !slices.Equal(r.typing, []string{User(kivo), other}) || c.TypingTimeout(*first) != nil {
		t.Errorf("typing %v", r.typing)
	}
	if c.TypingTimeout(*again) == nil || !slices.Equal(r.typing, []string{User(kivo)}) { // its TTL ran out
		t.Errorf("typing %v", r.typing)
	}
	// Their message arriving ends it, theirs only: Instagram sends no "stopped" with a send. Our own message doesn't.
	c.Typing(th.ThreadID, otherID, true)
	c.Delta(lastDelta(t, "SlideUQPPNewMessage"))
	if !slices.Equal(r.typing, []string{User(kivo), other}) {
		t.Errorf("after ours: %v", r.typing)
	}
	c.Delta(firstDelta(t, "SlideUQPPNewMessage"))
	if !slices.Equal(r.typing, []string{other}) {
		t.Errorf("after theirs: %v", r.typing)
	}
	// Our own account typing elsewhere, and a thread this engine doesn't have, change nothing.
	if out, _ := c.Typing(th.ThreadID, 4200000301, true); out != nil {
		t.Error("our own typing")
	}
	if out, _ := c.Typing("340282366841710300000000000000000000999", kivoID, true); out != nil {
		t.Error("an unknown thread")
	}
}
