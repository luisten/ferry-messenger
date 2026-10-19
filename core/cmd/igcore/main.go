// The C API the app calls: instameow (mautrix's Instagram client), one client per Instagram account, JSON in and out
// (docs/PLAN-core.md §3). Instagram's data becomes chats here (core/chat, docs/PLAN-android.md stage 1): every change
// to a chat reaches the app through IGNextEvent, in the order the engine made it, as `{"kind": "Room", "room",
// "update", "profiles", "related"}` or `{"kind": "RoomRemoved", "room"}`; a call that changes chats returns the
// `seq` of its last update, so the app can wait until it has applied it. The state dump (web tokens), cookies and
// the viewer's contact details never cross.
//
// IDs: `account` is the account's FBID (the bridge's login ID). Chats are named by their room ID
// (`!ig-<account>-<thread>`, made by the engine; a room it didn't make is refused). `message` is Message.id.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"github.com/rs/zerolog"
	"go.mau.fi/util/jsontime"

	"go.mau.fi/mautrix-meta/pkg/instameow"
	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"go.mau.fi/mautrix-meta/pkg/messagix/cookies"
	"go.mau.fi/mautrix-meta/pkg/messagix/httpclient"
	"go.mau.fi/mautrix-meta/pkg/messagix/responses"
	"go.mau.fi/mautrix-meta/pkg/messagix/types"

	"github.com/luisten/ferry-messenger/core/chat"
)

type account struct {
	id     string
	cli    *instameow.Client
	ctx    context.Context
	cancel context.CancelFunc
	count  *counter
	chats  *book
}

// book is an account's chats, kept across a re-login. Its lock is held while an update is queued, so the app gets
// them in the order they were applied here.
type book struct {
	sync.Mutex
	*chat.Chats
}

var (
	mu       sync.Mutex
	accounts = map[string]*account{}

	// The events waiting for the app. Never dropped: a lost room update would leave the app's copy silently wrong.
	qmu    sync.Mutex
	queue  [][]byte
	seq    int64
	queued = make(chan struct{}, 1)

	otids atomic.Int64

	captureDir atomic.Value // string; set only by DEBUG builds (IGSetCapture)
	captureSeq atomic.Int64
)

// C6: every HTTP request to Instagram, by GraphQL operation name (else method and path), per account.
type counter struct {
	next http.RoundTripper
	mu   sync.Mutex
	n    map[string]int
}

func (c *counter) RoundTrip(r *http.Request) (*http.Response, error) {
	name := r.Header.Get("x-fb-friendly-name")
	if name == "" {
		name = r.Method + " " + r.URL.Host + r.URL.Path
	}
	c.add(name)
	return c.next.RoundTrip(r)
}

func (c *counter) add(name string) {
	c.mu.Lock()
	c.n[name]++
	c.mu.Unlock()
}

func (c *counter) snapshot() map[string]int {
	c.mu.Lock()
	defer c.mu.Unlock()
	m := make(map[string]int, len(c.n))
	for k, v := range c.n {
		m[k] = v
	}
	return m
}

// Writes what Instagram answered into <dir>/<account>/, numbered in order. DEBUG builds only, for test fixtures.
func capture(acct, name string, b []byte) {
	dir, _ := captureDir.Load().(string)
	if dir == "" {
		return
	}
	dir = filepath.Join(dir, acct)
	if os.MkdirAll(dir, 0o700) != nil {
		return
	}
	_ = os.WriteFile(filepath.Join(dir, fmt.Sprintf("%05d-%s.json", captureSeq.Add(1), name)), b, 0o600)
}

// wire is Instagram's answer as JSON, what core/chat reads (and the captures hold).
func wire(acct, name string, v any, err error) ([]byte, error) {
	if err != nil {
		return nil, err
	}
	b, err := json.Marshal(v)
	if err == nil {
		capture(acct, name, b)
	}
	return b, err
}

// push queues events for the app (an account's event, or a chat's change) and returns the last one's `seq`.
func push(events ...any) int64 {
	qmu.Lock()
	for _, e := range events {
		seq++
		switch e := e.(type) {
		case map[string]any:
			e["seq"] = seq
		case *roomEvent:
			e.Seq = seq
		}
		b, _ := json.Marshal(e)
		queue = append(queue, b)
	}
	n := seq
	qmu.Unlock()
	select {
	case queued <- struct{}{}:
	default:
	}
	return n
}

