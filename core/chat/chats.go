package chat

import (
	"encoding/json"
	"errors"
	"slices"
	"strconv"
)

// ErrUnknownRoom refuses a room this engine didn't make (E4): a New Message draft, or a DEBUG fixture room.
var ErrUnknownRoom = errors.New("not an Instagram chat")

// Chats is the engine's copy of one account's chats (E3): what applying Instagram's changes needs (the window, the
// tab, our watermark, unread, who's typing) and each thread's IDs. Every change it makes comes back as envelopes,
// applied here first, so the app's copy is this one as long as it applies them all, in order. Not safe for
// concurrent use: the caller locks.
type Chats struct {
	Account string
	// Our own member in every room: the viewer's name and picture.
	Name, Avatar string

	rooms map[string]*room
	// Typing names a thread by its long ID and people by their Instagram user ID (P0): both mapped as threads load.
	byLong       map[string]string
	fbidByUserID map[string]string
	// Each person's latest typing notice, by "<room>/<user>": a timeout from an older one does nothing.
	typingGen map[string]int

	// The rules' state (rules.go), by room: when each was last read in full, when we last said "typing".
	readAt, typingAt map[string]int64
	// New Message's drafts: room ID → whom it's for.
	drafts map[string]string
	// DEBUG: a real chat shown as a request (`FERRY_DEBUG_AS_REQUEST`), so every request rule applies to it.
	ForcedRequest string
}

func New(account string) *Chats {
	return &Chats{Account: account, rooms: map[string]*room{}, byLong: map[string]string{}, fbidByUserID: map[string]string{},
		typingGen: map[string]int{}, readAt: map[string]int64{}, typingAt: map[string]int64{}, drafts: map[string]string{}}
}

// The state parts of `Room.apply` and `Room.prepend` (Room.swift), for the fields this engine reads.
type room struct {
	thread, long, key string
	state             map[string]map[string]Event
	events            []Event // oldest first, since the last fresh window
	prevBatch         string
	unread            int
	typing            []string
	readUpTo          int64 // our m.read (ms)
}

func (r *room) apply(j JoinedRoom) {
	if j.State != nil {
		for _, e := range j.State.Events {
			r.setState(e)
		}
	}
	if t := j.Timeline; t != nil {
		if t.Limited {
			r.events = nil
		}
		if t.Limited || r.prevBatch == "" {
			r.prevBatch = t.PrevBatch
		}
		for _, e := range t.Events {
			r.setState(e)
			r.events = append(r.events, e)
		}
	}
	if u := j.UnreadNotifications; u != nil {
		r.unread = u.NotificationCount + u.HighlightCount
	}
	if j.Ephemeral != nil {
		for _, e := range j.Ephemeral.Events {
			switch e.Type {
			case "m.typing":
				r.typing, _ = e.Content["user_ids"].([]string)
			case "m.receipt":
				for _, kinds := range e.Content {
					if info, ok := obj(obj(obj(kinds)["m.read"])[Me])["ts"].(int64); ok && info >= r.readUpTo {
						r.readUpTo = info
					}
				}
			}
		}
	}
}

func (r *room) setState(e Event) {
	if e.StateKey == nil {
		return
	}
	if r.state[e.Type] == nil {
		r.state[e.Type] = map[string]Event{}
	}
	r.state[e.Type][*e.StateKey] = e
}

// prepend is one older page fetched from `token`, dropped if a fresh window replaced this one meanwhile.
func (r *room) prepend(p MessagesPage, token string) {
	if token != r.prevBatch {
		return
	}
	known := map[string]bool{}
	for _, e := range r.events {
		if e.EventID != "" {
			known[e.EventID] = true
		}
	}
	var older []Event
	for _, e := range slices.Backward(p.Chunk) {
		if !known[e.EventID] {
			older = append(older, e)
		}
	}
	r.events = append(older, r.events...)
	r.prevBatch = p.End
}

func (r *room) event(id string) *Event {
	for i := range r.events {
		if r.events[i].EventID == id {
			return &r.events[i]
		}
	}
	return nil
}

