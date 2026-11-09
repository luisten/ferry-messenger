package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"maps"
	"net"
	"net/http"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/luisten/ferry-messenger/core/engine"
)

// What reaches Instagram, replaced in tests: the engine (listen-only) and the web logout.
var (
	login       = engine.Login
	resume      = engine.Resume
	stopAccount = engine.Stop
	session     = engine.Session
	nextEvent   = engine.NextEvent
	counts      = engine.Counts
	logOut      = logOutAtInstagram
)

type relay struct {
	store *store
	apns  *apns // nil: no key, pushes are logged and dropped (local checks only)
	limit limiter

	mu     sync.Mutex
	status map[string]*status // by account, while this process runs
}

type status struct {
	Connected bool
	Since     time.Time
	Error     string
}

func newRelay(st *store, push *apns) *relay {
	return &relay{store: st, apns: push, status: map[string]*status{}, limit: limiter{m: map[string]*window{}}}
}

// MARK: The API (PLAN-relay §2): five endpoints, JSON, a phone's token on all but pairing.

const maxBody = 64 << 10

var errNotFound = errors.New("no such account") // the same for an unknown account and another phone's

func (r *relay) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/pair", r.pair)
	mux.HandleFunc("PUT /v1/apns", r.authed(r.setAPNs))
	mux.HandleFunc("PUT /v1/accounts", r.authed(r.add))
	mux.HandleFunc("DELETE /v1/accounts/{id}", r.authed(r.drop))
	mux.HandleFunc("GET /v1/status", r.authed(r.statusOf))
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		req.Body = http.MaxBytesReader(w, req.Body, maxBody)
		w.Header().Set("cache-control", "no-store")
		mux.ServeHTTP(w, req)
	})
}

func reply(w http.ResponseWriter, code int, v any) {
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, code int, msg string) {
	reply(w, code, map[string]string{"error": msg})
}

func decode(w http.ResponseWriter, req *http.Request, v any) bool {
	if err := json.NewDecoder(req.Body).Decode(v); err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			fail(w, http.StatusRequestEntityTooLarge, "too large")
		} else {
			fail(w, http.StatusBadRequest, "bad request")
		}
		return false
	}
	return true
}

func ip(req *http.Request) string {
	host, _, err := net.SplitHostPort(req.RemoteAddr)
	if err != nil {
		return req.RemoteAddr
	}
	return host
}

// authed lets a request through with a paired phone's token (`Authorization: Bearer …`), compared in constant time;
// failures count against the IP.
func (r *relay) authed(next func(w http.ResponseWriter, req *http.Request, phone string)) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		if r.limit.blocked(ip(req)) {
			fail(w, http.StatusTooManyRequests, "too many attempts")
			return
		}
		token, _ := strings.CutPrefix(req.Header.Get("authorization"), "Bearer ")
		h := hash(token)
		st, err := r.store.read()
		if err != nil {
			fail(w, http.StatusInternalServerError, "unavailable")
			return
		}
		found := ""
		for k := range st.Phones {
			if subtle.ConstantTimeCompare([]byte(k), []byte(h)) == 1 {
				found = k
			}
		}
		if token == "" || found == "" {
			r.limit.fail(ip(req))
			fail(w, http.StatusUnauthorized, "not paired")
			return
		}
		next(w, req, found)
	}
}

// inviteCode normalizes what a person typed: case, dashes and spaces don't matter.
func inviteCode(s string) string {
	return strings.NewReplacer("-", "", " ", "").Replace(strings.ToUpper(s))
}

// pair takes a one-time invite code from the relay's operator and gives the phone its own token, kept here only as a
// hash.
func (r *relay) pair(w http.ResponseWriter, req *http.Request) {
	if r.limit.blocked(ip(req)) {
		fail(w, http.StatusTooManyRequests, "too many attempts")
		return
	}
	var body struct {
		Invite string `json:"invite"`
	}
	if !decode(w, req, &body) {
		return
	}
	raw := make([]byte, 32)
	_, _ = rand.Read(raw)
	token := base64.RawURLEncoding.EncodeToString(raw)
	ok := false
	err := r.store.update(func(st *state) error {
		now := time.Now().UnixMilli()
		maps.DeleteFunc(st.Invites, func(_ string, expires int64) bool { return expires < now })
		h := hash(inviteCode(body.Invite))
		if _, ok = st.Invites[h]; ok {
			delete(st.Invites, h)
			st.Phones[hash(token)] = &phone{}
		}
		return nil
	})
	switch {
	case err == nil && !ok:
		r.limit.fail(ip(req))
		fail(w, http.StatusUnauthorized, "bad or expired invite")
	case err != nil:
		fail(w, http.StatusInternalServerError, "unavailable")
	default:
		record("", "paired", nil)
		reply(w, http.StatusOK, map[string]string{"token": token})
	}
}