type roomEvent struct {
	Account string `json:"account"`
	Seq     int64  `json:"seq"`
	chat.Envelope
}

// do changes the account's chats and queues what changed, in that order.
func (a *account) do(f func(c *chat.Chats) []chat.Envelope) int64 {
	a.chats.Lock()
	defer a.chats.Unlock()
	var events []any
	for _, e := range f(a.chats.Chats) {
		events = append(events, &roomEvent{Account: a.id, Envelope: e})
	}
	return push(events...)
}

// readThread reads one thread in full (a read; nothing is sent) into its room.
func (a *account) readThread(thread string) (room string, n int64, err error) {
	resp, err := a.cli.GetThread(a.ctx, slidetypes.MakeGetThreadInfoRequest(thread))
	b, err := wire(a.id, "thread", resp, err)
	if err != nil {
		return "", 0, err
	}
	t, err := chat.ReadThread(b)
	if err != nil {
		return "", 0, err
	}
	if t == nil {
		return "", 0, errors.New("Instagram has no such chat")
	}
	n = a.do(func(c *chat.Chats) []chat.Envelope { e := c.Thread(*t); room = e.Room; return []chat.Envelope{e} })
	return room, n, nil
}

func jsonOut(v any) *C.char {
	b, err := json.Marshal(v)
	if err != nil {
		return fail(err)
	}
	return C.CString(string(b))
}

func fail(err error) *C.char {
	state, reason := classify(err)
	b, _ := json.Marshal(map[string]string{"error": err.Error(), "code": state, "reason": reason})
	return C.CString(string(b))
}

// An error as the bridge's state names, so the app's Health reads it as before (igconnector client.go:172):
// BAD_CREDENTIALS when Instagram wants a new login (and why), TRANSIENT_DISCONNECT for the network, else UNKNOWN_ERROR.
func classify(err error) (state, reason string) {
	for _, c := range []struct {
		err    error
		reason string
	}{
		{httpclient.ErrTokenInvalidated, "logged_out"}, {httpclient.ErrChallengeRequired, "challenge"},
		{httpclient.ErrCheckpointRequired, "checkpoint"}, {httpclient.ErrConsentRequired, "consent"},
		{httpclient.ErrAccountSuspended, "suspended"},
	} {
		if errors.Is(err, c.err) {
			return "BAD_CREDENTIALS", c.reason
		}
	}
	var netErr net.Error
	if errors.As(err, &netErr) || errors.Is(err, context.DeadlineExceeded) {
		return "TRANSIENT_DISCONNECT", "network"
	}
	return "UNKNOWN_ERROR", ""
}

func get(acct string) (*account, error) {
	mu.Lock()
	defer mu.Unlock()
	if a := accounts[acct]; a != nil {
		return a, nil
	}
	return nil, errors.New("account not started")
}

// One library call for an account.
func call(acct *C.char, f func(a *account) (any, error)) *C.char {
	a, err := get(C.GoString(acct))
	if err != nil {
		return fail(err)
	}
	v, err := f(a)
	if err != nil {
		return fail(err)
	}
	return jsonOut(v)
}

type ids struct{ room, thread, long, key string }

// One library call for a chat this engine made (E4): DEBUG fixture rooms and New Message drafts never get here.
func roomCall(room *C.char, f func(a *account, r ids) (any, error)) *C.char {
	r := ids{room: C.GoString(room)}
	acct, _, _ := strings.Cut(strings.TrimPrefix(r.room, "!ig-"), "-")
	a, err := get(acct)
	if err != nil {
		return fail(err)
	}
	a.chats.Lock()
	r.thread, r.long, r.key, err = a.chats.IDs(r.room)
	a.chats.Unlock()
	if err != nil {
		return fail(err)
	}
	v, err := f(a, r)
	if err != nil {
		return fail(err)
	}
	return jsonOut(v)
}