// lastBase is the newest message at or before `ms` that isn't an edit (any message when `ms` < 0).
func (r *room) lastBase(ms int64) *Event {
	for i := len(r.events) - 1; i >= 0; i-- {
		if e := &r.events[i]; e.isBase() && (ms < 0 || e.OriginServerTS <= ms) {
			return e
		}
	}
	return nil
}

// lastMessage is the newest message that is neither an edit nor unsent.
func (r *room) lastMessage() *Event { return r.lastMessageWhere(func(*Event) bool { return true }) }

// currentContent is a message's content as it shows: its latest edit's `m.new_content` (same sender only).
func (r *room) currentContent(base *Event) map[string]any {
	for _, e := range slices.Backward(r.events) {
		if e.replaces() == base.EventID && e.Sender == base.Sender {
			if c := obj(e.Content["m.new_content"]); c != nil {
				return c
			}
		}
	}
	return base.Content
}

func (r *room) bridge() *Event {
	for _, e := range r.state["m.bridge"] {
		if obj(e.Content["protocol"])["id"] == protocolID {
			return &e
		}
	}
	return nil
}

func (r *room) isGeneral() bool {
	b := r.bridge()
	return b != nil && obj(b.Content["channel"])[inboxFolderKey] == "GENERAL"
}

// bridgeUpdate is the room's `m.bridge` again with its channel changed (the Instagram tab), or nil without one.
func (r *room) bridgeUpdate(change func(channel map[string]any)) *JoinedRoom {
	b := r.bridge()
	if b == nil || obj(b.Content["channel"]) == nil {
		return nil
	}
	e := *b
	e.Content = clone(b.Content)
	channel := clone(obj(b.Content["channel"]))
	change(channel)
	e.Content["channel"] = channel
	return &JoinedRoom{State: &EventList{[]Event{e}}}
}

func (e Event) replaces() string {
	if rel := obj(e.Content["m.relates_to"]); rel["rel_type"] == "m.replace" {
		id, _ := rel["event_id"].(string)
		return id
	}
	return ""
}

// isBase is a message or sticker that isn't an edit: one row in a thread.
func (e Event) isBase() bool {
	return (e.Type == "m.room.message" || e.Type == "m.sticker") && e.replaces() == ""
}

// put applies an update to the engine's copy and hands it over.
func (c *Chats) put(id string, r *room, j JoinedRoom) Envelope {
	r.apply(j)
	return Envelope{Kind: "Room", Room: id, Update: &j}
}

func (c *Chats) room(id string) (*room, error) {
	if r := c.rooms[id]; r != nil {
		return r, nil
	}
	return nil, ErrUnknownRoom
}

// Has says whether this engine made the room (E4).
func (c *Chats) Has(id string) bool { return c.rooms[id] != nil }

// IDs are the room's thread: `thread` (most calls), `long` (unsend, mark read) and `key` (uploads).
func (c *Chats) IDs(id string) (thread, long, key string, err error) {
	r, err := c.room(id)
	if err != nil {
		return "", "", "", err
	}
	return r.thread, r.long, r.key, nil
}

// Thread is a thread from a mailbox page or a read, as a fresh window of its room. A read's answer leaves `folder`
// empty (only mailbox pages fill it, P0), so a re-read keeps the tab the room had, or opening a General chat would
// move it to Chats; and it weighs our own watermark (`readUpTo`).
func (c *Chats) Thread(t Thread) Envelope {
	id := RoomID(c.Account, t.ID)
	r := c.rooms[id]
	var readUpTo int64
	if r != nil {
		readUpTo = r.readUpTo
		if t.Folder == "" && r.isGeneral() {
			t.Folder = "GENERAL"
		}
	} else {
		r = &room{state: map[string]map[string]Event{}}
		c.rooms[id] = r
	}
	env := snapshot(t, c.Account, c.Name, c.Avatar, readUpTo)
	r.apply(*env.Update)
	r.thread = t.ID
	if t.ThreadID != "" {
		r.long = t.ThreadID
		c.byLong[t.ThreadID] = id
	}
	if t.ThreadKey != "" {
		r.key = t.ThreadKey
	}
	for _, u := range t.Users {
		if u.ID != "" && u.FBID != "" {
			c.fbidByUserID[u.ID] = u.FBID
		}
	}
	return env
}

