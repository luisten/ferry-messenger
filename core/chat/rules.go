package chat

import (
	"errors"
	"slices"
	"strings"
)

// Instagram's rules (docs/PLAN-android.md stage 2): how often a chat is read again, when "Seen" and typing go out,
// what a request allows, New Message's drafts, when a web push channel is registered. They decide how many Instagram
// actions the apps spend, so both apps get them from here. Each decides from the engine's copy; the C API makes the
// requests it says to make. Times are Unix ms, passed in.

const (
	reReadAfter  = 30_000  // opening a chat reads it again at most every 30 s
	typingEvery  = 20_000  // one "typing" per 20 s (Instagram holds it for 22)
	editMaxAge   = 900_000 // edits within 15 minutes (`Timeline.editMaxAge`)
	editMaxCount = 5       // at most 5 (`Timeline.editMaxCount`)
	// MaxPages is how many pages of each mailbox folder load after a login.
	// ponytail: at most 20 a folder per launch; page on scroll if real inboxes outgrow that.
	MaxPages = 20
)

var (
	ErrRequest    = errors.New("Accept the request first.")
	ErrNotOwn     = errors.New("Only your own messages can be changed.")
	ErrNotEditing = errors.New("This message can't be edited any more.")
)

// Folders are the mailbox folders a login loads after its first page, in order: the rest of the inbox (`INBOX`, from
// the first page's cursor), then Requests, then General on professional accounts. As the bridge did (`chatsync.go:91`),
// so search and counts see every chat.
func Folders(professional bool) []string {
	if professional {
		return []string{"INBOX", "PENDING", "GENERAL"}
	}
	return []string{"INBOX", "PENDING"}
}

func (r *room) isRequest() bool {
	b := r.bridge()
	return b != nil && obj(b.Content["channel"])["com.beeper.message_request"] == true
}

// Open is a chat opened in the app: `read` says to read it in full (the mailbox's copy of a message has no reactions
// or edit history, P1), at most every 30 s. A read; it sends nothing.
func (c *Chats) Open(id string, now int64) (read bool, err error) {
	if _, err := c.room(id); err != nil {
		return false, err
	}
	if now-c.readAt[id] < reReadAfter {
		return false, nil
	}
	c.readAt[id] = now
	return true, nil
}

// Reading is a read made for another reason (fresh media links after a failed download): the next open counts from it.
func (c *Chats) Reading(id string, now int64) { c.readAt[id] = now }

// MarkRead is "Seen" on the newest incoming message, only where the other person may see it (not a request) and only
// when the chat is unread (Instagram has our read otherwise: a reopen sent a needless "Seen" in P4). The chat reads at
// once, with our m.read there. `long` "" means nothing to send.
func (c *Chats) MarkRead(id string) (out []Envelope, long, message string, ms int64, err error) {
	r, err := c.room(id)
	if err != nil {
		return nil, "", "", 0, err
	}
	if r.isRequest() || r.unread == 0 || r.long == "" {
		return nil, "", "", 0, nil
	}
	target := r.lastMessageWhere(func(e *Event) bool { return e.Sender != Me })
	if target == nil {
		return nil, "", "", 0, nil
	}
	return []Envelope{c.put(id, r, readUpdate(target.EventID, target.OriginServerTS))}, r.long, target.EventID, target.OriginServerTS, nil
}

// SetTyping is the composer's typing state: "typing" at most once per 20 s, "stopped" only after a "typing", never in
// a request. `send` says to tell Instagram.
func (c *Chats) SetTyping(id string, on bool, now int64) (send bool, err error) {
	r, err := c.room(id)
	if err != nil {
		return false, err
	}
	if r.isRequest() {
		return false, nil
	}
	since, typing := c.typingAt[id]
	if on {
		if typing && now-since < typingEvery {
			return false, nil
		}
		c.typingAt[id] = now
		return true, nil
	}
	delete(c.typingAt, id)
	return typing, nil
}