func (a *account) handle(evt slidetypes.ClientEvent) error {
	if a.id == "" {
		return nil // before IGLogin knows the account: only LoadIndex's ReconnectionStateUpdate (seen in P0)
	}
	e := map[string]any{"account": a.id, "kind": fmt.Sprintf("%T", evt)[len("*slidetypes."):], "at": time.Now().UnixMilli()}
	switch evt := evt.(type) {
	case *slidetypes.Delta:
		e["delta"] = json.RawMessage(evt.Raw) // the wire JSON, unknown types (SlideUQPPIGMoveThread) included
	case *slidetypes.TypingNotification:
		e["thread"], e["typing"] = evt.ThreadID, evt
	case *slidetypes.Connected:
		a.count.add("socket connect")
	case *slidetypes.Disconnected:
		e["failures"] = evt.FailureCount
		if evt.Error != nil {
			e["error"] = evt.Error.Error()
		}
	case *slidetypes.AuthError:
		if evt.Error != nil {
			e["error"] = evt.Error.Error()
			e["code"], e["reason"] = classify(evt.Error)
		}
	}
	// SeqIDUpdate, ReconnectionStateUpdate (may hold session data), ResnapshotRequired: the kind only, captured.
	b, _ := json.Marshal(e)
	capture(a.id, "event-"+e["kind"].(string), b)

	switch evt := evt.(type) {
	case *slidetypes.Delta:
		var reread string
		a.do(func(c *chat.Chats) []chat.Envelope { out, r := c.Delta(evt.Raw); reread = r; return out })
		if reread != "" { // what AppModel did on `.refresh`: the same read, from here
			go func() { _, _, _ = a.readThread(reread) }()
		}
	case *slidetypes.TypingNotification:
		var timer *chat.TypingTimer
		a.do(func(c *chat.Chats) []chat.Envelope {
			out, t := c.Typing(evt.ThreadID, evt.SenderID, evt.ActivityStatus == 1)
			timer = t
			return out
		})
		if timer != nil {
			ttl := time.Duration(evt.TTL) * time.Millisecond
			if ttl <= 0 {
				ttl = 22 * time.Second
			}
			t := *timer
			time.AfterFunc(ttl, func() { a.do(func(c *chat.Chats) []chat.Envelope { return c.TypingTimeout(t) }) })
		}
	case *slidetypes.Connected, *slidetypes.Disconnected, *slidetypes.AuthError:
		push(e)
	}
	return nil
}

//export IGSetCapture
func IGSetCapture(dir *C.char) { captureDir.Store(C.GoString(dir)) }

// Logs in (or re-logs in) with the cookies from the web view, loads the index and mailbox, and connects the socket.
// The mailbox's chats are queued; the result is `{account, viewer, next, seq}`, `next` the mailbox's next page.
//
//export IGLogin
func IGLogin(cookiesJSON *C.char) *C.char {
	var raw map[cookies.MetaCookieName]string
	if err := json.Unmarshal([]byte(C.GoString(cookiesJSON)), &raw); err != nil {
		return fail(err)
	}
	c := &cookies.Cookies{Platform: types.Instagram}
	c.UpdateValues(raw)
	if missing := c.GetMissingCookieNames(); len(missing) > 0 {
		return fail(fmt.Errorf("missing cookies: %v", missing))
	}
	log := zerolog.New(os.Stderr).Level(zerolog.WarnLevel).With().Timestamp().Logger()
	a := &account{count: &counter{n: map[string]int{}}}
	cli := instameow.NewClient(instameow.ClientParams{
		Cookies: c, Log: log,
		EventHandler: func(_ context.Context, evt slidetypes.ClientEvent) error { return a.handle(evt) },
	})
	h := cli.GetHTTP()
	a.count.next = h.HTTP.Transport
	h.HTTP.Transport = a.count

	ctx, cancel := context.WithCancel(log.WithContext(context.Background()))
	viewer, mailbox, err := cli.LoadIndex(ctx)
	if err != nil {
		cancel()
		return fail(err)
	}
	fbid := cli.GetOwnFBID()
	if fbid == 0 {
		cancel()
		return fail(errors.New("logged in, but Instagram didn't say which account"))
	}
	id := strconv.FormatInt(fbid, 10)
	a.cli, a.ctx, a.cancel = cli, ctx, cancel

	mu.Lock()
	old := accounts[id]
	if old != nil {
		a.chats = old.chats
	} else {
		a.chats = &book{Chats: chat.New(id)}
	}
	a.id = id
	accounts[id] = a
	mu.Unlock()
	if old != nil {
		old.cancel()
		old.cli.Disconnect()
	}

	if mailbox != nil {
		mailbox.Token = ""
	}
	v := viewer.Data
	// Only what the app shows: the viewer also carries a business account's email and phone number.
	shown := map[string]any{
		"id": v.ID, "fbid": v.Fbid, "username": v.Username, "full_name": v.FullName,
		"profile_pic_url": v.ProfilePicURL, "is_professional_account": v.IsProfessionalAccount,
		"is_business_account": v.IsBusinessAccount, "has_tabbed_inbox": v.HasTabbedInbox,
	}
	capture(id, "login", must(json.Marshal(map[string]any{"account": id, "viewer": shown, "mailbox": mailbox})))
	threads, next, err := chat.Mailbox(must(json.Marshal(mailbox)))
	if err != nil {
		return fail(err)
	}
	n := a.do(func(c *chat.Chats) []chat.Envelope {
		c.Name, c.Avatar = v.FullName, v.ProfilePicURL
		var out []chat.Envelope
		for _, t := range threads {
			out = append(out, c.Thread(t))
		}
		return out
	})
	go cli.Connect(ctx) // after the chats are in: its live changes apply to them
	return jsonOut(map[string]any{"account": id, "viewer": shown, "next": nextPage(next), "seq": n})
}

