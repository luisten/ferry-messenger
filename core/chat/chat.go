// Package chat turns Instagram's data into the Matrix-shaped chats the apps show (docs/PLAN-android.md, E1–E4): the
// `m.bridge`, `m.room.*`, message, reaction and receipt events Ferry's bridge used to send, built here. It keeps its
// own copy of each chat (chats.go), the only writer of what Instagram says, and hands every change over as an
// update. Pure: no network, no cgo, no clock.
//
// Input is Instagram's JSON as the library's types marshal it (the same bytes the captures in testdata/ hold, and
// what IGSetCapture writes) or, for live deltas, as Instagram sent it: decoded here, not taken typed from the
// library, because its typed message content doesn't survive that JSON (`__typename` is dropped), so tests and the
// app would take different paths.
package chat

import (
	"encoding/json"
	"math"
	"net/url"
	"slices"
	"strconv"
	"strings"
)

const (
	// Me is the one user the views treat as "us" in every account's chats, as Ferry's double puppet was.
	Me = "@me"
	// StartToken is a room's first page when Instagram has no older one: the thread view shows the start of the chat.
	StartToken = "ig-start"

	protocolID     = "instagramgo"
	inboxFolderKey = "fi.mau.instagram.inbox_folder" // BridgeInfo.inboxFolderKey
	eventKey       = "fi.ferry.event"                // MessageKind.eventKey
	unsupportedKey = "fi.ferry.unsupported"          // MessageKind.unsupportedKey
	shareTextKey   = "fi.ferry.share_text"           // MessageKind.shareTextKey
	stickerKey     = "fi.ferry.sticker"              // MessageKind.stickerKey
	albumKey       = "fi.ferry.album"                // MediaInfo.albumKey
)

// User is a person's user ID in the rooms.
func User(fbid string) string { return "@ig_" + fbid }

// RoomID is one room per account and thread: a thread both of our accounts are in is two chats (as with
// `split_portals`).
func RoomID(account, thread string) string { return "!ig-" + account + "-" + thread }

// OfflineThreadingID is an ID as Instagram's web client makes them (`methods.GenerateEpochID`): ms << 22, a counter
// << 12 for IDs made in the same millisecond, then 42. Our local echo's transaction ID: the socket's echo carries it.
func OfflineThreadingID(ms, counter int64) string {
	return strconv.FormatInt(ms<<22|(counter&0x3FF)<<12|42, 10)
}

// MARK: Instagram's data (only the fields the app reads)

// Thread has three IDs (P0): `id` for most calls and in deltas' `thread_fbid`; `thread_id` (the long one) for
// unsend, mark read and typing; `thread_key` in a DM is the other person's FBID, and uploads go to it.
type Thread struct {
	ID             string        `json:"id"`
	ThreadKey      string        `json:"thread_key"`
	ThreadID       string        `json:"thread_id"`
	IsGroup        bool          `json:"is_group"`
	ThreadTitle    string        `json:"thread_title"`
	ThreadImageURL string        `json:"thread_image_url"`
	Users          []IGUser      `json:"users"` // everyone but us
	SlideMessages  Page[Message] `json:"slide_messages"`
	ReadReceipts   []ReadReceipt `json:"slide_read_receipts"`
	MarkedAsUnread bool          `json:"marked_as_unread"`
	// `PRIMARY`/`GENERAL` (Instagram's tabs) and `INBOX`/`PENDING`/`SPAM` (requests), P0. Only mailbox pages fill
	// `folder`.
	Folder       string `json:"folder"`
	SystemFolder string `json:"system_folder"`
}

type IGUser struct {
	ID         string `json:"id"` // the Instagram user ID (typing names people by it)
	FBID       string `json:"interop_messaging_user_fbid"`
	Username   string `json:"username"`
	FullName   string `json:"full_name"`
	ProfilePic string `json:"profile_pic_url"`
}

type Page[T any] struct {
	Edges []struct {
		Node T `json:"node"`
	} `json:"edges"`
	PageInfo struct {
		EndCursor   string `json:"end_cursor"`
		HasNextPage bool   `json:"has_next_page"`
	} `json:"page_info"`
}

func (p Page[T]) nodes() []T {
	out := make([]T, len(p.Edges))
	for i, e := range p.Edges {
		out[i] = e.Node
	}
	return out
}

// Next is the cursor for the next page, "" at the end.
func (p Page[T]) Next() string {
	if p.PageInfo.HasNextPage {
		return p.PageInfo.EndCursor
	}
	return ""
}