func (r *relay) setAPNs(w http.ResponseWriter, req *http.Request, me string) {
	var body struct {
		Token   string `json:"token"`
		Sandbox bool   `json:"sandbox"`
	}
	if !decode(w, req, &body) {
		return
	}
	if len(body.Token) < 32 || len(body.Token) > 200 || strings.Trim(body.Token, "0123456789abcdefABCDEF") != "" {
		fail(w, http.StatusBadRequest, "bad APNs token")
		return
	}
	err := r.store.update(func(st *state) error {
		st.Phones[me].APNs, st.Phones[me].Sandbox = body.Token, body.Sandbox
		return nil
	})
	if err != nil {
		fail(w, http.StatusInternalServerError, "unavailable")
		return
	}
	reply(w, http.StatusOK, map[string]bool{"ok": true})
}

// add starts listening for an account with its relay session (R2: its own login, made by hand in Ferry's web view):
// one index and mailbox load, then the socket. The cookies say which account; the app checks that it's the one it
// meant, and drops it otherwise. An account already here moves to this session: the old one is ended.
func (r *relay) add(w http.ResponseWriter, req *http.Request, me string) {
	var body struct {
		Cookies map[string]string `json:"cookies"`
	}
	if !decode(w, req, &body) {
		return
	}
	if len(body.Cookies) == 0 {
		fail(w, http.StatusBadRequest, "no session")
		return
	}
	b, _ := json.Marshal(body.Cookies)
	out, err := login(string(b))
	if err != nil {
		code, reason := engine.Classify(err)
		if code == "BAD_CREDENTIALS" {
			fail(w, http.StatusUnprocessableEntity, "Instagram refused the session: "+reason)
		} else {
			fail(w, http.StatusBadGateway, "Instagram couldn't be reached")
		}
		return
	}
	id, _ := out["account"].(string)
	viewer, _ := out["viewer"].(map[string]any)
	username, _ := viewer["username"].(string)
	cur := current(id, body.Cookies)
	var old *account
	err = r.store.update(func(st *state) error {
		old = st.Accounts[id]
		st.Accounts[id] = &account{Phone: me, Username: username, Cookies: cur}
		return nil
	})
	if err != nil {
		stopAccount(id)
		fail(w, http.StatusInternalServerError, "unavailable")
		return
	}
	r.setStatus(id, func(s *status) { s.Error = "" })
	record(id, "added", nil)
	if old != nil && old.Cookies["sessionid"] != body.Cookies["sessionid"] {
		go func() {
			result, via, n := logOut(old.Cookies)
			record(id, "replaced session ended", map[string]any{"result": result, "via": via, "requests": n})
		}()
	}
	reply(w, http.StatusOK, map[string]string{"account": id, "username": username})
}

// drop ends the account's relay session for good (R10), in this order: the socket closes, the session is logged out
// at Instagram, its cookies are deleted. The answer says which happened.
func (r *relay) drop(w http.ResponseWriter, req *http.Request, me string) {
	id := req.PathValue("id")
	st, err := r.store.read()
	if err != nil {
		fail(w, http.StatusInternalServerError, "unavailable")
		return
	}
	a := st.Accounts[id]
	if a == nil || a.Phone != me {
		fail(w, http.StatusNotFound, errNotFound.Error())
		return
	}
	cur := current(id, a.Cookies)
	stopAccount(id)
	result, via, n := logOut(cur)
	record(id, "logout", map[string]any{"result": result, "via": via, "requests": n})
	err = r.store.update(func(st *state) error {
		delete(st.Accounts, id)
		if !slices.ContainsFunc(slices.Collect(maps.Values(st.Accounts)), func(a *account) bool { return a.Phone == me }) {
			if p := st.Phones[me]; p != nil {
				p.APNs = "" // nothing left to notify on this phone
			}
		}
		return nil
	})
	r.mu.Lock()
	delete(r.status, id)
	r.mu.Unlock()
	reply(w, http.StatusOK, map[string]any{"socket": "closed", "logout": result, "deleted": err == nil})
}

