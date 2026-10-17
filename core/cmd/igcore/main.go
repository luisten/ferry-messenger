// The C API the app calls: instameow (mautrix's Instagram client), one client per Instagram account, JSON in and out
// (docs/PLAN-core.md §3). Threads, messages and deltas cross as the library's own JSON (decision C1); the state dump
// (web tokens), cookies and the viewer's contact details never do.
//
// IDs: `account` is the account's FBID (the bridge's login ID). A thread has three: `thread` is ThreadInfo.id (send,
// react, edit, typing, history), `threadLong` is ThreadInfo.thread_id (unsend, mark read), and thread_key (uploads).
// `message` is Message.id.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
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
)

type account struct {
	id     string
	cli    *instameow.Client
	ctx    context.Context
	cancel context.CancelFunc
	count  *counter
}

var (
	mu       sync.Mutex
	accounts = map[string]*account{}
	events   = make(chan []byte, 1024)

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

// Writes what crosses to Swift into <dir>/<account>/, numbered in order. DEBUG builds only, for test fixtures.
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

func jsonOut(acct, name string, v any) *C.char {
	b, err := json.Marshal(v)
	if err != nil {
		return fail(err)
	}
	capture(acct, name, b)
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

func get(acct *C.char) (*account, error) {
	mu.Lock()
	defer mu.Unlock()
	if a := accounts[C.GoString(acct)]; a != nil {
		return a, nil
	}
	return nil, errors.New("account not started")
}

// One library call for an account, its result passed through as JSON.
func call(acct *C.char, name string, f func(a *account) (any, error)) *C.char {
	a, err := get(acct)
	if err != nil {
		return fail(err)
	}
	v, err := f(a)
	if err != nil {
		return fail(err)
	}
	return jsonOut(a.id, name, v)
}

func handler(acct string, count *counter) func(context.Context, slidetypes.ClientEvent) error {
	return func(_ context.Context, evt slidetypes.ClientEvent) error {
		if acct == "" {
			return nil // before IGLogin knows the account: only LoadIndex's ReconnectionStateUpdate (seen in P0)
		}
		e := map[string]any{"account": acct, "kind": fmt.Sprintf("%T", evt)[len("*slidetypes."):], "at": time.Now().UnixMilli()}
		switch evt := evt.(type) {
		case *slidetypes.Delta:
			e["delta"] = json.RawMessage(evt.Raw) // the wire JSON, unknown types (SlideUQPPIGMoveThread) included
		case *slidetypes.TypingNotification:
			e["thread"] = evt.ThreadID
			e["typing"] = evt
		case *slidetypes.Connected:
			count.add("socket connect")
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
		// SeqIDUpdate, ReconnectionStateUpdate (may hold session data), ResnapshotRequired: the kind only.
		b, _ := json.Marshal(e)
		capture(acct, "event-"+e["kind"].(string), b)
		select {
		case events <- b:
		default: // ponytail: drops when Swift stops polling; the app polls while active
		}
		return nil
	}
}

//export IGSetCapture
func IGSetCapture(dir *C.char) { captureDir.Store(C.GoString(dir)) }

// Logs in (or re-logs in) with the cookies from the web view, loads the index and mailbox, and connects the socket.
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
	count := &counter{n: map[string]int{}}
	var id string
	cli := instameow.NewClient(instameow.ClientParams{
		Cookies: c, Log: log,
		EventHandler: func(ctx context.Context, evt slidetypes.ClientEvent) error { return handler(id, count)(ctx, evt) },
	})
	h := cli.GetHTTP()
	count.next = h.HTTP.Transport
	h.HTTP.Transport = count

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
	id = strconv.FormatInt(fbid, 10)

	mu.Lock()
	old := accounts[id]
	accounts[id] = &account{id: id, cli: cli, ctx: ctx, cancel: cancel, count: count}
	mu.Unlock()
	if old != nil {
		old.cancel()
		old.cli.Disconnect()
	}
	go cli.Connect(ctx)

	if mailbox != nil {
		mailbox.Token = ""
	}
	v := viewer.Data
	return jsonOut(id, "login", map[string]any{
		"account": id,
		// Only what the app shows: the viewer also carries a business account's email and phone number.
		"viewer": map[string]any{
			"id": v.ID, "fbid": v.Fbid, "username": v.Username, "full_name": v.FullName,
			"profile_pic_url": v.ProfilePicURL, "is_professional_account": v.IsProfessionalAccount,
			"is_business_account": v.IsBusinessAccount, "has_tabbed_inbox": v.HasTabbedInbox,
		},
		"mailbox": mailbox,
	})
}

//export IGNextEvent
func IGNextEvent(timeoutMS C.int) *C.char {
	select {
	case b := <-events:
		return C.CString(string(b))
	case <-time.After(time.Duration(timeoutMS) * time.Millisecond):
		return nil
	}
}

//export IGInboxPage
func IGInboxPage(acct, folder, cursor *C.char) *C.char {
	f := C.GoString(folder)
	return call(acct, "inbox-"+f, func(a *account) (any, error) {
		fbid, _ := strconv.ParseInt(a.id, 10, 64)
		resp, err := a.cli.PaginateMailbox(a.ctx, slidetypes.MakePaginateMailboxRequest(fbid, C.GoString(cursor), f, nil))
		if err == nil && resp.Mailbox != nil {
			resp.Mailbox.Token = ""
		}
		return resp, err
	})
}

//export IGThread
func IGThread(acct, thread *C.char) *C.char {
	return call(acct, "thread", func(a *account) (any, error) {
		return a.cli.GetThread(a.ctx, slidetypes.MakeGetThreadInfoRequest(C.GoString(thread)))
	})
}

// Older messages: after `cursor` (the previous page's end cursor), or else older than `message`.
//
//export IGOlder
func IGOlder(acct, thread, cursor, message *C.char) *C.char {
	return call(acct, "older", func(a *account) (any, error) {
		req := &slidetypes.PaginateMessagesRequest{ThreadID: C.GoString(thread), FirstN: 20, InitialMessagePageCount: 20}
		if c := C.GoString(cursor); c != "" {
			req.AfterCursor = &c
		} else {
			m := C.GoString(message)
			req.OlderThanMessageID = &m
		}
		return a.cli.PaginateMessages(a.ctx, req)
	})
}

func optional(s *C.char) *string {
	if v := C.GoString(s); v != "" {
		return &v
	}
	return nil
}

// `otid` is the offline threading ID Swift generated for its local echo; the socket's echo carries it back.
//
//export IGSend
func IGSend(acct, thread, text, replyTo, otid *C.char) *C.char {
	return call(acct, "send", func(a *account) (any, error) {
		return a.cli.SendMessage(a.ctx, &slidetypes.SendTextRequest{
			IGThreadIGID:       optional(thread),
			OfflineThreadingID: C.GoString(otid),
			Text:               slidetypes.SensitiveString{Value: C.GoString(text)},
			ReplyToMessageID:   optional(replyTo),
			SendAttribution:    new("igd_web_chat_tab:in_thread"),
		})
	})
}

// The first message to someone with no thread yet: Instagram makes the thread (`recipient` is their FBID). The
// thread arrives through the socket like any new one.
//
//export IGSendNew
func IGSendNew(acct, recipient, text, otid *C.char) *C.char {
	return call(acct, "send-new", func(a *account) (any, error) {
		return a.cli.SendMessage(a.ctx, &slidetypes.SendTextRequest{
			RecipientIGIDs:     []string{C.GoString(recipient)},
			OfflineThreadingID: C.GoString(otid),
			Text:               slidetypes.SensitiveString{Value: C.GoString(text)},
			SendAttribution:    new("igd_web_chat_tab:in_thread"),
		})
	})
}

//export IGAccept
func IGAccept(acct, thread, otid *C.char) *C.char {
	return call(acct, "accept", func(a *account) (any, error) {
		return a.cli.AcceptMessageRequest(a.ctx, &slidetypes.AcceptMessageRequestRequest{
			ThreadID: C.GoString(thread), OfflineThreadingID: C.GoString(otid),
		})
	})
}

// Deletes the thread for this account (a request's Delete). Future requests from them aren't moved to spam.
//
//export IGDeleteThread
func IGDeleteThread(acct, thread *C.char) *C.char {
	return call(acct, "delete-thread", func(a *account) (any, error) {
		return a.cli.DeleteThread(a.ctx, &slidetypes.DeleteThreadRequest{ThreadID: C.GoString(thread)})
	})
}

//export IGSearch
func IGSearch(acct, query *C.char) *C.char {
	return call(acct, "search", func(a *account) (any, error) { return a.cli.SearchUsers(a.ctx, C.GoString(query)) })
}

// Our DM with `user` (their FBID), if there is one: `{found, thread_igid, thread_fbid}` (thread_fbid is ThreadInfo.id).
//
//export IGFindDM
func IGFindDM(acct, user *C.char) *C.char {
	return call(acct, "find-dm", func(a *account) (any, error) {
		fbid, err := strconv.ParseInt(C.GoString(user), 10, 64)
		if err != nil {
			return nil, err
		}
		ids, err := a.cli.FetchThreadID(a.ctx, fbid)
		if errors.Is(err, instameow.ErrThreadNotFound) {
			return map[string]any{"found": false}, nil
		} else if err != nil {
			return nil, err
		}
		return map[string]any{"found": true, "thread_igid": ids.LongID, "thread_fbid": ids.ShortID}, nil
	})
}

// Sends a photo, video or voice note (`path`, the file Swift prepared): uploads it to Instagram's media endpoint for
// the thread (`threadKey`, ThreadInfo.thread_key), then sends it to `thread` (ThreadInfo.id). As the bridge did
// (msgconv/mediadl/upload.go), without its Matrix download first.
// ponytail: no Android upload fallback for videos (upload.go:104); add it if an account's video uploads come back
// without an ID.
//
//export IGSendMedia
func IGSendMedia(acct, threadKey, thread, path, mime *C.char, voice C.int, replyTo, otid *C.char) *C.char {
	return call(acct, "send-media", func(a *account) (any, error) {
		key, err := strconv.ParseInt(C.GoString(threadKey), 10, 64)
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
		return a.cli.SendMedia(a.ctx, &slidetypes.SendMediaRequest{
			AttachmentFBID: strconv.FormatInt(id, 10), ThreadID: C.GoString(thread), OfflineThreadingID: C.GoString(otid),
			ReplyToMessageID: optional(replyTo),
		})
	})
}

var shortcode = regexp.MustCompile(`/(?:reel|p)/([a-zA-Z0-9_-]+)/?`)

// A shared reel, post or story's own media (`target`, its instagram.com link; `id`, the share's target_id): the best
// video, else the best image. A read; the bridge's resolve_media (msgconv/igconv/xma.go).
//
//export IGResolveMedia
func IGResolveMedia(acct, target, id *C.char) *C.char {
	return call(acct, "resolve-media", func(a *account) (any, error) {
		u, err := url.Parse(C.GoString(target))
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
			resp, err := a.cli.FetchMedia(a.ctx, C.GoString(id), code)
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
		best := map[string]any{"width": item.OriginalWidth, "height": item.OriginalHeight, "duration": item.VideoDuration}
		for _, v := range item.VideoVersions {
			if w, _ := best["video_width"].(int); v.Width > w {
				best["url"], best["video"], best["video_width"] = v.URL, true, v.Width
			}
		}
		if best["url"] == nil {
			res := 0
			for _, c := range item.ImageVersions2.Candidates {
				if c.Width*c.Height > res {
					best["url"], res = c.URL, c.Width*c.Height
				}
			}
		}
		if best["url"] == nil {
			return nil, errors.New("Instagram has no media for this share")
		}
		return best, nil
	})
}

//export IGReact
func IGReact(acct, thread, message, emoji *C.char, remove C.int) *C.char {
	return call(acct, "react", func(a *account) (any, error) {
		status := slidetypes.ReactionStatusCreated
		if remove != 0 {
			status = slidetypes.ReactionStatusDeleted
		}
		return a.cli.SendReaction(a.ctx, &slidetypes.CreateReactionRequest{Input: slidetypes.ReactionInput{
			Emoji: C.GoString(emoji), MessageID: C.GoString(message), ReactionStatus: status, ThreadID: C.GoString(thread),
		}})
	})
}

//export IGEdit
func IGEdit(acct, thread, message, text, otid *C.char) *C.char {
	return call(acct, "edit", func(a *account) (any, error) {
		return a.cli.EditMessage(a.ctx, &slidetypes.EditMessageRequest{
			ThreadID: C.GoString(thread), TargetMessageID: C.GoString(message), OfflineThreadingID: C.GoString(otid),
			Body: slidetypes.SensitiveString{Value: C.GoString(text)},
		})
	})
}

//export IGUnsend
func IGUnsend(acct, threadLong, message *C.char) *C.char {
	return call(acct, "unsend", func(a *account) (any, error) {
		return a.cli.UnsendMessage(a.ctx, &slidetypes.UnsendMessageRequest{
			MessageID: C.GoString(message), SendData: slidetypes.SendData{ThreadID: C.GoString(threadLong)},
		})
	})
}

// Sends "Seen" up to `message` (sent at `tsMS`): the same two requests the bridge makes (handlematrix.go:323).
//
//export IGMarkRead
func IGMarkRead(acct, threadLong, message *C.char, tsMS C.longlong) *C.char {
	return call(acct, "mark-read", func(a *account) (any, error) {
		meta := slidetypes.MarkReadMetadata{IGThreadIGID: C.GoString(threadLong)}
		id := C.GoString(message)
		if _, err := a.cli.MarkRead(a.ctx, &slidetypes.MarkReadRequest{
			Metadata: meta, Data: slidetypes.MarkReadData{MessageID: id, ItemID: new("")},
		}); err != nil {
			return nil, err
		}
		return a.cli.MarkReadValidation(a.ctx, &slidetypes.MarkReadRequest{
			Metadata: meta, Data: slidetypes.MarkReadData{MessageID: id, MessageTimestampMS: jsontime.UnixMilliString{Time: time.UnixMilli(int64(tsMS))}},
		})
	})
}

//export IGTyping
func IGTyping(acct, thread *C.char, on C.int) *C.char {
	return call(acct, "typing", func(a *account) (any, error) {
		a.count.add("typing (socket)") // goes over the socket, so the HTTP counter doesn't see it
		return map[string]bool{"ok": true}, a.cli.SetTyping(a.ctx, C.GoString(thread), on != 0)
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
	a, err := get(acct)
	if err != nil {
		return fail(err)
	}
	b, _ := json.Marshal(a.cli.GetCookies().GetAll())
	return C.CString(string(b))
}

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