// Remove forgets a deleted thread's room.
func (c *Chats) Remove(id string) []Envelope {
	r := c.rooms[id]
	if r == nil {
		return nil
	}
	delete(c.rooms, id)
	if c.byLong[r.long] == id {
		delete(c.byLong, r.long)
	}
	return []Envelope{{Kind: "RoomRemoved", Room: id}}
}

// Older is where the room's next older page starts: its thread and cursor ("" or StartToken: nothing older).
func (c *Chats) Older(id string) (thread, cursor string, err error) {
	r, err := c.room(id)
	if err != nil {
		return "", "", err
	}
	return r.thread, r.prevBatch, nil
}

// Prepend is the page Instagram answered from `cursor` (nil: nothing older), also prepended to the engine's copy.
func (c *Chats) Prepend(id, cursor string, t *Thread) MessagesPage {
	p := page(t, c.Account)
	if r := c.rooms[id]; r != nil {
		r.prepend(p, cursor)
	}
	return p
}

// Unread marks the chat unread again ("Seen" failed: the next open tries again).
func (c *Chats) Unread(id string) []Envelope {
	if r := c.rooms[id]; r != nil {
		return []Envelope{c.put(id, r, unread(1))}
	}
	return nil
}

// Unresolved is the share "Load video" fetches: its instagram.com link and Instagram's ID for it.
func (c *Chats) Unresolved(id, message string) (target, targetID string, err error) {
	r, err := c.room(id)
	if err != nil {
		return "", "", err
	}
	if e := r.event(message); e != nil {
		u := obj(r.currentContent(e)["com.beeper.unresolved_media"])
		target, _ = u["target_url"].(string)
		targetID, _ = u["target_id"].(string)
	}
	if target == "" {
		return "", "", errors.New("nothing to load")
	}
	return target, targetID, nil
}

// Resolved is the share's media in place of its card, as a hidden edit.
func (c *Chats) Resolved(id, message string, m Resolved) ([]Envelope, error) {
	r, err := c.room(id)
	if err != nil {
		return nil, err
	}
	e := r.event(message)
	if e == nil {
		return nil, errors.New("no such message in this chat")
	}
	return []Envelope{c.put(id, r, timeline(resolvedEvent(m, *e, r.currentContent(e))))}, nil
}

// TypingTimer is when a "typing…" ends by itself: Instagram holds it for the notice's TTL unless another comes.
type TypingTimer struct {
	room, user string
	gen        int
}

// Typing is someone's typing notice (the thread's long ID, their Instagram user ID). On, it comes with the timer to
// set for its TTL.
func (c *Chats) Typing(long string, senderID int64, on bool) ([]Envelope, *TypingTimer) {
	id := c.byLong[long]
	r, sender := c.rooms[id], c.fbidByUserID[strconv.FormatInt(senderID, 10)]
	if r == nil || sender == "" || sender == c.Account {
		return nil, nil
	}
	user, key := User(sender), id+"/"+User(sender)
	c.typingGen[key]++
	out := []Envelope{c.put(id, r, typingUpdate(user, on, r.typing))}
	if !on {
		return out, nil
	}
	return out, &TypingTimer{id, user, c.typingGen[key]}
}

// TypingTimeout ends a "typing…" whose TTL ran out, unless a newer notice from them came since.
func (c *Chats) TypingTimeout(t TypingTimer) []Envelope {
	r := c.rooms[t.room]
	if r == nil || c.typingGen[t.room+"/"+t.user] != t.gen || !slices.Contains(r.typing, t.user) {
		return nil
	}
	return []Envelope{c.put(t.room, r, typingUpdate(t.user, false, r.typing))}
}