// BeforeSend is what goes before a message: a request is accepted first (a reply accepts it, as the bridge did), and
// "typing" stops if we'd said it (`typingOff`).
func (c *Chats) BeforeSend(id string) (accept, typingOff bool, err error) {
	r, err := c.room(id)
	if err != nil {
		return false, false, err
	}
	_, typingOff = c.typingAt[id]
	delete(c.typingAt, id)
	return r.isRequest(), typingOff, nil
}

// CanReact refuses a reaction in a request: the other person would see that we'd read it.
func (c *Chats) CanReact(id string) error {
	r, err := c.room(id)
	if err == nil && r.isRequest() {
		err = ErrRequest
	}
	return err
}

// CanUnsend allows only our own messages, outside requests.
func (c *Chats) CanUnsend(id, message string) error {
	if err := c.CanReact(id); err != nil {
		return err
	}
	if e := c.rooms[id].event(message); e == nil || e.Sender != Me {
		return ErrNotOwn
	}
	return nil
}

// CanEdit allows our own texts, outside requests, within 15 minutes and 5 edits (`Timeline.canEdit`, which hides the
// menu item; edits with the same text count once, as Instagram's echo of ours repeats it).
func (c *Chats) CanEdit(id, message string, now int64) error {
	if err := c.CanUnsend(id, message); err != nil {
		return err
	}
	r := c.rooms[id]
	base := r.event(message)
	content := r.currentContent(base)
	isText := content["msgtype"] == "m.text" && !has(content, "external_url") && len(arr(content["com.beeper.linkpreviews"])) == 0
	if !isText || now-base.OriginServerTS >= editMaxAge || r.editCount(base) >= editMaxCount {
		return ErrNotEditing
	}
	return nil
}

// editCount is how many different texts a message has been edited to.
func (r *room) editCount(base *Event) int {
	unsent := map[string]bool{}
	for _, e := range r.events {
		if e.Type == "m.room.redaction" {
			if id, ok := e.Content["redacts"].(string); ok {
				unsent[id] = true
			}
		}
	}
	var texts []string
	for _, e := range r.events {
		next := obj(e.Content["m.new_content"])
		if e.replaces() != base.EventID || e.Sender != base.Sender || next == nil || unsent[e.EventID] || e.Unsigned != nil && e.Unsigned.RedactedBecause != nil {
			continue
		}
		text, _ := next["body"].(string)
		kind, _ := next["msgtype"].(string)
		if !slices.Contains(texts, kind+"\n"+text) {
			texts = append(texts, kind+"\n"+text)
		}
	}
	return len(texts)
}

// lastMessageWhere is the newest message that is neither an edit nor unsent, among those `match` keeps.
func (r *room) lastMessageWhere(match func(*Event) bool) *Event {
	unsent := map[string]bool{}
	for _, e := range r.events {
		if e.Type == "m.room.redaction" {
			if id, ok := e.Content["redacts"].(string); ok {
				unsent[id] = true
			}
		}
	}
	for i := len(r.events) - 1; i >= 0; i-- {
		if e := &r.events[i]; e.isBase() && (e.Unsigned == nil || e.Unsigned.RedactedBecause == nil) && !unsent[e.EventID] && match(e) {
			return e
		}
	}
	return nil
}

// ExistingDM is our room with `user` on this account, "" when we have none.
func (c *Chats) ExistingDM(user string) string {
	for id, r := range c.rooms {
		if b := r.bridge(); b != nil && b.Content["com.beeper.room_type"] == "dm" && obj(b.Content["channel"])["id"] == user {
			return id
		}
	}
	return ""
}

// PushRoom is the room a push names (docs/PLAN-push.md): the thread's long ID, else (not for a group's) a DM with its
// sender's Instagram user ID; "" when this account hasn't loaded that chat (the app opens the inbox).
func (c *Chats) PushRoom(long, user string, group bool) string {
	if id := c.byLong[long]; id != "" && c.rooms[id] != nil {
		return id
	}
	if fbid := c.fbidByUserID[user]; fbid != "" && !group {
		return c.ExistingDM(fbid)
	}
	return ""
}