type Message struct {
	ID                 string     `json:"id"`
	SenderFBID         string     `json:"sender_fbid"`
	TimestampMS        string     `json:"timestamp_ms"`
	ContentType        string     `json:"content_type"`
	TextBody           string     `json:"text_body"`
	IGDSnippet         string     `json:"igd_snippet"`
	OfflineThreadingID string     `json:"offline_threading_id"`
	RepliedToMessageID string     `json:"replied_to_message_id"` // "" on every message that isn't a reply
	Reactions          []Reaction `json:"reactions"`
	RepliedToMessage   *Message   `json:"replied_to_message"` // the message this one replies to, sent along with it
	// Earlier versions, oldest first; `text_body` is the current one.
	SlideEditHistory []struct {
		Body string `json:"body"`
	} `json:"slide_edit_history"`
	// The attachments, by kind (`audio_attachments`, `videos`, `attachments`, `xma`…), kept as JSON.
	Content map[string]any `json:"content"`
}

func (m Message) ms() int64 { return parseMS(m.TimestampMS) }

// Instagram's "Reacted 😂 to your message" log entry repeats a reaction the message itself shows: not a row.
func (m Message) isShown() bool { return m.ContentType != "REACTION_LOG_XMAT" }

// Reaction is a message's (`reaction`, `sender_fbid`) or a delta's, whose log entry ID is how a later delete names
// it (the delete carries nothing else, P0).
type Reaction struct {
	Reaction    string `json:"reaction"`
	SenderFBID  string `json:"sender_fbid"`
	LogID       string `json:"log_message_id"`
	TimestampMS string `json:"reaction_timestamp_ms"`
}

type ReadReceipt struct {
	FBID        string `json:"participant_fbid"`
	WatermarkMS string `json:"watermark_timestamp_ms"`
}

// Resolved is a share's own media at its best size ("Load video").
type Resolved struct {
	URL      string
	Video    bool
	Width    float64
	Height   float64
	Duration float64 // seconds
}

// MARK: What the apps get (Matrix's shapes, as SyncTypes.swift decodes them)

type Event struct {
	Type           string         `json:"type"`
	Content        map[string]any `json:"content"`
	EventID        string         `json:"event_id,omitempty"`
	Sender         string         `json:"sender,omitempty"`
	StateKey       *string        `json:"state_key,omitempty"`
	OriginServerTS int64          `json:"origin_server_ts,omitempty"`
	Unsigned       *Unsigned      `json:"unsigned,omitempty"`
}

type Unsigned struct {
	TransactionID   string `json:"transaction_id,omitempty"`
	RedactedBecause any    `json:"redacted_because,omitempty"`
}

type JoinedRoom struct {
	State               *EventList `json:"state,omitempty"`
	Timeline            *Timeline  `json:"timeline,omitempty"`
	Ephemeral           *EventList `json:"ephemeral,omitempty"`
	UnreadNotifications *Unread    `json:"unread_notifications,omitempty"`
}

type EventList struct {
	Events []Event `json:"events"`
}

type Timeline struct {
	Events    []Event `json:"events"`
	Limited   bool    `json:"limited"`
	PrevBatch string  `json:"prev_batch,omitempty"`
}

type Unread struct {
	NotificationCount int `json:"notification_count"`
	HighlightCount    int `json:"highlight_count"`
}

// MessagesPage is an older page as `/messages` gave it: newest first, `end` absent at the start of the chat.
type MessagesPage struct {
	Chunk []Event `json:"chunk"`
	End   string  `json:"end,omitempty"`
}

// Envelope is one chat's change: `Room` (an update to apply, as `Room.apply` takes it, with the people and reply
// targets that came with it), `RoomRemoved`, `Draft` (New Message's chat before its thread exists, rules.go) or
// `RoomMoved` (a draft's thread arrived: `To`).
type Envelope struct {
	Kind     string             `json:"kind"`
	Room     string             `json:"room"`
	Update   *JoinedRoom        `json:"update,omitempty"`
	Profiles map[string]Profile `json:"profiles,omitempty"`
	Related  []Event            `json:"related,omitempty"`
	To       string             `json:"to,omitempty"` // `RoomMoved`: the draft's chat now
}

// Profile is a person's name, picture and @handle (`UserProfile`): no `/profile` to ask any more.
type Profile struct {
	Name      string `json:"name,omitempty"`
	AvatarURL string `json:"avatar_url,omitempty"`
	Handle    string `json:"handle,omitempty"`
}

