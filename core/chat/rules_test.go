package chat

import (
	"encoding/json"
	"slices"
	"strconv"
	"testing"
)

// The rules (rules.go) on P0's captures: what they let through to Instagram, and what they keep back.

const at = int64(1_792_200_000_000) // a launch's clock, after every capture

// request is kivostudio's copy of the dummies' DM as a request (`system_folder` PENDING).
func request(t *testing.T) (*Chats, string) {
	th := thread(t)
	th.SystemFolder = "PENDING"
	c := New(kivo)
	return c, c.Thread(th).Room
}

func TestOpeningReadsAtMostEvery30s(t *testing.T) {
	c := New(tamo)
	id := c.Thread(thread(t)).Room
	for _, step := range []struct {
		after int64
		read  bool
	}{{0, true}, {10_000, false}, {29_999, false}, {30_000, true}, {45_000, false}} {
		if read, err := c.Open(id, at+step.after); err != nil || read != step.read {
			t.Errorf("open after %d ms: read %v (%v)", step.after, read, err)
		}
	}
	c.Reading(id, at+100_000) // a read for fresh media links: the next open counts from it
	if read, _ := c.Open(id, at+110_000); read {
		t.Error("read again within 30 s of the last read")
	}
	if _, err := c.Open("!debug-fixture", at); err != ErrUnknownRoom {
		t.Error("opened a room the engine didn't make")
	}
}

// "Seen" goes on their newest message, only when the chat is unread and never in a request.
func TestSeenOnlyWhenUnreadAndNeverInARequest(t *testing.T) {
	c := New(tamo)
	id := c.Thread(thread(t)).Room
	if _, long, _, _, _ := c.MarkRead(id); long != "" { // our "back" is newest: read
		t.Error("Seen on a read chat")
	}
	incoming := firstDelta(t, "SlideUQPPNewMessage")
	c.Delta(incoming)
	_, long, message, _, err := c.MarkRead(id)
	if err != nil || long == "" || message != deltaMessage(t, incoming).ID {
		t.Errorf("Seen on %q (%v)", message, err)
	}
	if _, long, _, _, _ := c.MarkRead(id); long != "" {
		t.Error("a second Seen")
	}
	// Their message, then unsent before we looked: the newest left is ours, so the chat is read and nothing goes.
	c.Delta(incoming)
	c.Delta(with(t, firstDelta(t, "SlideUQPPDeleteMessage"), func(m map[string]any) { m["message_id"] = deltaMessage(t, incoming).ID }))
	if _, long, _, _, _ := c.MarkRead(id); long != "" {
		t.Error("Seen after their only new message was unsent")
	}

	r, rid := request(t)
	if r.rooms[rid].unread != 1 {
		t.Fatal("the request isn't unread")
	}
	if _, long, _, _, _ := r.MarkRead(rid); long != "" { // opening it must send nothing
		t.Error("Seen in a request")
	}
}

func TestTypingAtMostEvery20sNeverInARequest(t *testing.T) {
	c := New(tamo)
	id := c.Thread(thread(t)).Room
	for _, step := range []struct {
		after int64
		on    bool
		send  bool
	}{{0, false, false}, {0, true, true}, {5_000, true, false}, {19_999, true, false}, {21_000, true, true},
		{22_000, false, true}, {23_000, false, false}, {24_000, true, true}} {
		if send, err := c.SetTyping(id, step.on, at+step.after); err != nil || send != step.send {
			t.Errorf("typing %v after %d ms: send %v (%v)", step.on, step.after, send, err)
		}
	}
	// Sending ends it: Instagram is told once, then nothing more.
	if accept, off, err := c.BeforeSend(id); err != nil || accept || !off {
		t.Errorf("before send: accept %v, typing off %v (%v)", accept, off, err)
	}
	if _, off, _ := c.BeforeSend(id); off {
		t.Error("typing off twice")
	}

	r, rid := request(t)
	if send, _ := r.SetTyping(rid, true, at); send {
		t.Error("typing in a request")
	}
	if accept, _, _ := r.BeforeSend(rid); !accept { // a reply in a request accepts it first
		t.Error("a reply in a request doesn't accept it")
	}
}