// ponytail: a week is a guess; step 4's soak says whether Instagram drops registrations sooner.
const registerEvery = 7 * 24 * 3600_000

// PushRegister says whether to register an account's web push channel with Instagram now (one request): the channel's
// endpoint isn't the one registered, the account logged in since (a new web session, `loginAt`; 0 for a stored one),
// or a week has passed.
func PushRegister(endpoint, registered string, registeredAt, loginAt, now int64) bool {
	return endpoint != registered || registeredAt < loginAt || now-registeredAt >= registerEvery
}

// DraftID is the chat with someone we've never messaged: Instagram has no thread until the first message.
func DraftID(account, user string) string { return "!ig-" + account + "-new-" + user }

// Draft is that chat (`Draft`, kept apart from the inbox's rooms, so the inbox and search never show an empty chat),
// or nothing new when it exists already. The first message makes the thread (`DraftRecipient`); when it arrives,
// `Load` leads the draft to it (`RoomMoved`).
func (c *Chats) Draft(contact Contact) (id string, out []Envelope) {
	id = DraftID(c.Account, contact.ID)
	if _, ok := c.drafts[id]; ok {
		return id, nil
	}
	c.drafts[id] = contact.ID
	handle := ""
	for _, i := range contact.Identifiers {
		if h, ok := strings.CutPrefix(i, "instagram:"); ok && h != "" {
			handle = h
			break
		}
	}
	name := nonEmpty(contact.Name, handle, "New chat")
	bridge := map[string]any{"protocol": map[string]any{"id": protocolID, "displayname": "Instagram"}, "com.beeper.room_type": "dm",
		"channel": map[string]any{"id": contact.ID, "displayname": name, "fi.mau.receiver": c.Account}}
	state := []Event{stateEvent("m.bridge", "instagram", bridge), stateEvent("m.room.name", "", map[string]any{"name": name}),
		member(Me, c.Name, c.Avatar), member(User(contact.ID), name, contact.AvatarURL)}
	if contact.AvatarURL != "" {
		state = append(state, stateEvent("m.room.avatar", "", map[string]any{"url": contact.AvatarURL}))
	}
	return id, []Envelope{{Kind: "Draft", Room: id,
		Update:   &JoinedRoom{State: &EventList{state}, Timeline: &Timeline{Events: []Event{}, Limited: true, PrevBatch: StartToken}},
		Profiles: map[string]Profile{User(contact.ID): {Name: contact.Name, AvatarURL: contact.AvatarURL, Handle: handle}}}}
}

// DraftRecipient is whom a draft's first message goes to (Instagram makes the thread with it).
func (c *Chats) DraftRecipient(id string) (user string, ok bool) {
	user, ok = c.drafts[id]
	return user, ok
}

// Load is a thread from a mailbox page or a read, with what follows from it: the draft it replaces moves there, and
// (DEBUG) the chat shown as a request is one here too.
func (c *Chats) Load(t Thread) []Envelope {
	env := c.Thread(t)
	out := []Envelope{env}
	r := c.rooms[env.Room]
	if b := r.bridge(); b != nil && b.Content["com.beeper.room_type"] == "dm" {
		user, _ := obj(b.Content["channel"])["id"].(string)
		if draft := DraftID(c.Account, user); c.drafts[draft] != "" {
			delete(c.drafts, draft)
			out = append(out, Envelope{Kind: "RoomMoved", Room: draft, To: env.Room})
		}
	}
	if env.Room == c.ForcedRequest && !r.isRequest() {
		if j := r.bridgeUpdate(func(channel map[string]any) { channel["com.beeper.message_request"] = true }); j != nil {
			out = append(out, c.put(env.Room, r, *j))
		}
	}
	return out
}