type accountStatus struct {
	Account   string `json:"account"`
	Username  string `json:"username"`
	Connected bool   `json:"connected"`
	Since     int64  `json:"since,omitempty"` // ms
	Error     string `json:"error,omitempty"`
}

func (r *relay) statusOf(w http.ResponseWriter, _ *http.Request, me string) {
	st, err := r.store.read()
	if err != nil {
		fail(w, http.StatusInternalServerError, "unavailable")
		return
	}
	out := []accountStatus{}
	r.mu.Lock()
	for _, id := range slices.Sorted(maps.Keys(st.Accounts)) {
		a := st.Accounts[id]
		if a.Phone != me {
			continue
		}
		s := accountStatus{Account: id, Username: a.Username, Error: a.Stopped}
		if live := r.status[id]; live != nil {
			s.Connected = live.Connected && a.Stopped == ""
			if !live.Since.IsZero() {
				s.Since = live.Since.UnixMilli()
			}
			if s.Error == "" {
				s.Error = live.Error
			}
		}
		out = append(out, s)
	}
	r.mu.Unlock()
	reply(w, http.StatusOK, map[string]any{"accounts": out})
}

func (r *relay) setStatus(id string, change func(s *status)) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.status[id] == nil {
		r.status[id] = &status{}
	}
	change(r.status[id])
}

// MARK: Failed attempts, per IP: 10 in 15 minutes, then nothing until the window ends. Behind the operator's proxy
// every request has the proxy's IP, so the limit becomes the whole relay's: stricter, still safe.

type limiter struct {
	mu sync.Mutex
	m  map[string]*window
}

type window struct {
	n     int
	until time.Time
}

const maxFailures, failureWindow = 10, 15 * time.Minute

func (l *limiter) blocked(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	w := l.m[ip]
	return w != nil && w.n >= maxFailures && time.Now().Before(w.until)
}

func (l *limiter) fail(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.m) > 10_000 { // ponytail: forgets everyone at once rather than sweeping old windows
		l.m = map[string]*window{}
	}
	w := l.m[ip]
	if w == nil || time.Now().After(w.until) {
		w = &window{until: time.Now().Add(failureWindow)}
		l.m[ip] = w
	}
	w.n++
}

// MARK: Listening: the engine's events become pushes and status.

// start listens for every stored account that hasn't stopped (Resume tries again by itself after a network failure).
func (r *relay) start() error {
	st, err := r.store.read()
	if err != nil {
		return err
	}
	for id, a := range st.Accounts {
		if a.Stopped != "" {
			continue
		}
		b, _ := json.Marshal(a.Cookies)
		go func() {
			if _, err := resume(id, string(b)); err != nil {
				if code, reason := engine.Classify(err); code == "BAD_CREDENTIALS" {
					r.stopped(id, reason)
				} else {
					r.setStatus(id, func(s *status) { s.Error = "network" })
					record(id, "start failed", map[string]any{"code": code})
				}
			}
		}()
	}
	return nil
}

// listen handles the engine's events until ctx ends.
func (r *relay) listen(ctx context.Context) {
	for ctx.Err() == nil {
		var events []json.RawMessage
		if b := nextEvent(time.Second); b != nil && json.Unmarshal(b, &events) == nil {
			for _, e := range events {
				r.event(e)
			}
		}
	}
}

type event struct {
	Kind    string `json:"kind"`
	Account string `json:"account"`
	Code    string `json:"code"`
	Reason  string `json:"reason"`
	Room    string `json:"room"`
	From    string `json:"from"`
	Group   string `json:"group"`
	Body    string `json:"body"`
}

