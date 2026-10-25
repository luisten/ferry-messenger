// The C API the app calls: instameow (mautrix's Instagram client), one client per Instagram account, JSON in and out
// (docs/PLAN-core.md §3). Instagram's data becomes chats here (core/chat, docs/PLAN-android.md stage 1): every change
// to a chat reaches the app through IGNextEvent, in the order the engine made it, as `{"kind": "Room", "room",
// "update", "profiles", "related"}` or `{"kind": "RoomRemoved", "room"}`; a call that changes chats returns the
// `seq` of its last update, so the app can wait until it has applied it. The state dump (web tokens), cookies and
// the viewer's contact details never cross.
//
// Instagram's rules live here too (stage 2, core/chat/rules.go): after a login the engine loads the other folders by
// itself, and opening a chat, "Seen", typing, replies in requests, reactions, edits, unsends and New Message's drafts
// go through the rules, which decide whether Instagram is asked at all.
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
	webpush "github.com/luisten/ferry-messenger/core/push"
)

type account struct {
	id     string
	cli    *instameow.Client
	ctx    context.Context
	cancel context.CancelFunc
	stop   context.CancelFunc // ends the socket connect started (IGPause); under mu
	count  *counter
	chats  *book
	// When IGLogin last made a new web session for it (ms; 0 if only resumed this launch): a new session registers
	// its web push channel again (rules.go's PushRegister).
	loginAt int64
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

	// A passing login failure tries again every 30 s, by account (IGResume).
	retries = map[string]*time.Timer{}

	// DEBUG builds only (IGSetDebug): every send blocked, and a real chat shown as a request.
	debugMu          sync.Mutex
	debugBlockSends  bool
	debugRequestRoom string

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
	n = a.do(func(c *chat.Chats) []chat.Envelope { out := c.Load(*t); room = out[0].Room; return out })
	return room, n, nil
}

// loadFolders is the rest of the inbox (after the first page's `next`), then the first pages of Requests and
// (professional accounts) General, one request a page (chat.Folders, chat.MaxPages), while the account runs.
func (a *account) loadFolders(next string, professional bool) {
	fbid, _ := strconv.ParseInt(a.id, 10, 64)
	for _, folder := range chat.Folders(professional) {
		cursor := ""
		if folder == "INBOX" {
			if cursor = next; cursor == "" {
				continue
			}
		}
		for range chat.MaxPages {
			// ponytail: polls while the app is in the background (IGPause), so a wake never pages; a cond if it matters.
			for paused.Load() && a.ctx.Err() == nil {
				time.Sleep(time.Second)
			}
			if a.ctx.Err() != nil {
				return
			}
			resp, err := a.cli.PaginateMailbox(a.ctx, slidetypes.MakePaginateMailboxRequest(fbid, cursor, folder, nil))
			if err == nil && resp.Mailbox != nil {
				resp.Mailbox.Token = ""
			}
			if _, err := wire(a.id, "inbox-"+folder, resp, err); err != nil {
				break
			}
			threads, more, err := chat.Mailbox(must(json.Marshal(resp.Mailbox)))
			if err != nil {
				break
			}
			a.do(func(c *chat.Chats) (out []chat.Envelope) {
				for _, t := range threads {
					out = append(out, c.Load(t)...)
				}
				return out
			})
			if cursor = more; cursor == "" {
				break
			}
		}
	}
}

// typing tells Instagram we're typing or stopped (over the socket, so the HTTP counter doesn't see it).
func (a *account) typing(thread string, on bool) {
	a.count.add("typing (socket)")
	_ = a.cli.SetTyping(a.ctx, thread, on)
}

// accept accepts a request, then reads the chat again: its new folder lets "Seen" and typing through.
func (a *account) accept(r ids) error {
	resp, err := a.cli.AcceptMessageRequest(a.ctx, &slidetypes.AcceptMessageRequestRequest{ThreadID: r.thread, OfflineThreadingID: newOTID()})
	if _, err = wire(a.id, "accept", resp, err); err != nil {
		return err
	}
	_, _, _ = a.readThread(r.thread)
	return nil
}

func newOTID() string { return chat.OfflineThreadingID(time.Now().UnixMilli(), otids.Add(1)) }