// Delta is one live change (Instagram's own JSON: upstream drops fields it doesn't know, like `ig_inbox_folder`),
// applied to its room. `reread` is a thread to read in full and pass to `Thread`: a new chat, or a change this copy
// can't apply by itself (a reaction from before this launch, a new name, picture, member or folder).
func (c *Chats) Delta(raw []byte) (out []Envelope, reread string) {
	var d delta
	if json.Unmarshal(raw, &d) != nil || d.ThreadFBID == "" {
		return nil, ""
	}
	id := RoomID(c.Account, d.ThreadFBID)
	r := c.rooms[id]
	if r == nil {
		if d.Typename == "SlideUQPPNewMessage" { // a new DM or request
			return nil, d.ThreadFBID
		}
		return nil, ""
	}
	if d.Message != nil {
		if e := relatedEvent(*d.Message, c.Account); e != nil {
			out = append(out, Envelope{Kind: "Room", Room: id, Related: []Event{*e}})
		}
	}
	apply := func(j JoinedRoom) { out = append(out, c.put(id, r, j)) }
	switch d.Typename {
	case "SlideUQPPReadReceipt": // someone's "Seen", on the newest message they'd seen
		rr := d.ReadReceipt
		if rr == nil || rr.FBID == "" || rr.FBID == c.Account {
			break
		}
		if seen := r.lastBase(parseMS(rr.WatermarkMS)); seen != nil {
			apply(JoinedRoom{Ephemeral: &EventList{[]Event{receiptEvent(read{User(rr.FBID), seen.EventID, parseMS(rr.WatermarkMS)})}}})
		}
	case "SlideUQPPMarkRead": // read here or on another device, and how far: the "New messages" line starts after it
		ms, err := strconv.ParseInt(d.ReadTimestampMS, 10, 64)
		limit := ms
		if err != nil {
			limit = -1
		}
		seen, at := r.lastBase(limit), ms
		var seenID string
		if seen != nil {
			seenID = seen.EventID
			if err != nil {
				at = seen.OriginServerTS
			}
		}
		apply(readUpdate(seenID, at))
	case "SlideUQPPCreateReaction", "SlideUQPPDeleteReaction", "SlideUQPPEditMessage", "SlideUQPPDeleteMessage":
		j, refresh := change(d, c.Account, r.events)
		if refresh {
			return out, d.ThreadFBID
		}
		if j == nil {
			break
		}
		apply(*j)
		// An unread message unsent: the chat is read again when what's left ends with ours (seen live in P3).
		if last := r.lastMessage(); d.Typename == "SlideUQPPDeleteMessage" && r.unread > 0 && last != nil && last.Sender == Me {
			apply(unread(0))
		}
	case "SlideUQPPIGMoveThread": // moved between Primary and General (upstream doesn't map it; the raw delta has it)
		var j *JoinedRoom
		if folder := d.IGInboxFolder; folder != nil {
			j = r.bridgeUpdate(func(channel map[string]any) {
				if *folder == "GENERAL" {
					channel[inboxFolderKey] = "GENERAL"
				} else {
					delete(channel, inboxFolderKey)
				}
			})
		}
		if j == nil {
			return out, d.ThreadFBID
		}
		apply(*j)
	case "SlideUQPPThreadName", "SlideUQPPThreadImage", "SlideUQPPParticipantJoin", "SlideUQPPParticipantLeave",
		"SlideUQPPUpdateThreadFolder": // a request accepted or moved elsewhere
		return out, d.ThreadFBID
	case "SlideUQPPDeleteThread": // here or on another device: the room goes
		return append(out, c.Remove(id)...), ""
	case "SlideUQPPNewMessage":
		m := d.Message
		if m == nil || !m.isShown() {
			break
		}
		j := timeline(messageEvents(*m, c.Account)...)
		if m.SenderFBID == c.Account {
			j.UnreadNotifications = &Unread{}
		} else if d.ThreadReadStateEffect == "MARK_UNREAD" {
			j.UnreadNotifications = &Unread{NotificationCount: 1}
		}
		apply(j)
		// Their message ends their typing: Instagram sends no "stopped" with it, so "typing…" held for its 22 s TTL.
		if u := User(m.SenderFBID); slices.Contains(r.typing, u) {
			apply(typingUpdate(u, false, r.typing))
		}
	case "SlideUQPPIGMarkThreadUnread":
		apply(unread(count(d.MarkedAsUnread)))
	}
	return out, ""
}