// Reactions, edits and unsends: never in a request; only our own messages change, texts within 15 minutes and 5 edits.
func TestWhatARequestAndOurOwnMessagesAllow(t *testing.T) {
	r, rid := request(t)
	back := thread(t).SlideMessages.Edges[0].Node // tamoveska's, so theirs in kivostudio's request
	if r.CanReact(rid) != ErrRequest || r.CanUnsend(rid, back.ID) != ErrRequest || r.CanEdit(rid, back.ID, back.ms()) != ErrRequest {
		t.Error("allowed in a request")
	}

	c := New(tamo)
	id := c.Thread(thread(t)).Room
	if c.CanReact(id) != nil || c.CanUnsend(id, back.ID) != nil {
		t.Error("our own message can't be reacted to or unsent")
	}
	if err := c.CanEdit(id, back.ID, back.ms()+60_000); err != nil {
		t.Errorf("a minute-old text: %v", err)
	}
	if c.CanEdit(id, back.ID, back.ms()+editMaxAge) != ErrNotEditing {
		t.Error("edited after 15 minutes")
	}
	edited := thread(t).SlideMessages.Edges[1].Node // kivostudio's edited reply
	if c.CanUnsend(id, edited.ID) != ErrNotOwn || c.CanEdit(id, edited.ID, edited.ms()) != ErrNotOwn {
		t.Error("their message changes")
	}
	voice := thread(t).SlideMessages.Edges[6].Node
	if voice.ContentType != "AUDIOS" || c.CanEdit(id, voice.ID, voice.ms()) != ErrNotEditing {
		t.Errorf("a %s edits", voice.ContentType)
	}
	// Five different texts, and repeats count once (Instagram's echo of our edit repeats it).
	edit := func(text string, n int64) {
		b, _ := json.Marshal(map[string]any{"__typename": "SlideUQPPEditMessage", "thread_fbid": "1700000000000301", "message_id": back.ID,
			"text_body": text, "slide_edit_history_entry": map[string]any{"timestamp_ms": strconv.FormatInt(back.ms()+n, 10)}})
		c.Delta(b)
	}
	for i, text := range []string{"one", "one", "two", "three", "four"} {
		edit(text, int64(i+1))
	}
	if err := c.CanEdit(id, back.ID, back.ms()+60_000); err != nil {
		t.Errorf("4 edits: %v", err)
	}
	edit("five", 6)
	if c.CanEdit(id, back.ID, back.ms()+60_000) != ErrNotEditing {
		t.Error("a sixth edit")
	}
}

// New Message: our DM when we have one, else a draft (apart from the inbox) until the first message makes the
// thread; when it arrives, the draft leads to it.
func TestNewMessageDraftsLeadToTheirThread(t *testing.T) {
	c := New(tamo)
	c.Name, c.Avatar = "Tamo Veska", "https://scontent.example.invalid/v/f003.jpg"
	dmRoom := c.Load(dm(t, "ig_login_tamo"))[0].Room
	if c.ExistingDM(kivo) != dmRoom || c.ExistingDM("17841400000000999") != "" {
		t.Error("ExistingDM")
	}
	someone := Contact{ID: "17841400000000999", Name: "Sample Person", AvatarURL: "https://scontent.example.invalid/v/f099.jpg",
		Identifiers: []string{"instagram:sample.person"}}
	id, out := c.Draft(someone)
	if id != DraftID(tamo, someone.ID) || len(out) != 1 || out[0].Kind != "Draft" || c.Has(id) {
		t.Fatalf("draft %q %v", id, out)
	}
	if again, more := c.Draft(someone); again != id || more != nil {
		t.Error("a second draft")
	}
	if user, ok := c.DraftRecipient(id); !ok || user != someone.ID {
		t.Error("whom the first message goes to")
	}

	// Their DM arrives (the first message's NewMessage delta makes the engine read it): the draft moves there.
	kivoDraft, draftOut := c.Draft(Contact{ID: kivo, Name: "Kivo Studio"}) // as if the thread were new
	moved := c.Load(dm(t, "ig_login_tamo"))
	if len(moved) != 2 || moved[1].Kind != "RoomMoved" || moved[1].Room != kivoDraft || moved[1].To != dmRoom {
		t.Errorf("moved %v", moved)
	}
	if _, ok := c.DraftRecipient(kivoDraft); ok {
		t.Error("the draft stays")
	}
	golden(t, "drafts", map[string][]Envelope{"draft": out, "kivo_draft": draftOut, "moved": moved})
}