func now() int64 { return time.Now().UnixMilli() }

// currentSeq is the last queued event's: a call that changed nothing waits for nothing.
func currentSeq() int64 {
	qmu.Lock()
	defer qmu.Unlock()
	return seq
}

// blocked refuses what DEBUG builds hold back: every send under FERRY_DEBUG_BLOCK_SENDS, and sends to the chat shown
// as a request.
func blocked(room string) error {
	debugMu.Lock()
	defer debugMu.Unlock()
	if debugBlockSends || room != "" && room == debugRequestRoom {
		return errors.New("DEBUG: blocked (FERRY_DEBUG_BLOCK_SENDS or FERRY_DEBUG_AS_REQUEST).")
	}
	return nil
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

// accountOf is the account a room ID names (`!ig-<account>-…`).
func accountOf(room string) string {
	acct, _, _ := strings.Cut(strings.TrimPrefix(room, "!ig-"), "-")
	return acct
}

// One library call for a chat this engine made (E4): DEBUG fixture rooms and New Message drafts never get here.
func roomCall(room *C.char, f func(a *account, r ids) (any, error)) *C.char {
	r := ids{room: C.GoString(room)}
	a, err := get(accountOf(r.room))
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
	case *slidetypes.ResnapshotRequired:
		// Instagram can't replay what the socket missed (a long time away) and the library stops reconnecting: load
		// the inbox again, as a launch does (upstream's bridge does a full reconnect). ponytail: no guard against a
		// loop, as upstream; the new mailbox's seqID is fresh. Add one if C6 ever shows repeated logins.
		cookies, _ := json.Marshal(a.cli.GetCookies().GetAll())
		go relogin(a.id, string(cookies))
	}
	return nil
}

//export IGSetCapture
func IGSetCapture(dir *C.char) { captureDir.Store(C.GoString(dir)) }

// login logs in (or re-logs in) with cookies from the web view or the Keychain: loads the index and mailbox, queues the
// first page's chats, connects the socket, then loads the other folders by itself. `{account, viewer, seq}`.
func login(cookiesJSON string) (map[string]any, error) {
	var raw map[cookies.MetaCookieName]string
	if err := json.Unmarshal([]byte(cookiesJSON), &raw); err != nil {
		return nil, err
	}
	c := &cookies.Cookies{Platform: types.Instagram}
	c.UpdateValues(raw)
	if missing := c.GetMissingCookieNames(); len(missing) > 0 {
		return nil, fmt.Errorf("missing cookies: %v", missing)
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
		return nil, err
	}
	fbid := cli.GetOwnFBID()
	if fbid == 0 {
		cancel()
		return nil, errors.New("logged in, but Instagram didn't say which account")
	}
	id := strconv.FormatInt(fbid, 10)
	a.cli, a.ctx, a.cancel = cli, ctx, cancel

	mu.Lock()
	old := accounts[id]
	if old != nil {
		a.chats, a.loginAt = old.chats, old.loginAt
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
		return nil, err
	}
	debugMu.Lock()
	forced := debugRequestRoom
	debugMu.Unlock()
	n := a.do(func(c *chat.Chats) (out []chat.Envelope) {
		c.Name, c.Avatar, c.ForcedRequest = v.FullName, v.ProfilePicURL, forced
		for _, t := range threads {
			out = append(out, c.Load(t)...)
		}
		return out
	})
	mu.Lock()
	if !paused.Load() { // else IGUnpause connects it
		a.connect() // after the chats are in: its live changes apply to them
	}
	mu.Unlock()
	go a.loadFolders(next, v.IsProfessionalAccount)
	return map[string]any{"account": id, "viewer": shown, "seq": n}, nil
}

// Logs in with the cookies from the web view (a new account, or a fix for one Instagram signed out): `{account,
// viewer, seq}`. The user is there, so nothing retries.
//
//export IGLogin
func IGLogin(cookiesJSON *C.char) *C.char {
	out, err := login(C.GoString(cookiesJSON))
	if err != nil {
		return fail(err)
	}
	mu.Lock()
	if a := accounts[out["account"].(string)]; a != nil {
		a.loginAt = now()
	}
	mu.Unlock()
	return jsonOut(out)
}