// nextPage is a next page's cursor, null at the end (an empty one would ask for the first page again).
func nextPage(next string) *string {
	if next == "" {
		return nil
	}
	return &next
}

func must(b []byte, _ error) []byte { return b }

// Everything waiting for the app (a JSON array, oldest first), or nothing after `timeoutMS` without any.
//
//export IGNextEvent
func IGNextEvent(timeoutMS C.int) *C.char {
	timeout := time.NewTimer(time.Duration(timeoutMS) * time.Millisecond)
	defer timeout.Stop()
	for {
		qmu.Lock()
		if len(queue) > 0 {
			b := append(append([]byte{'['}, bytes.Join(queue, []byte{','})...), ']')
			queue = nil
			qmu.Unlock()
			return C.CString(string(b))
		}
		qmu.Unlock()
		select {
		case <-queued:
		case <-timeout.C:
			return nil
		}
	}
}

// One page of a mailbox folder (`INBOX`, `PENDING`, `GENERAL`) after `cursor`: its chats are queued; the result is
// `{next, seq}`.
//
//export IGInboxPage
func IGInboxPage(acct, folder, cursor *C.char) *C.char {
	f := C.GoString(folder)
	return call(acct, func(a *account) (any, error) {
		fbid, _ := strconv.ParseInt(a.id, 10, 64)
		resp, err := a.cli.PaginateMailbox(a.ctx, slidetypes.MakePaginateMailboxRequest(fbid, C.GoString(cursor), f, nil))
		if err == nil && resp.Mailbox != nil {
			resp.Mailbox.Token = ""
		}
		if _, err := wire(a.id, "inbox-"+f, resp, err); err != nil {
			return nil, err
		}
		threads, next, err := chat.Mailbox(must(json.Marshal(resp.Mailbox)))
		if err != nil {
			return nil, err
		}
		n := a.do(func(c *chat.Chats) []chat.Envelope {
			var out []chat.Envelope
			for _, t := range threads {
				out = append(out, c.Thread(t))
			}
			return out
		})
		return map[string]any{"next": nextPage(next), "seq": n}, nil
	})
}

// The chat read in full: reactions, edits, reply targets (the mailbox's copy of a message has none, P1). A read; it
// sends nothing. `{room, seq}`.
//
//export IGReadChat
func IGReadChat(room *C.char) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		room, n, err := a.readThread(r.thread)
		return map[string]any{"room": room, "seq": n}, err
	})
}

// The page of older messages before the room's window, as `/messages` gives it (a MessagesPage, newest first, no
// `end` at the start of the chat), also prepended to the engine's copy. A read.
//
//export IGOlder
func IGOlder(room *C.char) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		a.chats.Lock()
		_, cursor, _ := a.chats.Older(r.room)
		a.chats.Unlock()
		var t *chat.Thread
		if cursor != "" && cursor != chat.StartToken {
			resp, err := a.cli.PaginateMessages(a.ctx, &slidetypes.PaginateMessagesRequest{
				ThreadID: r.thread, FirstN: 20, InitialMessagePageCount: 20, AfterCursor: &cursor,
			})
			b, err := wire(a.id, "older", resp, err)
			if err != nil {
				return nil, err
			}
			if t, err = chat.OlderThread(b); err != nil {
				return nil, err
			}
		}
		a.chats.Lock()
		defer a.chats.Unlock()
		return a.chats.Prepend(r.room, cursor, t), nil
	})
}

func optional(s *C.char) *string {
	if v := C.GoString(s); v != "" {
		return &v
	}
	return nil
}