// Contact is a search result as New Message's contact (N1, `BridgeAPI.Contact`): the FBID is who we message and what
// a DM's channel names.
type Contact struct {
	ID          string   `json:"id"`
	Name        string   `json:"name,omitempty"`
	AvatarURL   string   `json:"avatar_url,omitempty"`
	Identifiers []string `json:"identifiers,omitempty"`
}

// MARK: Library responses

// Mailbox reads a mailbox (the login's, or a page's `fetch__SlideMailbox`): its threads and the next page's cursor.
func Mailbox(b []byte) (threads []Thread, next string, err error) {
	var m struct {
		ThreadsByFolder Page[struct {
			Thread *Thread `json:"as_ig_direct_thread"`
		}] `json:"threads_by_folder"`
	}
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, "", err
	}
	for _, n := range m.ThreadsByFolder.nodes() {
		if n.Thread != nil {
			threads = append(threads, *n.Thread)
		}
	}
	return threads, m.ThreadsByFolder.Next(), nil
}

// ReadThread reads `GetThread`'s answer; nil when Instagram has no such thread.
func ReadThread(b []byte) (*Thread, error) {
	var r struct {
		Wrapped struct {
			Thread *Thread `json:"as_ig_direct_thread"`
		} `json:"get_slide_thread_nullable"`
	}
	err := json.Unmarshal(b, &r)
	return r.Wrapped.Thread, err
}

// OlderThread reads `PaginateMessages`' answer.
func OlderThread(b []byte) (*Thread, error) {
	var r struct {
		Wrapped struct {
			Thread *Thread `json:"as_ig_direct_thread"`
		} `json:"fetch__SlideThread"`
	}
	err := json.Unmarshal(b, &r)
	return r.Wrapped.Thread, err
}

// SentID reads `SendMessage`'s answer: Instagram's ID for the message, which the local echo's "sent" state keeps.
func SentID(b []byte) string {
	var r struct {
		Sent struct {
			ID string `json:"id"`
		} `json:"xig_direct_text_send_with_slide_messaging_response"`
	}
	_ = json.Unmarshal(b, &r)
	return r.Sent.ID
}

// Contacts reads `SearchUsers`' answer as New Message's contacts.
func Contacts(b []byte) ([]Contact, error) {
	var r struct {
		Data struct {
			Results []struct {
				FBID       string `json:"interop_messaging_user_fbid"`
				Username   string `json:"username"`
				FullName   string `json:"full_name"`
				ProfilePic string `json:"profile_pic_url"`
			} `json:"search_messenger_contact_v2"`
		} `json:"xfb_combinedIGSearchQuery"`
	}
	if err := json.Unmarshal(b, &r); err != nil {
		return nil, err
	}
	contacts := []Contact{}
	for _, u := range r.Data.Results {
		if u.FBID == "" {
			continue
		}
		c := Contact{ID: u.FBID, Name: nonEmpty(u.FullName, u.Username), AvatarURL: u.ProfilePic}
		if u.Username != "" {
			c.Identifiers = []string{"instagram:" + u.Username}
		}
		contacts = append(contacts, c)
	}
	return contacts, nil
}

// MARK: Threads and messages as rooms and events