// Connects a stored account (a launch, "Try again"): as IGLogin, and after a passing failure (the network) it tries
// again every 30 s by itself, telling the app each time (`Login` with IGLogin's answer, or `LoginFailed`), until it
// connects, the app calls this again, or the account stops.
//
//export IGResume
func IGResume(acct, cookiesJSON *C.char) *C.char {
	id, cookies := C.GoString(acct), C.GoString(cookiesJSON)
	stopRetry(id)
	out, err := login(cookies)
	if err != nil {
		retryLater(id, cookies, err)
		return fail(err)
	}
	return jsonOut(out)
}

// ponytail: a fixed 30 s while the app runs; backoff if it ever hammers.
func retryLater(id, cookies string, err error) {
	if state, _ := classify(err); state != "TRANSIENT_DISCONNECT" || paused.Load() { // paused: the app retries on return
		return
	}
	mu.Lock()
	defer mu.Unlock()
	var t *time.Timer
	t = time.AfterFunc(30*time.Second, func() {
		mu.Lock()
		current := retries[id] == t
		if current {
			delete(retries, id)
		}
		mu.Unlock()
		if current {
			relogin(id, cookies)
		}
	})
	retries[id] = t
}

// Logs in again by itself, telling the app (`Login` with IGLogin's answer, or `LoginFailed`) and retrying after a
// passing failure.
func relogin(id, cookies string) {
	out, err := login(cookies)
	if err != nil {
		state, reason := classify(err)
		push(map[string]any{"account": id, "kind": "LoginFailed", "error": err.Error(), "code": state, "reason": reason})
		retryLater(id, cookies, err)
		return
	}
	out["kind"] = "Login"
	push(out)
}

func stopRetry(id string) {
	mu.Lock()
	defer mu.Unlock()
	if t := retries[id]; t != nil {
		t.Stop()
		delete(retries, id)
	}
}

// DEBUG builds only: `blockSends` holds back every send and upload (FERRY_DEBUG_BLOCK_SENDS); `requestRoom` is a real
// chat every rule treats as a request, whose sends are held back too (FERRY_DEBUG_AS_REQUEST).
//
//export IGSetDebug
func IGSetDebug(blockSends C.int, requestRoom *C.char) {
	debugMu.Lock()
	debugBlockSends, debugRequestRoom = blockSends != 0, C.GoString(requestRoom)
	debugMu.Unlock()
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

// A chat opened: read in full (the mailbox's copy of a message has no reactions or edit history, P1), at most every
// 30 s (rules.go). A read; it sends nothing. `{seq}`.
//
//export IGOpenChat
func IGOpenChat(room *C.char) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		a.chats.Lock()
		read, err := a.chats.Open(r.room, now())
		a.chats.Unlock()
		if err != nil || !read {
			return map[string]int64{"seq": currentSeq()}, err
		}
		_, n, err := a.readThread(r.thread)
		return map[string]int64{"seq": n}, err
	})
}

// The chat read in full now, whenever it was last: Instagram's media links expire (33 h to 30 days, P0), so a failed
// download reads it again for fresh ones. A read. `{room, seq}`.
//
//export IGReadChat
func IGReadChat(room *C.char) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		a.chats.Lock()
		a.chats.Reading(r.room, now())
		a.chats.Unlock()
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