// DEBUG: a real chat shown as a request is one for every rule, and stays one after a re-read.
func TestAChatForcedToBeARequest(t *testing.T) {
	c := New(kivo)
	c.ForcedRequest = RoomID(kivo, "1700000000000301")
	out := c.Load(thread(t))
	if len(out) != 2 || channel(Envelope{Update: &JoinedRoom{State: out[1].Update.State}})["com.beeper.message_request"] != true {
		t.Fatalf("not marked: %v", out)
	}
	if _, long, _, _, _ := c.MarkRead(c.ForcedRequest); long != "" || c.CanReact(c.ForcedRequest) != ErrRequest {
		t.Error("Seen or a reaction in it")
	}
	if len(c.Load(thread(t))) != 2 || !c.rooms[c.ForcedRequest].isRequest() {
		t.Error("a re-read unmarked it")
	}
}

func TestFoldersAfterTheFirstPage(t *testing.T) {
	if !slices.Equal(Folders(false), []string{"INBOX", "PENDING"}) || !slices.Equal(Folders(true), []string{"INBOX", "PENDING", "GENERAL"}) {
		t.Error("folders")
	}
}

// A push names its chat by the thread's long ID (`t_id`), else its sender's Instagram user ID (`s`; `u` is the account
// it's for, 2026-10-24's capture): the captured push (push_text_kivo, scrubbed to this thread) opens the dummies' DM.
func TestAPushOpensItsChat(t *testing.T) {
	var p struct {
		Params map[string]string `json:"params"`
	}
	fixture(t, "push_text_kivo", &p)
	c := New(tamo)
	if c.PushRoom(p.Params["t_id"], p.Params["s"]) != "" {
		t.Error("a room before the chat loaded")
	}
	id := c.Thread(thread(t)).Room
	if got := c.PushRoom(p.Params["t_id"], p.Params["s"]); got != id {
		t.Errorf("by its push: %q", got)
	}
	if got := c.PushRoom("", p.Params["s"]); got != id {
		t.Errorf("by its sender: %q", got)
	}
	if got := c.PushRoom("340282366841710300000000000000000000999", "4200000999"); got != "" {
		t.Errorf("a stranger's push opened %q", got)
	}
}

// A web push channel is registered with Instagram when its endpoint is new, after a login, or a week on; never on
// every launch.
func TestRegisteringAPushChannel(t *testing.T) {
	const week = int64(7 * 24 * 3600_000)
	for _, step := range []struct {
		name                     string
		registered               string
		registeredAt, loginAt, n int64
		want                     bool
	}{
		{"never registered", "", 0, 0, at, true},
		{"a launch the next day", "e1", at, 0, at + 24*3600_000, false},
		{"a new endpoint", "e0", at, 0, at + 1, true},
		{"a login since", "e1", at, at + 5, at + 10, true},
		{"the login it registered after", "e1", at + 10, at + 5, at + 20, false},
		{"a week on", "e1", at, 0, at + week, true},
	} {
		if got := PushRegister("e1", step.registered, step.registeredAt, step.loginAt, step.n); got != step.want {
			t.Errorf("%s: %v", step.name, got)
		}
	}
}