// snapshot is a thread with its newest messages, as a fresh window (`limited`): applying it again replaces the last
// one. `readUpTo` is how far we've read as this engine knows it (our `m.read`, ms): a read that left before our
// "Seen" reached Instagram still says unread, and opening a chat sends both at once.
func snapshot(t Thread, account, myName, myAvatar string, readUpTo int64) Envelope {
	var people []IGUser
	for _, u := range t.Users {
		if u.FBID != "" && u.FBID != account {
			people = append(people, u)
		}
	}
	isDM := !t.IsGroup
	var contact *IGUser
	if isDM && len(people) > 0 {
		contact = &people[0]
	}
	name := t.ThreadTitle
	if name == "" && contact != nil {
		name = nonEmpty(contact.FullName, contact.Username)
	}
	if name == "" {
		name = "Instagram chat"
	}

	channelID := t.ID
	if isDM {
		channelID = t.ThreadKey
		if channelID == "" && contact != nil {
			channelID = contact.FBID
		}
		if channelID == "" {
			channelID = t.ID
		}
	}
	channel := map[string]any{"id": channelID, "displayname": name, "fi.mau.receiver": account}
	if t.SystemFolder == "PENDING" || t.SystemFolder == "SPAM" {
		channel["com.beeper.message_request"] = true
	}
	if t.Folder == "GENERAL" {
		channel[inboxFolderKey] = "GENERAL"
	}
	bridge := map[string]any{"protocol": map[string]any{"id": protocolID, "displayname": "Instagram"}, "channel": channel}
	if isDM {
		bridge["com.beeper.room_type"] = "dm" // a group has none (S7.6)
	}

	state := []Event{stateEvent("m.bridge", "instagram", bridge), stateEvent("m.room.name", "", map[string]any{"name": name})}
	avatar := t.ThreadImageURL
	if isDM {
		avatar = ""
		if contact != nil {
			avatar = contact.ProfilePic
		}
	}
	if avatar != "" {
		state = append(state, stateEvent("m.room.avatar", "", map[string]any{"url": avatar}))
	}
	state = append(state, member(Me, myName, myAvatar))
	profiles := map[string]Profile{}
	for _, p := range people {
		state = append(state, member(User(p.FBID), nonEmpty(p.FullName, p.Username), p.ProfilePic))
		profiles[User(p.FBID)] = Profile{Name: p.FullName, AvatarURL: p.ProfilePic, Handle: p.Username}
	}

	var messages []Message // oldest first, as rooms keep them
	for _, m := range slices.Backward(t.SlideMessages.nodes()) {
		if m.isShown() {
			messages = append(messages, m)
		}
	}
	mine := readUpTo
	for _, r := range t.ReadReceipts {
		if r.FBID == account {
			mine = max(parseMS(r.WatermarkMS), readUpTo)
			break
		}
	}
	unread := t.MarkedAsUnread
	if n := len(messages); n > 0 && messages[n-1].SenderFBID != account && messages[n-1].ms() > mine {
		unread = true
	}

	var events, related []Event
	for _, m := range messages {
		events = append(events, messageEvents(m, account)...)
		if e := relatedEvent(m, account); e != nil {
			related = append(related, *e)
		}
	}
	joined := JoinedRoom{
		State:               &EventList{state},
		Timeline:            &Timeline{Events: nonNil(events), Limited: true, PrevBatch: nonEmpty(t.SlideMessages.Next(), StartToken)},
		UnreadNotifications: &Unread{NotificationCount: count(unread)},
	}
	if r := readReceipts(t.ReadReceipts, account, messages); r != nil {
		joined.Ephemeral = &EventList{[]Event{*r}}
	}
	return Envelope{Kind: "Room", Room: RoomID(account, t.ID), Update: &joined, Profiles: profiles, Related: related}
}

// page is an older page as `/messages` gave it: newest first, `end` "" at the start of the chat.
func page(t *Thread, account string) MessagesPage {
	var events []Event
	if t == nil {
		return MessagesPage{Chunk: []Event{}}
	}
	for _, m := range slices.Backward(t.SlideMessages.nodes()) { // oldest first, then the whole chunk reversed
		if m.isShown() {
			events = append(events, messageEvents(m, account)...)
		}
	}
	slices.Reverse(events)
	return MessagesPage{Chunk: nonNil(events), End: t.SlideMessages.Next()}
}

// messageEvents is a message and what hangs off it: earlier versions as the base plus `m.replace` edits (so it reads
// "Edited"), and one `m.reaction` per person. Our own carry their offline threading ID, which clears the local echo.
func messageEvents(m Message, account string) []Event {
	sender := senderID(m.SenderFBID, account)
	var base map[string]any
	if len(m.SlideEditHistory) > 0 {
		base = text(m.SlideEditHistory[0].Body)
	} else {
		base = content(m)
	}
	if m.RepliedToMessageID != "" {
		base["m.relates_to"] = map[string]any{"m.in_reply_to": map[string]any{"event_id": m.RepliedToMessageID}}
	}
	e := Event{Type: "m.room.message", Content: base, EventID: m.ID, Sender: sender, OriginServerTS: m.ms()}
	if sender == Me && m.OfflineThreadingID != "" {
		e.Unsigned = &Unsigned{TransactionID: m.OfflineThreadingID}
	}
	events := []Event{e}
	if len(m.SlideEditHistory) > 0 {
		bodies := []string{}
		for _, h := range m.SlideEditHistory[1:] {
			bodies = append(bodies, h.Body)
		}
		for i, body := range append(bodies, m.TextBody) {
			events = append(events, Event{Type: "m.room.message", Content: map[string]any{
				"msgtype": "m.text", "body": "* " + body, "m.new_content": text(body),
				"m.relates_to": map[string]any{"rel_type": "m.replace", "event_id": m.ID},
			}, EventID: m.ID + "~edit" + strconv.Itoa(i), Sender: sender, OriginServerTS: m.ms() + int64(i) + 1})
		}
	}
	for _, r := range m.Reactions {
		if r.Reaction == "" || r.SenderFBID == "" {
			continue
		}
		events = append(events, Event{Type: "m.reaction", Content: map[string]any{"m.relates_to": map[string]any{
			"rel_type": "m.annotation", "event_id": m.ID, "key": r.Reaction,
		}}, EventID: m.ID + "~react" + r.SenderFBID, Sender: senderID(r.SenderFBID, account), OriginServerTS: m.ms()})
	}
	return events
}