// A text (a reply when `replyTo`). `otid` is the offline threading ID of the app's local echo (IGNewOTID); the
// socket's echo carries it back. In a request it accepts first, as the bridge did; "typing" stops if we'd said it. To
// a New Message draft it's the first message, which makes the thread (its arrival moves the draft, `RoomMoved`).
// `{id}`: Instagram's ID for the message ("" for a draft's).
//
//export IGSend
func IGSend(room, text, replyTo, otid *C.char) *C.char {
	req := &slidetypes.SendTextRequest{
		OfflineThreadingID: C.GoString(otid), Text: slidetypes.SensitiveString{Value: C.GoString(text)},
		ReplyToMessageID: optional(replyTo), SendAttribution: new("igd_web_chat_tab:in_thread"),
	}
	if a, err := get(accountOf(C.GoString(room))); err == nil {
		a.chats.Lock()
		user, draft := a.chats.DraftRecipient(C.GoString(room))
		a.chats.Unlock()
		if draft {
			if err := blocked(""); err != nil {
				return fail(err)
			}
			req.RecipientIGIDs, req.ReplyToMessageID = []string{user}, nil
			resp, err := a.cli.SendMessage(a.ctx, req)
			if _, err = wire(a.id, "send-new", resp, err); err != nil {
				return fail(err)
			}
			return jsonOut(map[string]string{"id": ""})
		}
	}
	return roomCall(room, func(a *account, r ids) (any, error) {
		if err := blocked(r.room); err != nil {
			return nil, err
		}
		a.chats.Lock()
		accept, typingOff, err := a.chats.BeforeSend(r.room)
		a.chats.Unlock()
		if err != nil {
			return nil, err
		}
		if typingOff {
			a.typing(r.thread, false)
		}
		if accept {
			if err := a.accept(r); err != nil {
				return nil, err
			}
		}
		req.IGThreadIGID = &r.thread
		resp, err := a.cli.SendMessage(a.ctx, req)
		b, err := wire(a.id, "send", resp, err)
		return map[string]string{"id": chat.SentID(b)}, err
	})
}

// A new offline threading ID, for a local echo.
//
//export IGNewOTID
func IGNewOTID() *C.char {
	return C.CString(newOTID())
}

// Accepts a request, then reads the chat again (its new folder arrives as an update). `{seq}`.
//
//export IGAccept
func IGAccept(room *C.char) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		if err := blocked(r.room); err != nil {
			return nil, err
		}
		return map[string]int64{"seq": currentSeq()}, a.accept(r)
	})
}

// Deletes the thread for this account (a request's Delete); its room goes. Future requests from them aren't moved
// to spam.
//
//export IGDeleteThread
func IGDeleteThread(room *C.char) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		if err := blocked(r.room); err != nil {
			return nil, err
		}
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

// New Message's chat with `contact` (a search result, `{id, name, avatar_url, identifiers}`): our DM with them, else
// the one Instagram has (read in full), else a draft until the first message makes the thread. `{room, seq}`.
//
//export IGOpenDM
func IGOpenDM(acct, contactJSON *C.char) *C.char {
	return call(acct, func(a *account) (any, error) {
		var contact chat.Contact
		if err := json.Unmarshal([]byte(C.GoString(contactJSON)), &contact); err != nil {
			return nil, err
		}
		fbid, err := strconv.ParseInt(contact.ID, 10, 64)
		if err != nil {
			return nil, err
		}
		a.chats.Lock()
		room := a.chats.ExistingDM(contact.ID)
		a.chats.Unlock()
		if room != "" {
			return map[string]any{"room": room, "seq": currentSeq()}, nil
		}
		found, err := a.cli.FetchThreadID(a.ctx, fbid)
		if err == nil {
			capture(a.id, "find-dm", must(json.Marshal(found)))
			room, n, err := a.readThread(found.ShortID)
			return map[string]any{"room": room, "seq": n}, err
		} else if !errors.Is(err, instameow.ErrThreadNotFound) {
			return nil, err
		}
		n := a.do(func(c *chat.Chats) (out []chat.Envelope) { room, out = c.Draft(contact); return out })
		return map[string]any{"room": room, "seq": n}, nil
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
		if err := blocked(r.room); err != nil {
			return nil, err
		}
		a.chats.Lock()
		request, typingOff, err := a.chats.BeforeSend(r.room)
		a.chats.Unlock()
		if err == nil && request { // never in a request
			err = chat.ErrRequest
		}
		if err != nil {
			return nil, err
		}
		if typingOff {
			a.typing(r.thread, false)
		}
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
		if err := blocked(r.room); err != nil {
			return nil, err
		}
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

// Our reaction to `message`, or (`remove`) its removal: never in a request. Instagram keeps one per person, so another
// emoji replaces it.
//
//export IGReact
func IGReact(room, message, emoji *C.char, remove C.int) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		if err := allowed(a, r.room, func(c *chat.Chats) error { return c.CanReact(r.room) }); err != nil {
			return nil, err
		}
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

// Our own text, edited: within 15 minutes and 5 edits, never in a request.
//
//export IGEdit
func IGEdit(room, message, text *C.char) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		if err := allowed(a, r.room, func(c *chat.Chats) error { return c.CanEdit(r.room, C.GoString(message), now()) }); err != nil {
			return nil, err
		}
		resp, err := a.cli.EditMessage(a.ctx, &slidetypes.EditMessageRequest{
			ThreadID: r.thread, TargetMessageID: C.GoString(message), OfflineThreadingID: newOTID(),
			Body: slidetypes.SensitiveString{Value: C.GoString(text)},
		})
		_, err = wire(a.id, "edit", resp, err)
		return map[string]bool{"ok": true}, err
	})
}