func (r *relay) event(raw []byte) {
	var e event
	if json.Unmarshal(raw, &e) != nil || e.Account == "" {
		return
	}
	switch e.Kind {
	case "Notify":
		r.notify(e)
	case "Connected":
		r.setStatus(e.Account, func(s *status) { s.Connected, s.Since, s.Error = true, time.Now(), "" })
		record(e.Account, "connected", nil)
	case "Disconnected":
		r.setStatus(e.Account, func(s *status) { s.Connected, s.Since = false, time.Now() })
		record(e.Account, "disconnected", nil)
	case "Login":
		r.setStatus(e.Account, func(s *status) { s.Error = "" })
		record(e.Account, "logged in again", nil)
	case "AuthError", "LoginFailed":
		if e.Code == "BAD_CREDENTIALS" {
			r.stopped(e.Account, e.Reason)
			return
		}
		r.setStatus(e.Account, func(s *status) { s.Error = "network" })
		record(e.Account, strings.ToLower(e.Kind), map[string]any{"code": e.Code})
	}
}

// stopped: Instagram ended the session or wants a checkpoint. The relay stops listening for the account, says so in
// one push, and keeps its cookies until the phone drops it.
func (r *relay) stopped(id, reason string) {
	stopAccount(id)
	var a *account
	var p *phone
	_ = r.store.update(func(st *state) error {
		if a = st.Accounts[id]; a == nil || a.Stopped != "" {
			a = nil
			return errors.New("unchanged")
		}
		a.Stopped = nonEmpty(reason, "stopped")
		p = st.Phones[a.Phone]
		return nil
	})
	r.setStatus(id, func(s *status) { s.Connected = false })
	if a == nil {
		return
	}
	record(id, "stopped", map[string]any{"reason": a.Stopped})
	r.push(id, a.Phone, p, stoppedAlert(a.Username, id, a.Stopped))
}

// notify turns R6's notification into R5's alert: title the sender (a group's name), "To @account" with two or more
// accounts on this phone, the text or a line for media.
func (r *relay) notify(e event) {
	st, err := r.store.read()
	if err != nil {
		return
	}
	a := st.Accounts[e.Account]
	if a == nil || a.Stopped != "" {
		return
	}
	title, body, subtitle := e.From, e.Body, ""
	if e.Group != "" {
		title, body = e.Group, e.From+": "+e.Body
	}
	others := 0
	for _, b := range st.Accounts {
		if b.Phone == a.Phone && b.Stopped == "" {
			others++
		}
	}
	if others > 1 {
		subtitle = "To @" + a.Username
	}
	r.push(e.Account, a.Phone, st.Phones[a.Phone], alert(title, subtitle, body, e.Room, e.Account))
}

// push sends to the phone's device; Apple saying the token is gone forgets it. Logged without what it says.
func (r *relay) push(account, owner string, p *phone, payload []byte) {
	if p == nil || p.APNs == "" {
		record(account, "push skipped", map[string]any{"why": "no device token"})
		return
	}
	if r.apns == nil {
		record(account, "push skipped", map[string]any{"why": "no APNs key"})
		return
	}
	code, reason, err := r.apns.send(p.APNs, p.Sandbox, payload)
	if err != nil {
		record(account, "push failed", map[string]any{"error": "unreachable"})
		return
	}
	record(account, "push", map[string]any{"status": code, "reason": reason})
	if gone(code, reason) {
		_ = r.store.update(func(st *state) error {
			if q := st.Phones[owner]; q != nil && q.APNs == p.APNs {
				q.APNs = ""
			}
			return nil
		})
	}
}

// current is the account's cookies as Instagram rotated them while it ran, else `stored`.
func current(id string, stored map[string]string) map[string]string {
	var cur map[string]string
	if b, err := session(id); err == nil && json.Unmarshal(b, &cur) == nil && len(cur) > 0 {
		return cur
	}
	return stored
}

// keepCookies writes back the cookies Instagram rotated, so a restart resumes the same session.
func (r *relay) keepCookies() {
	_ = r.store.update(func(st *state) error {
		for id, a := range st.Accounts {
			if a.Stopped != "" {
				continue
			}
			a.Cookies = current(id, a.Cookies)
		}
		return nil
	})
}

func nonEmpty(s ...string) string {
	for _, v := range s {
		if v != "" {
			return v
		}
	}
	return ""
}