// relatedEvent is a reply's target, filed in `Room.related` so the quote shows without a fetch. Instagram sends none
// for a target unsent since: an unsent stand-in then, so the quote says so instead of loading forever.
func relatedEvent(m Message, account string) *Event {
	if q := m.RepliedToMessage; q != nil && q.ID != "" {
		// Only what a quote needs: no reactions, edits, reply or offline threading ID of its own.
		quoted := Message{ID: q.ID, SenderFBID: q.SenderFBID, TimestampMS: q.TimestampMS, ContentType: q.ContentType,
			TextBody: q.TextBody, IGDSnippet: q.IGDSnippet, Content: q.Content}
		return &messageEvents(quoted, account)[0]
	}
	if m.RepliedToMessageID == "" {
		return nil
	}
	return &Event{Type: "m.room.message", Content: map[string]any{}, EventID: m.RepliedToMessageID,
		Sender: senderID(m.SenderFBID, account), Unsigned: &Unsigned{RedactedBecause: map[string]any{}}}
}

// content is the message's content in the shapes `MessageKind`, `MediaInfo` and the cards read. Media links are
// Instagram's CDN URLs, downloaded on tap (`MediaCache`).
func content(m Message) map[string]any {
	c := m.Content
	switch {
	case m.ContentType == "TEXT":
		return text(m.TextBody)
	case m.ContentType == "AUDIOS":
		audio := first(c["audio_attachments"])
		ms, _ := audio["playable_duration_ms"].(float64)
		return media("m.audio", "Voice message", audio["attachment_cdn_url"], map[string]any{"mimetype": "audio/mp4", "duration": ms},
			map[string]any{"org.matrix.msc3245.voice": map[string]any{}, "org.matrix.msc1767.audio": map[string]any{"duration": ms}})
	case m.ContentType == "VIDEOS":
		return album(arr(c["videos"]), new(true))
	case m.ContentType == "IMAGES":
		return album(arr(c["attachments"]), new(false))
	case has(c, "ordered_photo_video_attachments"): // photos and videos in one message (upstream's shape)
		return album(arr(c["ordered_photo_video_attachments"]), nil)
	case has(c, "animated_media"):
		// A GIF or a sticker: `GIFS` (one we uploaded), `INSTAGRAM_MESSAGING_ANIMATED_IMAGE` (Instagram's GIPHY picker,
		// live 2026-10-20, `ig_animated_images_tamo`). The mailbox's copy has no media (`null`).
		gif := first(c["animated_media"])
		// ponytail: there only the snippet ("You sent a sticker.") says it's a sticker, in English; else it's a GIF
		// until the thread is read.
		sticker := gif["is_sticker"] == true || strings.HasSuffix(m.IGDSnippet, " sent a sticker.")
		content := media("m.image", "GIF", gif["attachment_webp_url"], map[string]any{
			"mimetype": "image/webp", "w": gif["preview_width"], "h": gif["preview_height"],
			"thumbnail_url": gif["preview_cdn_url"], "fi.mau.gif": true,
		}, nil)
		if sticker {
			content["body"], content[stickerKey] = "Sticker", true
		}
		return content
	case has(c, "text_fragments"): // Instagram's own line: "… named the group …", "… left the group"
		line := ""
		for _, f := range arr(c["text_fragments"]) {
			if s, ok := obj(f)["plaintext"].(string); ok {
				line += s
			}
		}
		if line = nonEmpty(line, m.IGDSnippet); line == "" {
			return unsupported(m)
		}
		return map[string]any{"msgtype": "m.notice", "body": line, eventKey: true}
	case has(c, "xma"):
		// A story reply or reaction (`MONTAGE_SHARE_XMA`) is the story plus what was sent, `xma_text_body` (live
		// 2026-10-19, `ig_story_replies_kivo`). The mailbox's copy has `xma: null` and the text only in `text_body`:
		// a text until the thread is read, previewed as Instagram's own snippet does.
		body, _ := c["xma_text_body"].(string)
		sent := nonEmpty(body, m.TextBody)
		xma := obj(c["xma"])
		if xma == nil && sent != "" {
			return text(sent)
		}
		return share(xma, m.IGDSnippet, sent)
	case m.ContentType == "RAVEN_IMAGE" || m.ContentType == "RAVEN_VIDEO":
		// Instagram's in-chat camera (live 2026-10-24, `ig_camera_media_tamo`): `view_mode` 0 view once, 1 allow replay,
		// 2 keep in chat. Kept, it carries the same attachment as a photo or video from the camera roll, so it's the
		// same card (without one, as a mailbox copy may be, still a photo or video until the thread is read, like a
		// GIF's); the others carry none and stay a line (never shown as a lasting photo, D13). The bridge's own
		// wording is how `MessageKind` knows view-once media.
		video := m.ContentType == "RAVEN_VIDEO"
		if mode, _ := c["view_mode"].(float64); mode == 2 {
			return album([]any{c["attachment"]}, &video)
		}
		what := "photo"
		if video {
			what = "video"
		}
		return map[string]any{"msgtype": "m.notice", "body": "This " + what + " can only be viewed once. Use the Instagram app to view."}
	default:
		return unsupported(m)
	}
}

