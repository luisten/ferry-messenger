package chat

import (
	"fmt"
	"strings"
)

// R6 (docs/PLAN-relay.md): what the relay notifies. New messages from others as they arrive; never history, the
// first load, our own, requests, General, reactions, edits, unsends or Instagram's own lines ("… named the group").
// "New" is newer than both `Since` (when the relay started listening) and anything this account has seen in the
// chat, notified or not: a reload after a resnapshot never notifies the same message again, and a request accepted
// elsewhere doesn't notify its old messages.

// Notification is one message to notify, as R5 shows it: from whom (`@handle`, else their name), the group's name ("" in
// a DM), and what it says (the text, or a line for media).
type Notification struct {
	Room  string `json:"room"`
	From  string `json:"from"`
	Group string `json:"group,omitempty"`
	Body  string `json:"body"`
	At    int64  `json:"at"`
}

// Notifications is what these updates (just applied, from Load or Delta) bring to notify.
func (c *Chats) Notifications(out []Envelope) (notes []Notification) {
	if c.Since == 0 {
		return nil
	}
	for _, env := range out {
		if env.Kind == "RoomRemoved" {
			delete(c.seen, env.Room)
		}
		r := c.rooms[env.Room]
		if env.Kind != "Room" || env.Update == nil || env.Update.Timeline == nil || r == nil {
			continue
		}
		quiet := r.isRequest() || r.isGeneral()
		mark := max(c.Since, c.seen[env.Room])
		for _, e := range env.Update.Timeline.Events {
			if !e.isBase() {
				continue
			}
			c.seen[env.Room] = max(c.seen[env.Room], e.OriginServerTS)
			if quiet || e.OriginServerTS <= mark || e.Sender == Me || e.Content[eventKey] == true {
				continue
			}
			notes = append(notes, Notification{Room: env.Room, From: c.from(r, e.Sender), Group: r.groupName(),
				Body: notificationBody(e.Content), At: e.OriginServerTS})
		}
	}
	return notes
}

func (c *Chats) from(r *room, user string) string {
	if h := c.handles[user]; h != "" {
		return "@" + h
	}
	if m, ok := r.state["m.room.member"][user]; ok {
		if name, _ := m.Content["displayname"].(string); name != "" {
			return name
		}
	}
	return "Someone"
}

func (r *room) groupName() string {
	if b := r.bridge(); b == nil || b.Content["com.beeper.room_type"] == "dm" {
		return ""
	}
	name, _ := r.state["m.room.name"][""].Content["name"].(string)
	return name
}

// notificationBody is a message's text, or a line for what it is.
func notificationBody(c map[string]any) string {
	body, _ := c["body"].(string)
	if s, _ := c[shareTextKey].(string); s != "" {
		return s
	}
	if all, _ := c[albumKey].([]any); len(all) > 1 {
		return fmt.Sprintf("Sent %d photos", len(all))
	}
	if _, share := c["external_url"]; share {
		return body // Instagram's line, or "Sent a reel"
	}
	switch c["msgtype"] {
	case "m.image":
		switch {
		case c[stickerKey] == true:
			return "Sent a sticker"
		case obj(c["info"])["fi.mau.gif"] == true:
			return "Sent a GIF"
		}
		return "Sent a photo"
	case "m.video":
		return "Sent a video"
	case "m.audio":
		return "Sent a voice message"
	}
	return strings.TrimSpace(body)
}