// Unsend, for everyone (our own messages, never in a request). Instagram names the thread by its long ID here (P0).
//
//export IGUnsend
func IGUnsend(room, message *C.char) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		if err := allowed(a, r.room, func(c *chat.Chats) error { return c.CanUnsend(r.room, C.GoString(message)) }); err != nil {
			return nil, err
		}
		resp, err := a.cli.UnsendMessage(a.ctx, &slidetypes.UnsendMessageRequest{
			MessageID: C.GoString(message), SendData: slidetypes.SendData{ThreadID: r.long},
		})
		_, err = wire(a.id, "unsend", resp, err)
		return map[string]bool{"ok": true}, err
	})
}

// "Seen" on their newest message, when the chat is unread and isn't a request (rules.go; the app calls this on open and
// on each new message while the chat shows): the chat reads at once (an update, before Instagram is asked), then the
// same two requests the bridge makes (handlematrix.go:323). If they fail, the chat is unread again, so the next open
// tries again. `{seq}`.
//
//export IGMarkRead
func IGMarkRead(room *C.char) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		var long, id string
		var ms int64
		var err error
		n := a.do(func(c *chat.Chats) (out []chat.Envelope) { out, long, id, ms, err = c.MarkRead(r.room); return out })
		if err != nil || long == "" {
			return map[string]int64{"seq": n}, err
		}
		meta := slidetypes.MarkReadMetadata{IGThreadIGID: long}
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

// The composer's typing state (the app calls this as the text changes, and when the chat closes): Instagram hears
// "typing" at most once per 20 s and "stopped" only after it, never in a request. `{sent}`.
//
//export IGTyping
func IGTyping(room *C.char, on C.int) *C.char {
	return roomCall(room, func(a *account, r ids) (any, error) {
		if blocked("") != nil { // the chat shown as a request is held back by the request rule, as a real one is
			return map[string]bool{"sent": false}, nil
		}
		a.chats.Lock()
		send, err := a.chats.SetTyping(r.room, on != 0, now())
		a.chats.Unlock()
		if send {
			a.typing(r.thread, on != 0)
		}
		return map[string]bool{"sent": send}, err
	})
}