// unsupported is what the app can't show (a poll…), as a line that sends you to Instagram. A thread
// read's copy has no `igd_snippet` (the mailbox's and live deltas' do), so the content type is all that names it on
// every path.
func unsupported(m Message) map[string]any {
	// ponytail: "poll" is a guess at Instagram's naming (no poll captured yet); name more kinds once one is.
	what := "a message Ferry can't show"
	typename, _ := m.Content["__typename"].(string)
	if strings.Contains(strings.ToLower(m.ContentType), "poll") || strings.Contains(strings.ToLower(typename), "poll") {
		what = "a poll"
	}
	return map[string]any{"msgtype": "m.notice", "body": "Sent " + what, unsupportedKey: what}
}

// album is photos or videos: one, or several sent together (one message, live 2026-10-18). Several are the first
// one's content plus all of them under `albumKey`, which `MediaCard` stacks. `video` nil: each item says.
func album(items []any, video *bool) map[string]any {
	card := func(item map[string]any) map[string]any {
		url, w, h := item["attachment_cdn_url"], item["preview_width"], item["preview_height"]
		isVideo := item["__typename"] == "XFBSlideVideoAttachment"
		if video != nil {
			isVideo = *video
		}
		if isVideo {
			return media("m.video", "Video", url, map[string]any{"mimetype": "video/mp4", "w": w, "h": h, "thumbnail_url": item["preview_cdn_url"]}, nil)
		}
		return media("m.image", "Photo", url, map[string]any{"mimetype": "image/jpeg", "w": w, "h": h}, nil)
	}
	if len(items) < 2 {
		return card(first(items))
	}
	firstCard, all := card(obj(items[0])), make([]any, len(items))
	for i, item := range items {
		all[i] = card(obj(item))
	}
	firstCard[albumKey] = all
	return firstCard
}