// `otid` is the offline threading ID of the app's local echo (IGNewOTID); the socket's echo carries it back. The
// result is `{id}`, Instagram's ID for the message.
//
//export IGSend
func IGSend(room, text, replyTo, otid *C.char) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		resp, err := a.cli.SendMessage(a.ctx, &slidetypes.SendTextRequest{
			IGThreadIGID:       &r.thread,
			OfflineThreadingID: C.GoString(otid),
			Text:               slidetypes.SensitiveString{Value: C.GoString(text)},
			ReplyToMessageID:   optional(replyTo),
			SendAttribution:    new("igd_web_chat_tab:in_thread"),
		})
		b, err := wire(a.id, "send", resp, err)
		return map[string]string{"id": chat.SentID(b)}, err
	})
}

// The first message to someone with no thread yet: Instagram makes the thread (`recipient` is their FBID). The
// thread arrives through the socket like any new one.
//
//export IGSendNew
func IGSendNew(acct, recipient, text, otid *C.char) *C.char {
	return call(acct, func(a *account) (any, error) {
		resp, err := a.cli.SendMessage(a.ctx, &slidetypes.SendTextRequest{
			RecipientIGIDs:     []string{C.GoString(recipient)},
			OfflineThreadingID: C.GoString(otid),
			Text:               slidetypes.SensitiveString{Value: C.GoString(text)},
			SendAttribution:    new("igd_web_chat_tab:in_thread"),
		})
		_, err = wire(a.id, "send-new", resp, err)
		return map[string]bool{"ok": true}, err
	})
}

// A new offline threading ID, for a local echo.
//
//export IGNewOTID
func IGNewOTID() *C.char {
	return C.CString(chat.OfflineThreadingID(time.Now().UnixMilli(), otids.Add(1)))
}

//export IGAccept
func IGAccept(room, otid *C.char) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		resp, err := a.cli.AcceptMessageRequest(a.ctx, &slidetypes.AcceptMessageRequestRequest{
			ThreadID: r.thread, OfflineThreadingID: C.GoString(otid),
		})
		_, err = wire(a.id, "accept", resp, err)
		return map[string]bool{"ok": true}, err
	})
}

// Deletes the thread for this account (a request's Delete); its room goes. Future requests from them aren't moved
// to spam.
//
//export IGDeleteThread
func IGDeleteThread(room *C.char) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		resp, err := a.cli.DeleteThread(a.ctx, &slidetypes.DeleteThreadRequest{ThreadID: r.thread})
		if _, err = wire(a.id, "delete-thread", resp, err); err != nil {
			return nil, err
		}
		return map[string]int64{"seq": a.do(func(c *chat.Chats) []chat.Envelope { return c.Remove(r.room) })}, nil
	})
}

// People to start a chat with, as New Message's contacts.
//
//export IGSearch
func IGSearch(acct, query *C.char) *C.char {
	return call(acct, func(a *account) (any, error) {
		resp, err := a.cli.SearchUsers(a.ctx, C.GoString(query))
		b, err := wire(a.id, "search", resp, err)
		if err != nil {
			return nil, err
		}
		return chat.Contacts(b)
	})
}

// Our DM with `user` (their FBID), if Instagram has one, read into its room: `{found, room, seq}`.
//
//export IGFindDM
func IGFindDM(acct, user *C.char) *C.char {
	return call(acct, func(a *account) (any, error) {
		fbid, err := strconv.ParseInt(C.GoString(user), 10, 64)
		if err != nil {
			return nil, err
		}
		found, err := a.cli.FetchThreadID(a.ctx, fbid)
		if errors.Is(err, instameow.ErrThreadNotFound) {
			return map[string]any{"found": false}, nil
		} else if err != nil {
			return nil, err
		}
		capture(a.id, "find-dm", must(json.Marshal(found)))
		room, n, err := a.readThread(found.ShortID)
		return map[string]any{"found": true, "room": room, "seq": n}, err
	})
}