// allowed is DEBUG's block, then a rule's verdict on the engine's copy.
func allowed(a *account, room string, rule func(c *chat.Chats) error) error {
	if err := blocked(room); err != nil {
		return err
	}
	a.chats.Lock()
	defer a.chats.Unlock()
	return rule(a.chats.Chats)
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

// paused is IGPause's: the app is in the background, so no socket, retry or folder page may reach Instagram.
var paused atomic.Bool

// The app went to the background: every account's socket closes, retries stop and folder paging waits, so a Background
// App Refresh wake, which resumes this process, never reaches Instagram (docs/PLAN-push.md). Before wakes existed only
// the user resumed the app. Chats stay; IGUnpause reconnects without reloading the index, as the library's own
// reconnect did on return.
//
//export IGPause
func IGPause() {
	if paused.Swap(true) {
		return
	}
	mu.Lock()
	defer mu.Unlock()
	for _, a := range accounts {
		if a.stop != nil {
			a.stop()
		}
	}
	for id, t := range retries {
		t.Stop()
		delete(retries, id)
	}
}

// The app is active again: every account's socket reconnects, and Instagram's client catches up on what it missed.
//
//export IGUnpause
func IGUnpause() {
	if !paused.Swap(false) {
		return
	}
	mu.Lock()
	defer mu.Unlock()
	for _, a := range accounts {
		a.connect()
	}
}

// Starts the account's sockets on a context of their own, which IGPause cancels. Not the library's Disconnect: that
// stops a client's sockets for good (dgw's `stopping`), and 1.6.0 never reconnected after its first return
// (TestASocketReconnectsAfterItsContextEnds). Holds mu.
func (a *account) connect() {
	ctx, stop := context.WithCancel(a.ctx)
	a.stop = stop
	go a.cli.Connect(ctx)
}

// The phone's web push channels (docs/PLAN-push.md): `state` is the last answer of IGPushSetup, IGPushDrain or
// IGRegisterPush ("" the first time), `accounts` a JSON array of account IDs. A channel and keys for each account
// without one, the channels of accounts not listed dropped. Mozilla only. Answers the new state, which holds private
// keys: only for Swift to write straight to the Keychain, never logged (as IGSession's cookies, decision C3).
//
//export IGPushSetup
func IGPushSetup(stateJSON, accountsJSON *C.char) *C.char {
	s, err := pushState(stateJSON)
	var accounts []string
	if err == nil {
		err = json.Unmarshal([]byte(C.GoString(accountsJSON)), &accounts)
	}
	if err != nil {
		return fail(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if s, err = webpush.Setup(ctx, s, accounts); err != nil {
		return fail(err)
	}
	return jsonOut(s)
}

// What Mozilla held for the phone, read and acked: `{state, pushes}`, each push marked whether to notify (a message
// newer than `since`, Unix ms: the last time the app was open). Mozilla only; Instagram isn't asked anything, so the
// app can call it from a background wake.
//
//export IGPushDrain
func IGPushDrain(stateJSON *C.char, since C.longlong) *C.char {
	s, err := pushState(stateJSON)
	if err != nil {
		return fail(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	s, pushes, err := webpush.Drain(ctx, s, int64(since), 1500*time.Millisecond, 10*time.Second)
	if err != nil {
		return fail(err)
	}
	return jsonOut(map[string]any{"state": s, "pushes": pushes})
}

// Registers the account's web push channel with Instagram (`device_type: web_vapid`, what instagram.com sends when a
// browser allows notifications) when rules.go's PushRegister says to: one request, else none. Only the public keys
// go. `{state, sent}`.
//
//export IGRegisterPush
func IGRegisterPush(acct, stateJSON *C.char) *C.char {
	return call(acct, func(a *account) (any, error) {
		s, err := pushState(stateJSON)
		if err != nil {
			return nil, err
		}
		ch := s.Accounts[a.id]
		if ch == nil {
			return nil, errors.New("This account has no push channel yet.")
		}
		mu.Lock()
		loginAt := a.loginAt
		mu.Unlock()
		if !chat.PushRegister(ch.Endpoint, ch.RegisteredEndpoint, ch.RegisteredAt, loginAt, now()) {
			return map[string]any{"state": s, "sent": false}, nil
		}
		keys := instameow.PushKeys{P256DH: ch.Keys.P256DH, Auth: ch.Keys.Auth}
		ctx, cancel := context.WithTimeout(a.ctx, 15*time.Second) // a hung request would hold up a wake's drain
		defer cancel()
		if err := a.cli.RegisterPushNotifications(ctx, ch.Endpoint, keys); err != nil {
			return nil, err
		}
		ch.RegisteredEndpoint, ch.RegisteredAt = ch.Endpoint, now()
		return map[string]any{"state": s, "sent": true}, nil
	})
}

// The room a push names, once its account's chats have loaded: `{room}`, "" for the inbox.
//
//export IGPushRoom
func IGPushRoom(acct, pushJSON *C.char) *C.char {
	return call(acct, func(a *account) (any, error) {
		var p webpush.Push
		if err := json.Unmarshal([]byte(C.GoString(pushJSON)), &p); err != nil {
			return nil, err
		}
		a.chats.Lock()
		defer a.chats.Unlock()
		return map[string]string{"room": a.chats.PushRoom(p.Thread, p.User, p.Group != "")}, nil
	})
}

func pushState(stateJSON *C.char) (s webpush.State, err error) {
	if text := C.GoString(stateJSON); text != "" {
		err = json.Unmarshal([]byte(text), &s)
	}
	return s, err
}

// Disconnects the account and forgets its client and chats (Remove Account). Instagram isn't told.
//
//export IGStop
func IGStop(acct *C.char) {
	stopRetry(C.GoString(acct))
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