// share is a share (Instagram's XMA) in the bridge's shapes, so the cards read it as before: a reel or story waits
// for "Load video" (`com.beeper.unresolved_media`, then `resolved`), a post is its image, a link off Instagram is a
// text with its preview, an expired story its notice. The author is Instagram's `header_title_text`, its own line
// about it ("Replied to @…'s story") `eyebrow_text`, as the bridge's `<blockquote>`. `sent` is what was sent with it
// (a story reply, or a story reaction's emoji), under `shareTextKey`: one message, so one menu, reaction row and
// unsend.
func share(xma map[string]any, snippet, sent string) map[string]any {
	link, hasLink := xma["target_url"].(string)
	preview := obj(xma["preview_image"])
	caption := ""
	for _, k := range []string{"title_text", "caption_body_text", "subtitle_text"} {
		if s, _ := xma[k].(string); s != "" {
			caption = s
			break
		}
	}
	kind := ""
	if hasLink {
		kind = shareType(link)
	}
	if kind == "" {
		if !hasLink {
			// The mailbox's copy has no `xma`, and its snippet names the sender ("You sent an attachment."): a line
			// that says who, so the inbox doesn't add "You: " again. The thread's copy replaces it.
			if xma == nil {
				return map[string]any{"msgtype": "m.notice", "body": nonEmpty(snippet, "Shared content"), eventKey: true}
			}
			notice := map[string]any{"msgtype": "m.notice", "body": nonEmpty(caption, snippet, "Shared content")}
			if sent != "" {
				notice[shareTextKey] = sent
			}
			return notice
		}
		p := map[string]any{"matched_url": link}
		for key, field := range map[string]string{"og:title": "title_text", "og:description": "subtitle_text"} {
			if v, ok := xma[field]; ok {
				p[key] = v
			}
		}
		if v, ok := preview["url"]; ok {
			p["og:image"] = v
		}
		return map[string]any{"msgtype": "m.text", "body": nonEmpty(sent, link), "com.beeper.linkpreviews": []any{p}}
	}
	html := ""
	if s, _ := xma["eyebrow_text"].(string); s != "" {
		html = "<blockquote>" + escape(s) + "</blockquote>"
	}
	if s, ok := xma["header_title_text"].(string); ok {
		html += "<strong>" + escape(s) + "</strong>"
	}
	if caption != "" {
		html += "<p>" + escape(caption) + "</p>"
	}
	info := map[string]any{"w": preview["width"], "h": preview["height"]}
	fields := map[string]any{"body": nonEmpty(snippet, "Sent a "+kind), "external_url": link, "formatted_body": html,
		"format": "org.matrix.custom.html"}
	if kind == "post" {
		fields["msgtype"] = "m.image"
		if v, ok := preview["url"]; ok {
			fields["url"] = v
		}
	} else {
		fields["msgtype"] = "m.video"
		info["thumbnail_url"] = preview["url"]
		fields["com.beeper.unresolved_media"] = map[string]any{"target_url": link, "target_id": xma["target_id"]}
	}
	if sent != "" {
		fields[shareTextKey] = sent
	}
	for k, v := range info {
		if v == nil || v == float64(0) {
			delete(info, k)
		}
	}
	fields["info"] = info
	return fields
}

// shareType is `MessageKind.ShareType(instagramURL:)`: "reel", "post", "story", or "" for anything else.
func shareType(link string) string {
	u, err := url.Parse(link)
	if err != nil {
		return ""
	}
	if h := u.Hostname(); h != "instagram.com" && !strings.HasSuffix(h, ".instagram.com") {
		return ""
	}
	switch p := u.EscapedPath(); {
	case strings.Contains(p, "/reel/") || strings.Contains(p, "/reels/"):
		return "reel"
	case strings.Contains(p, "/p/"):
		return "post"
	case strings.Contains(p, "/stories/"):
		return "story"
	}
	return ""
}

// resolvedEvent is "Load video" done: the share's media, as the hidden edit that swaps the card (the bridge's
// resolve_media did the same; `com.beeper.dont_render_edited` keeps "Edited" off). `current` is the message's content
// as it shows now.
func resolvedEvent(m Resolved, base Event, current map[string]any) Event {
	content := clone(current)
	delete(content, "com.beeper.unresolved_media")
	info := clone(obj(content["info"]))
	if m.Width > 0 {
		info["w"] = m.Width
	}
	if m.Height > 0 {
		info["h"] = m.Height
	}
	if m.Video {
		content["msgtype"], info["mimetype"] = "m.video", "video/mp4"
		if m.Duration > 0 {
			info["duration"] = math.Round(m.Duration * 1000)
		}
	} else {
		content["msgtype"], info["mimetype"] = "m.image", "image/jpeg"
	}
	content["url"], content["info"] = m.URL, info
	return Event{Type: "m.room.message", Content: map[string]any{
		"msgtype": content["msgtype"], "body": "* resolved", "m.new_content": content,
		"m.relates_to": map[string]any{"rel_type": "m.replace", "event_id": base.EventID}, "com.beeper.dont_render_edited": true,
	}, EventID: base.EventID + "~resolved", Sender: base.Sender, OriginServerTS: base.OriginServerTS + 1}
}

// readReceipts is everyone's watermark as `m.read`, ours as `Me`'s (where the "New messages" line starts).
func readReceipts(receipts []ReadReceipt, account string, messages []Message) *Event {
	var reads []read
	for _, r := range receipts {
		ms := parseMS(r.WatermarkMS)
		if r.FBID == "" {
			continue
		}
		found := false
		for _, m := range slices.Backward(messages) {
			if m.ms() <= ms {
				reads = append(reads, read{senderID(r.FBID, account), m.ID, ms})
				found = true
				break
			}
		}
		// Ours, older than every message loaded (an unread chat's mailbox copy is its last message or two): still how
		// far we'd read, on the oldest, or the app's "New messages" line has no place (QA 2026-10-20). The app reads
		// only our receipt's time; others' that predate them all say nothing, as they've seen none of these.
		if !found && r.FBID == account && ms > 0 && len(messages) > 0 {
			reads = append(reads, read{Me, messages[0].ID, ms})
		}
	}
	if len(reads) == 0 {
		return nil
	}
	e := receiptEvent(reads...)
	return &e
}

