package engine

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/luisten/ferry-messenger/core/chat"
)

// The relay's mode (ListenOnly): each call that would act as the account is refused before Instagram. The account
// has no client at all, so a call that got through would panic instead of passing. ListenOnly is for good, so this
// package's other tests mustn't need the app's mode (none does).
func TestListenOnlyRefusesEveryActionBeforeInstagram(t *testing.T) {
	ListenOnly()
	var login struct {
		Account string          `json:"account"`
		Mailbox json.RawMessage `json:"mailbox"`
	}
	b, err := os.ReadFile("../testdata/ig_login_tamo.json")
	if err == nil {
		err = json.Unmarshal(b, &login)
	}
	threads, _, err2 := chat.Mailbox(login.Mailbox)
	if err != nil || err2 != nil || len(threads) == 0 {
		t.Fatal(err, err2)
	}
	c := chat.New(login.Account)
	room := c.Load(threads[0])[0].Room
	draft, _ := c.Draft(chat.Contact{ID: "17841400000000999", Name: "Sample"})
	a := &account{id: login.Account, ctx: context.Background(), count: &counter{n: map[string]int{}}, chats: &book{Chats: c}}
	mu.Lock()
	accounts[a.id] = a
	mu.Unlock()
	defer func() { mu.Lock(); delete(accounts, a.id); mu.Unlock() }()

	for name, call := range map[string]func() (any, error){
		"send":          func() (any, error) { return Send(room, "hi", "", newOTID()) },
		"send to draft": func() (any, error) { return Send(draft, "hi", "", newOTID()) },
		"send media":    func() (any, error) { return SendMedia(room, "/dev/null", "image/jpeg", false, "", newOTID()) },
		"accept":        func() (any, error) { return Accept(room) },
		"delete":        func() (any, error) { return DeleteThread(room) },
		"load video":    func() (any, error) { return ResolveMedia(room, "m") },
		"react":         func() (any, error) { return React(room, "m", "❤️", false) },
		"edit":          func() (any, error) { return Edit(room, "m", "x") },
		"unsend":        func() (any, error) { return Unsend(room, "m") },
		"seen":          func() (any, error) { return MarkRead(room) },
		"typing":        func() (any, error) { return Typing(room, true) },
	} {
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Errorf("%s reached Instagram: %v", name, r)
				}
			}()
			if _, err := call(); err == nil || !strings.Contains(err.Error(), "listen-only") {
				t.Errorf("%s: %v", name, err)
			}
		}()
	}

	// Its chats change as they do for the app, but only R6's notifications are queued.
	NextEvent(time.Millisecond)
	a.chats.Since = 1
	a.do(func(c *chat.Chats) []chat.Envelope { return c.Load(threads[0]) })
	var events []map[string]any
	_ = json.Unmarshal(NextEvent(time.Second), &events)
	if len(events) == 0 {
		t.Error("nothing queued")
	}
	for _, e := range events {
		if e["kind"] != "Notify" || e["room"] != room || e["account"] != a.id {
			t.Errorf("queued %v", e)
		}
	}
}