// The delta fields the app applies; the rest are skipped.
type delta struct {
	Typename              string       `json:"__typename"`
	ThreadFBID            string       `json:"thread_fbid"`
	Message               *Message     `json:"message"`
	ThreadReadStateEffect string       `json:"thread_read_state_effect"`
	MarkedAsUnread        bool         `json:"marked_as_unread"`
	ReadReceipt           *ReadReceipt `json:"read_receipt"`
	// Reactions, edits and unsends: the message they're about.
	MessageID             string    `json:"message_id"`
	Reaction              *Reaction `json:"reaction"`
	TextBody              *string   `json:"text_body"`
	SlideEditHistoryEntry struct {
		TimestampMS string `json:"timestamp_ms"`
	} `json:"slide_edit_history_entry"`
	IGInboxFolder   *string `json:"ig_inbox_folder"`   // `SlideUQPPIGMoveThread`: the tab it moved to
	ReadTimestampMS string  `json:"read_timestamp_ms"` // `SlideUQPPMarkRead`: how far we've read, here or elsewhere
}

// change is what a reaction, edit or unsend does to its room: it needs the message it's about (`events`, the room's
// window). `refresh` when the window doesn't have it (a reaction from before this launch): re-read the thread.
func change(d delta, account string, events []Event) (j *JoinedRoom, refresh bool) {
	now := func(ms string) int64 {
		if n, err := strconv.ParseInt(ms, 10, 64); err == nil {
			return n
		}
		if len(events) > 0 {
			return events[len(events)-1].OriginServerTS
		}
		return 0
	}
	find := func(id string) *Event {
		for i := range events {
			if events[i].EventID == id {
				return &events[i]
			}
		}
		return nil
	}
	if d.MessageID == "" {
		return nil, false
	}
	target := find(d.MessageID)
	update := func(e Event) (*JoinedRoom, bool) { j := timeline(e); return &j, false }
	switch d.Typename {
	case "SlideUQPPCreateReaction":
		r := d.Reaction
		if r == nil || r.Reaction == "" || r.LogID == "" {
			return nil, false
		}
		return update(Event{Type: "m.reaction", Content: map[string]any{"m.relates_to": map[string]any{
			"rel_type": "m.annotation", "event_id": d.MessageID, "key": r.Reaction,
		}}, EventID: r.LogID, Sender: senderID(r.SenderFBID, account), OriginServerTS: now(r.TimestampMS)})
	case "SlideUQPPDeleteReaction":
		if d.Reaction == nil || d.Reaction.LogID == "" {
			return nil, true
		}
		reaction := find(d.Reaction.LogID)
		if reaction == nil {
			return nil, true
		}
		return update(redaction(d.Reaction.LogID, nonEmpty(reaction.Sender, Me), now("")))
	case "SlideUQPPEditMessage":
		if target == nil || d.TextBody == nil {
			return nil, true
		}
		ms := now(d.SlideEditHistoryEntry.TimestampMS)
		return update(Event{Type: "m.room.message", Content: map[string]any{
			"msgtype": "m.text", "body": "* " + *d.TextBody, "m.new_content": text(*d.TextBody),
			"m.relates_to": map[string]any{"rel_type": "m.replace", "event_id": d.MessageID},
		}, EventID: d.MessageID + "~edit" + strconv.FormatInt(ms, 10), Sender: target.Sender, OriginServerTS: ms})
	case "SlideUQPPDeleteMessage":
		if target == nil { // unsent before we saw it: nothing to show
			return nil, false
		}
		return update(redaction(d.MessageID, nonEmpty(target.Sender, Me), now("")))
	}
	return nil, false
}