type read struct {
	user, event string
	ts          int64
}

func receiptEvent(reads ...read) Event {
	content := map[string]any{}
	for _, r := range reads {
		users, _ := obj(content[r.event])["m.read"].(map[string]any)
		if users == nil {
			users = map[string]any{}
		}
		users[r.user] = map[string]any{"ts": r.ts}
		content[r.event] = map[string]any{"m.read": users}
	}
	return Event{Type: "m.receipt", Content: content}
}

// readUpdate is "we've read up to `eventID` (`ms`)": the chat is read, and our `m.read` moves there.
func readUpdate(eventID string, ms int64) JoinedRoom {
	j := JoinedRoom{UnreadNotifications: &Unread{}}
	if eventID != "" {
		j.Ephemeral = &EventList{[]Event{receiptEvent(read{Me, eventID, ms})}}
	}
	return j
}

// typingUpdate is one person starting or stopping, the others as they were: in a group, Instagram's notices come one
// person at a time, and one person's "stopped" cleared everyone. It replaces the list, as `m.typing` did.
func typingUpdate(user string, on bool, current []string) JoinedRoom {
	users := []string{}
	for _, u := range current {
		if u != user {
			users = append(users, u)
		}
	}
	if on {
		users = append(users, user)
	}
	return JoinedRoom{Ephemeral: &EventList{[]Event{{Type: "m.typing", Content: map[string]any{"user_ids": users}}}}}
}

func timeline(e ...Event) JoinedRoom { return JoinedRoom{Timeline: &Timeline{Events: e}} }

func unread(n int) JoinedRoom { return JoinedRoom{UnreadNotifications: &Unread{NotificationCount: n}} }

func redaction(id, sender string, ms int64) Event {
	return Event{Type: "m.room.redaction", Content: map[string]any{"redacts": id}, EventID: id + "~unsent", Sender: sender, OriginServerTS: ms}
}

func text(body string) map[string]any { return map[string]any{"msgtype": "m.text", "body": body} }

// media drops the info fields Instagram left out (or sent as null).
func media(msgtype, body string, url any, info, extra map[string]any) map[string]any {
	for k, v := range info {
		if v == nil {
			delete(info, k)
		}
	}
	fields := map[string]any{"msgtype": msgtype, "body": body, "info": info}
	if s, ok := url.(string); ok {
		fields["url"] = s
	}
	for k, v := range extra {
		fields[k] = v
	}
	return fields
}

func stateEvent(typ, key string, content map[string]any) Event {
	return Event{Type: typ, Content: content, EventID: "$ig-" + typ + "-" + key, Sender: Me, StateKey: &key}
}

func member(id, name, avatar string) Event {
	content := map[string]any{"membership": "join"}
	if name != "" {
		content["displayname"] = name
	}
	if avatar != "" {
		content["avatar_url"] = avatar
	}
	return Event{Type: "m.room.member", Content: content, EventID: "$ig-member-" + id, Sender: id, StateKey: &id}
}

func senderID(fbid, account string) string {
	if fbid == account {
		return Me
	}
	return User(fbid)
}

var escaper = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&#34;")

func escape(s string) string { return escaper.Replace(s) }

func parseMS(s string) int64 {
	n, _ := strconv.ParseInt(s, 10, 64)
	return n
}

// nonEmpty is the first of `s` that isn't empty.
func nonEmpty(s ...string) string {
	for _, v := range s {
		if v != "" {
			return v
		}
	}
	return ""
}

func count(b bool) int {
	if b {
		return 1
	}
	return 0
}

// nonNil keeps an empty list `[]` in JSON (Swift decodes a missing timeline list as nil, which reads the same).
func nonNil(events []Event) []Event {
	if events == nil {
		return []Event{}
	}
	return events
}

func obj(v any) map[string]any { m, _ := v.(map[string]any); return m }

func arr(v any) []any { a, _ := v.([]any); return a }

func first(v any) map[string]any {
	if a := arr(v); len(a) > 0 {
		return obj(a[0])
	}
	return nil
}

func has(m map[string]any, key string) bool { _, ok := m[key]; return ok }

func clone(m map[string]any) map[string]any {
	out := make(map[string]any, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}
