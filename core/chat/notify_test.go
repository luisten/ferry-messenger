package chat

import (
	"slices"
	"testing"
)

// R6 on P0's run as tamoveska's socket delivered it: the relay started listening a second before kivostudio's first
// message. Their two texts notify; the first load, our own message, reactions, the edit, the unsend, "Seen" and
// receipts don't, and neither does the thread loaded again afterwards (a resnapshot, or a new chat's read).
func TestTheRelayNotifiesNewMessagesFromOthersOnly(t *testing.T) {
	c := New(tamo)
	c.Since = 1_792_172_793_284 - 1000
	var notes []Notification
	for _, env := range [][]Envelope{c.Load(dm(t, "ig_login_tamo"))} {
		notes = append(notes, c.Notifications(env)...)
	}
	if len(notes) != 0 {
		t.Fatalf("the first load notified %v", notes)
	}
	for _, d := range deltas(t) {
		out, _ := c.Delta(d)
		notes = append(notes, c.Notifications(out)...)
	}
	room := RoomID(tamo, dm(t, "ig_login_tamo").ID)
	want := []Notification{
		{Room: room, From: "@kivostudio", Body: "P0 capture: hello", At: 1_792_172_793_284},
		{Room: room, From: "@kivostudio", Body: "P0 capture: a reply", At: 1_792_172_798_126},
	}
	if !slices.Equal(notes, want) {
		t.Errorf("notified %+v", notes)
	}
	if again := append(c.Notifications(c.Load(thread(t))), c.Notifications(c.Load(dm(t, "ig_login_tamo")))...); len(again) != 0 {
		t.Errorf("a reload notified again: %+v", again)
	}
}

// Requests and General never notify, nor do their messages later, once the chat moves to Primary (a request accepted
// elsewhere). An engine that isn't the relay's (`Since` 0) notifies nothing.
func TestRequestsGeneralAndTheAppsEngineDontNotify(t *testing.T) {
	for _, folder := range []struct{ folder, system string }{{"GENERAL", ""}, {"PRIMARY", "PENDING"}, {"PRIMARY", "SPAM"}} {
		c := New(kivo)
		c.Since = 1
		th := dm(t, "ig_login_kivo")
		th.Folder, th.SystemFolder = folder.folder, folder.system
		if notes := c.Notifications(c.Load(th)); len(notes) != 0 {
			t.Errorf("%v notified %v", folder, notes)
		}
		th.Folder, th.SystemFolder = "PRIMARY", ""
		if notes := c.Notifications(c.Load(th)); len(notes) != 0 {
			t.Errorf("moved from %v, notified %v", folder, notes)
		}
	}
	if notes := New(kivo).Notifications(New(kivo).Load(dm(t, "ig_login_kivo"))); notes != nil {
		t.Errorf("Since 0 notified %v", notes)
	}
	// The same chat new to a relay that started before it: tamoveska's newest message notifies, from her @handle.
	c := New(kivo)
	c.Since = 1
	notes := c.Notifications(c.Load(dm(t, "ig_login_kivo")))
	if len(notes) == 0 || notes[0].From != "@tamoveska" || notes[0].Group != "" {
		t.Errorf("a new chat: %+v", notes)
	}
}

func TestAGroupNotifiesUnderItsName(t *testing.T) {
	c := New(kivo)
	c.Since = 1
	th := dm(t, "ig_login_kivo")
	th.IsGroup, th.ThreadTitle = true, "Sample group"
	notes := c.Notifications(c.Load(th))
	if len(notes) == 0 || notes[0].Group != "Sample group" || notes[0].From != "@tamoveska" {
		t.Errorf("%+v", notes)
	}
}

func TestNotificationBodies(t *testing.T) {
	photo := map[string]any{"msgtype": "m.image", "body": "Photo"}
	for _, c := range []struct {
		content map[string]any
		want    string
	}{
		{text("hi there"), "hi there"},
		{photo, "Sent a photo"},
		{map[string]any{"msgtype": "m.image", "body": "Photo", albumKey: []any{photo, photo, photo}}, "Sent 3 photos"},
		{map[string]any{"msgtype": "m.image", "body": "Sticker", stickerKey: true}, "Sent a sticker"},
		{map[string]any{"msgtype": "m.image", "body": "GIF", "info": map[string]any{"fi.mau.gif": true}}, "Sent a GIF"},
		{map[string]any{"msgtype": "m.video", "body": "Video"}, "Sent a video"},
		{map[string]any{"msgtype": "m.audio", "body": "Voice message"}, "Sent a voice message"},
		{map[string]any{"msgtype": "m.video", "body": "Sent a reel", "external_url": "https://www.instagram.com/reel/x/"}, "Sent a reel"},
		{map[string]any{"msgtype": "m.video", "body": "Sent a story", "external_url": "x", shareTextKey: "😂"}, "😂"},
		{map[string]any{"msgtype": "m.notice", "body": "Sent a poll", unsupportedKey: "a poll"}, "Sent a poll"},
	} {
		if got := notificationBody(c.content); got != c.want {
			t.Errorf("%v: %q", c.content, got)
		}
	}
}