// Sends a photo, video or voice note (`path`, the file the app prepared): uploads it to Instagram's media endpoint
// for the thread (its thread_key), then sends it. As the bridge did (msgconv/mediadl/upload.go), without its Matrix
// download first.
// ponytail: no Android upload fallback for videos (upload.go:104); add it if an account's video uploads come back
// without an ID.
//
//export IGSendMedia
func IGSendMedia(room, path, mime *C.char, voice C.int, replyTo, otid *C.char) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		key, err := strconv.ParseInt(r.key, 10, 64)
		if err != nil {
			return nil, err
		}
		data, err := os.ReadFile(C.GoString(path))
		if err != nil {
			return nil, err
		}
		resp, err := a.cli.GetHTTP().SendMercuryUploadRequest(a.ctx, key, &httpclient.MercuryUploadMedia{
			Filename: filepath.Base(C.GoString(path)), MimeType: C.GoString(mime), MediaData: data, IsVoiceClip: voice != 0,
		})
		if err != nil {
			return nil, err
		}
		id := resp.Payload.RealMetadata.GetFbId()
		if id == 0 {
			return nil, errors.New("Instagram didn't accept the upload")
		}
		sent, err := a.cli.SendMedia(a.ctx, &slidetypes.SendMediaRequest{
			AttachmentFBID: strconv.FormatInt(id, 10), ThreadID: r.thread, OfflineThreadingID: C.GoString(otid),
			ReplyToMessageID: optional(replyTo),
		})
		_, err = wire(a.id, "send-media", sent, err)
		return map[string]bool{"ok": true}, err
	})
}

var shortcode = regexp.MustCompile(`/(?:reel|p)/([a-zA-Z0-9_-]+)/?`)

// "Load video" on a shared reel, post or story (`message`): its own media, the best video, else the best image, in
// place of the card as a hidden edit. A read; the bridge's resolve_media (msgconv/igconv/xma.go). `{seq}`.
//
//export IGResolveMedia
func IGResolveMedia(room, message *C.char) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		a.chats.Lock()
		target, id, err := a.chats.Unresolved(r.room, C.GoString(message))
		a.chats.Unlock()
		if err != nil {
			return nil, err
		}
		u, err := url.Parse(target)
		if err != nil {
			return nil, err
		}
		var item *responses.Items
		if strings.HasPrefix(u.Path, "/stories/") {
			mediaID, reelID := path.Base(u.Path), u.Query().Get("reel_id")
			resp, err := a.cli.FetchReel(a.ctx, []string{reelID}, mediaID)
			if err != nil {
				return nil, err
			}
			for _, it := range resp.Reels[reelID].Items {
				if it.Pk == mediaID {
					item = &it.Items
				}
			}
		} else {
			code := ""
			if m := shortcode.FindStringSubmatch(u.Path); len(m) > 1 {
				code = m[1]
			}
			resp, err := a.cli.FetchMedia(a.ctx, id, code)
			if err != nil {
				return nil, err
			}
			if len(resp.Items) > 0 {
				item = resp.Items[0]
				if child := u.Query().Get("carousel_share_child_media_id"); child != "" {
					for _, sub := range item.CarouselMedia {
						if strings.Contains(sub.ID, child) {
							item = sub
						}
					}
				}
			}
		}
		if item == nil {
			return nil, errors.New("Instagram has no media for this share")
		}
		best := chat.Resolved{Width: float64(item.OriginalWidth), Height: float64(item.OriginalHeight), Duration: item.VideoDuration}
		videoWidth := 0
		for _, v := range item.VideoVersions {
			if v.Width > videoWidth {
				best.URL, best.Video, videoWidth = v.URL, true, v.Width
			}
		}
		if best.URL == "" {
			res := 0
			for _, c := range item.ImageVersions2.Candidates {
				if c.Width*c.Height > res {
					best.URL, res = c.URL, c.Width*c.Height
				}
			}
		}
		if best.URL == "" {
			return nil, errors.New("Instagram has no media for this share")
		}
		capture(a.id, "resolve-media", must(json.Marshal(best)))
		n := a.do(func(c *chat.Chats) (out []chat.Envelope) { out, err = c.Resolved(r.room, C.GoString(message), best); return out })
		return map[string]int64{"seq": n}, err
	})
}

//export IGReact
func IGReact(room, message, emoji *C.char, remove C.int) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		status := slidetypes.ReactionStatusCreated
		if remove != 0 {
			status = slidetypes.ReactionStatusDeleted
		}
		resp, err := a.cli.SendReaction(a.ctx, &slidetypes.CreateReactionRequest{Input: slidetypes.ReactionInput{
			Emoji: C.GoString(emoji), MessageID: C.GoString(message), ReactionStatus: status, ThreadID: r.thread,
		}})
		_, err = wire(a.id, "react", resp, err)
		return map[string]bool{"ok": true}, err
	})
}

//export IGEdit
func IGEdit(room, message, text, otid *C.char) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		resp, err := a.cli.EditMessage(a.ctx, &slidetypes.EditMessageRequest{
			ThreadID: r.thread, TargetMessageID: C.GoString(message), OfflineThreadingID: C.GoString(otid),
			Body: slidetypes.SensitiveString{Value: C.GoString(text)},
		})
		_, err = wire(a.id, "edit", resp, err)
		return map[string]bool{"ok": true}, err
	})
}

// Unsend, for everyone. Instagram names the thread by its long ID here (P0).
//
//export IGUnsend
func IGUnsend(room, message *C.char) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		resp, err := a.cli.UnsendMessage(a.ctx, &slidetypes.UnsendMessageRequest{
			MessageID: C.GoString(message), SendData: slidetypes.SendData{ThreadID: r.long},
		})
		_, err = wire(a.id, "unsend", resp, err)
		return map[string]bool{"ok": true}, err
	})
}

// "Seen" up to `message`: the chat reads at once (an update, before Instagram is asked), then the same two requests
// the bridge makes (handlematrix.go:323). If they fail, the chat is unread again, so the next open tries again.
// Nothing is sent when the engine already had it read that far. `{seq}`.
//
//export IGMarkRead
func IGMarkRead(room, message *C.char) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		var long string
		var ms int64
		var err error
		n := a.do(func(c *chat.Chats) (out []chat.Envelope) { out, long, ms, err = c.MarkRead(r.room, C.GoString(message)); return out })
		if err != nil || long == "" {
			return map[string]int64{"seq": n}, err
		}
		meta := slidetypes.MarkReadMetadata{IGThreadIGID: long}
		id := C.GoString(message)
		_, err = a.cli.MarkRead(a.ctx, &slidetypes.MarkReadRequest{Metadata: meta, Data: slidetypes.MarkReadData{MessageID: id, ItemID: new("")}})
		if err == nil {
			var resp any
			resp, err = a.cli.MarkReadValidation(a.ctx, &slidetypes.MarkReadRequest{
				Metadata: meta, Data: slidetypes.MarkReadData{MessageID: id, MessageTimestampMS: jsontime.UnixMilliString{Time: time.UnixMilli(ms)}},
			})
			_, err = wire(a.id, "mark-read", resp, err)
		}
		if err != nil {
			a.do(func(c *chat.Chats) []chat.Envelope { return c.Unread(r.room) })
			return nil, err
		}
		return map[string]int64{"seq": n}, nil
	})
}

//export IGTyping
func IGTyping(room *C.char, on C.int) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		a.count.add("typing (socket)") // goes over the socket, so the HTTP counter doesn't see it
		return map[string]bool{"ok": true}, a.cli.SetTyping(a.ctx, r.thread, on != 0)
	})
}

// Requests made per account since login, by operation (C6).
//
//export IGCounts
func IGCounts() *C.char {
	mu.Lock()
	all := make(map[string]map[string]int, len(accounts))
	for id, a := range accounts {
		all[id] = a.count.snapshot()
	}
	mu.Unlock()
	b, _ := json.Marshal(all)
	return C.CString(string(b))
}

// The session's cookies as they are now (Instagram rotates some while it runs), only for Swift to write straight to
// the Keychain (decision C3). Never captured, never logged.
//
//export IGSession
func IGSession(acct *C.char) *C.char {
	a, err := get(C.GoString(acct))
	if err != nil {
		return fail(err)
	}
	b, _ := json.Marshal(a.cli.GetCookies().GetAll())
	return C.CString(string(b))
}

// Disconnects the account and forgets its client and chats (Remove Account). Instagram isn't told.
//
//export IGStop
func IGStop(acct *C.char) {
	mu.Lock()
	a := accounts[C.GoString(acct)]
	delete(accounts, C.GoString(acct))
	mu.Unlock()
	if a != nil {
		a.cancel()
		a.cli.Disconnect()
	}
}

//export IGStats
func IGStats() *C.char {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	b, _ := json.Marshal(map[string]any{"heapMB": float64(m.HeapAlloc) / 1e6, "goSysMB": float64(m.Sys) / 1e6, "goroutines": runtime.NumGoroutine()})
	return C.CString(string(b))
}

//export IGFree
func IGFree(p *C.char) { C.free(unsafe.Pointer(p)) }

func main() {}
