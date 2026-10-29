// Command relaygate is step 1 of docs/PLAN-relay.md, and throwaway: a listen-only Instagram client that answers one
// question before the relay is built. Does Instagram tolerate an always-on web session from the relay's host? Each
// account has its own web session, made by hand in relaygate-login and piped into `add`. The gate listens on the
// socket and logs what a relay would care about: connects, drops, each incoming message's delay, and any trouble with
// the session. Never message text, senders, chats or cookies. It never sends, reads, types or pages folders.
//
//	relaygate-login | relaygate add   a new account (one index load to learn which)
//	caffeinate -s relaygate run       listen until stopped (Ctrl-C)
//	relaygate report                  per day: hourly checks connected, drops, messages, worst delay, requests, notes
//	relaygate remove <id|@handle>     log the session out at Instagram, prove it, then forget it (stop run first)
//
// State and log live in ~/Library/Application Support/FerryRelayGate (or -dir), readable by this user only.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"maps"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/rs/zerolog"

	"go.mau.fi/mautrix-meta/pkg/instameow"
	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"go.mau.fi/mautrix-meta/pkg/messagix/cookies"
	"go.mau.fi/mautrix-meta/pkg/messagix/httpclient"
	"go.mau.fi/mautrix-meta/pkg/messagix/types"
)

type state struct {
	Accounts map[string]*stored `json:"accounts"` // by Instagram account ID
}

type stored struct {
	Username string                            `json:"username"`
	Cookies  map[cookies.MetaCookieName]string `json:"cookies"`
}

var (
	dir     string
	stateMu sync.Mutex
	logMu   sync.Mutex
)

func main() {
	home, _ := os.UserConfigDir()
	flag.StringVar(&dir, "dir", filepath.Join(home, "FerryRelayGate"), "where the state and log live")
	flag.Usage = func() { fmt.Fprintln(os.Stderr, "usage: relaygate [-dir d] add | run | report | remove <id|@handle>") }
	flag.Parse()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		fail(err)
	}
	var err error
	switch flag.Arg(0) {
	case "add":
		err = add(os.Stdin)
	case "run":
		err = run()
	case "report":
		err = report(os.Stdout)
	case "remove":
		err = remove(flag.Arg(1))
	default:
		flag.Usage()
		os.Exit(2)
	}
	if err != nil {
		fail(err)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "relaygate:", err)
	os.Exit(1)
}

// add reads one session's cookies from relaygate-login's pipe, loads the index once to learn whose they are, and keeps
// them (as Instagram has just rotated them) in the state file.
func add(in *os.File) error {
	if info, err := in.Stat(); err != nil || info.Mode()&os.ModeNamedPipe == 0 {
		return errors.New("pipe relaygate-login into this: cookies are never typed, pasted or kept in a file")
	}
	var raw map[cookies.MetaCookieName]string
	if err := json.NewDecoder(io.LimitReader(in, 64<<10)).Decode(&raw); err != nil {
		return fmt.Errorf("reading the session: %w", err)
	}
	cli, c, _ := client(raw, func(context.Context, slidetypes.ClientEvent) error { return nil })
	if missing := c.GetMissingCookieNames(); len(missing) > 0 {
		return fmt.Errorf("the session misses cookies %v", missing)
	}
	viewer, _, err := cli.LoadIndex(context.Background())
	if err != nil {
		return fmt.Errorf("Instagram refused the session: %w", err)
	}
	id := strconv.FormatInt(cli.GetOwnFBID(), 10)
	if id == "0" {
		return errors.New("Instagram didn't say which account this is")
	}
	s, err := load()
	if err != nil {
		return err
	}
	s.Accounts[id] = &stored{Username: viewer.Data.Username, Cookies: cli.GetCookies().GetAll()}
	if err := save(s); err != nil {
		return err
	}
	record(id, "added", nil)
	fmt.Printf("Added @%s (%s). Start listening with: caffeinate -s relaygate run\n", viewer.Data.Username, id)
	return nil
}

func remove(which string) error {
	if running() {
		return errors.New("stop relaygate run first (Ctrl-C): it would log the logout as trouble")
	}
	s, err := load()
	if err != nil {
		return err
	}
	for id, a := range s.Accounts {
		if which != id && strings.TrimPrefix(which, "@") != a.Username {
			continue
		}
		result, via := logOut(id, a.Cookies)
		record(id, "logout", map[string]any{"result": result, "via": via})
		delete(s.Accounts, id)
		if err := save(s); err != nil {
			return err
		}
		if result == "ended" {
			fmt.Printf("Logged @%s out at Instagram (its session no longer works: checked) and forgot it.\n", a.Username)
		} else {
			fmt.Printf("Forgot @%s here, but Instagram may still accept its session (%s): end it in Instagram's \"Where you're logged in\".\n", a.Username, result)
		}
		return nil
	}
	return fmt.Errorf("no account %q", which)
}

// The web logout isn't documented: the website's current path first, then its older one.
var logoutPaths = []string{"/api/v1/web/accounts/logout/ajax/", "/accounts/logout/ajax/"}

// logOut sends instagram.com's own logout for this session, as the website's Log out does (the library has none),
// and returns "ended", "still open" or "unknown" with the path that ended it. One index load first gives the request
// the website's headers (the CSRF token among them).
func logOut(id string, raw map[cookies.MetaCookieName]string) (result, via string) {
	ctx := context.Background()
	noop := func(context.Context, slidetypes.ClientEvent) error { return nil }
	cli, c, n := client(raw, noop)
	defer func() { record(id, "requests", map[string]any{"counts": n.take()}) }()
	if _, _, err := cli.LoadIndex(ctx); err != nil {
		if errors.Is(err, httpclient.ErrTokenInvalidated) {
			return "ended", "already"
		}
		reason, _ := classify(err)
		return "unknown (" + reason + ")", ""
	}
	post := func(path string) {
		h := cli.GetHTTP()
		headers := h.BuildHeaders(true, false)
		headers.Set("x-requested-with", "XMLHttpRequest")
		headers.Set("referer", "https://www.instagram.com/")
		form := url.Values{"one_tap_app_login": {"0"}, "user_id": {c.Get(cookies.IGCookieDSUserID)}}
		_, _, _ = h.MakeRequest(ctx, "https://www.instagram.com"+path, http.MethodPost, headers, []byte(form.Encode()), types.FORM)
	}
	// The proof: a fresh client on the original cookies, as a copy of them would be used. The first client's own jar
	// may have dropped them on the logout's answer, which proves nothing about Instagram's side.
	alive := func() (bool, error) {
		fresh, _, m := client(raw, noop)
		_, _, err := fresh.LoadIndex(ctx)
		n.add(m.take())
		if errors.Is(err, httpclient.ErrTokenInvalidated) {
			return false, nil
		}
		return err == nil, err
	}
	return endSession(post, alive)
}

// endSession tries each logout until the session itself says it's over: Instagram refusing it as logged out is the
// only answer that counts, whatever the logout request answered.
func endSession(post func(path string), alive func() (bool, error)) (result, via string) {
	result = "still open"
	for _, path := range logoutPaths {
		post(path)
		switch ok, err := alive(); {
		case !ok && err == nil:
			return "ended", path
		case err != nil:
			result = "unknown"
		}
	}
	return result, ""
}

// running says whether a `relaygate run` is going (its pid file names a live process).
func running() bool {
	b, err := os.ReadFile(filepath.Join(dir, "run.pid"))
	if err != nil {
		return false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	return err == nil && syscall.Kill(pid, 0) == nil
}

// A client on these cookies with nothing logged (the library's logs can carry what Instagram sent), counting every
// request it makes (C6).
func client(raw map[cookies.MetaCookieName]string, handle instameow.EventHandler) (*instameow.Client, *cookies.Cookies, *counter) {
	c := &cookies.Cookies{Platform: types.Instagram}
	c.UpdateValues(raw)
	cli := instameow.NewClient(instameow.ClientParams{Cookies: c, Log: zerolog.Nop(), DisableTyping: true, EventHandler: handle})
	h := cli.GetHTTP()
	count := &counter{next: h.HTTP.Transport, n: map[string]int{}}
	h.HTTP.Transport = count
	return cli, c, count
}

// One account's listener. It never calls anything that acts on Instagram: only LoadIndex and the socket.
type listener struct {
	id, username string
	connected    atomic.Bool

	mu   sync.Mutex
	cli  *instameow.Client
	stop context.CancelFunc
	n    *counter
	done bool // signed out or stopped: no more starts
}

func run() error {
	s, err := load()
	if err != nil {
		return err
	}
	if len(s.Accounts) == 0 {
		return errors.New("no accounts yet: relaygate-login | relaygate add")
	}
	if running() {
		return errors.New("relaygate run is already going")
	}
	pidFile := filepath.Join(dir, "run.pid")
	if err := os.WriteFile(pidFile, []byte(strconv.Itoa(os.Getpid())), 0o600); err != nil {
		return err
	}
	defer os.Remove(pidFile)
	var all []*listener
	for id, a := range s.Accounts {
		l := &listener{id: id, username: a.Username}
		all = append(all, l)
		go l.start(a.Cookies)
		fmt.Printf("Listening for @%s.\n", a.Username)
	}
	fmt.Println("Log:", filepath.Join(dir, "gate.log"), "· stop with Ctrl-C")
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	hourly := time.NewTicker(time.Hour)
	saving := time.NewTicker(10 * time.Minute)
	for {
		select {
		case <-hourly.C:
			for _, l := range all {
				record(l.id, "check", map[string]any{"connected": l.connected.Load()})
				l.flushCounts()
			}
		case <-saving.C:
			keepCookies(all)
		case <-sig:
			keepCookies(all)
			for _, l := range all {
				l.flushCounts()
				l.halt()
				record(l.id, "stopped", nil)
			}
			return nil
		}
	}
}

// start loads the index once and connects the socket; a network failure tries again a minute later.
func (l *listener) start(raw map[cookies.MetaCookieName]string) {
	for {
		l.mu.Lock()
		if l.done {
			l.mu.Unlock()
			return
		}
		cli, _, n := client(raw, l.handle)
		if l.n != nil {
			n.add(l.n.take()) // what the last client counted, not yet logged
		}
		l.cli, l.n = cli, n
		l.mu.Unlock()

		_, _, err := cli.LoadIndex(context.Background())
		if err == nil && strconv.FormatInt(cli.GetOwnFBID(), 10) != l.id {
			err = errors.New("these cookies belong to another account")
		}
		if err == nil {
			ctx, stop := context.WithCancel(context.Background())
			l.mu.Lock()
			l.stop = stop
			l.mu.Unlock()
			record(l.id, "started", nil)
			go cli.Connect(ctx)
			return
		}
		reason, passing := classify(err)
		record(l.id, "start failed", map[string]any{"reason": reason})
		if !passing {
			l.signedOut(reason)
			return
		}
		time.Sleep(time.Minute)
	}
}

func (l *listener) handle(_ context.Context, evt slidetypes.ClientEvent) error {
	switch evt := evt.(type) {
	case *slidetypes.Connected:
		l.connected.Store(true)
		l.counts().add(map[string]int{"socket connect": 1})
		record(l.id, "connected", nil)
	case *slidetypes.Disconnected:
		l.connected.Store(false)
		record(l.id, "disconnected", map[string]any{"failures": evt.FailureCount})
	case *slidetypes.AuthError:
		reason, _ := classify(evt.Error)
		l.signedOut(reason)
	case *slidetypes.ResnapshotRequired:
		// Instagram can't replay what the socket missed: load the index again, as the app does.
		record(l.id, "resnapshot", nil)
		l.mu.Lock()
		cur := l.cli.GetCookies().GetAll()
		l.mu.Unlock()
		l.halt()
		go l.start(cur)
	case *slidetypes.Delta:
		if sent, own, ok := incoming(evt.Raw, l.id); ok {
			record(l.id, "message", map[string]any{"own": own, "delay_ms": time.Now().UnixMilli() - sent})
		}
	}
	return nil
}

// The trouble the gate is looking for: Instagram ended the session or wants a checkpoint. It stops listening for that
// account, as a relay would, rather than logging in again.
func (l *listener) signedOut(reason string) {
	l.connected.Store(false)
	record(l.id, "trouble", map[string]any{"reason": reason})
	l.mu.Lock()
	l.done = true
	l.mu.Unlock()
	l.halt()
}

func (l *listener) halt() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.stop != nil {
		l.stop()
		l.stop = nil
	}
}

func (l *listener) counts() *counter {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.n
}

func (l *listener) flushCounts() {
	if n := l.counts(); n != nil {
		if c := n.take(); len(c) > 0 {
			record(l.id, "requests", map[string]any{"counts": c})
		}
	}
}

// keepCookies writes back the cookies Instagram rotated since the last save, so a restart resumes the same session.
func keepCookies(all []*listener) {
	s, err := load()
	if err != nil {
		return
	}
	changed := false
	for _, l := range all {
		l.mu.Lock()
		cli := l.cli
		l.mu.Unlock()
		if a := s.Accounts[l.id]; a != nil && cli != nil {
			if cur := cli.GetCookies().GetAll(); !maps.Equal(cur, a.Cookies) {
				a.Cookies, changed = cur, true
			}
		}
	}
	if changed {
		_ = save(s)
	}
}

// incoming reads a delta: a new message (Instagram's three kinds of it), when it was sent, and whether it's ours.
func incoming(raw []byte, self string) (sent int64, own, ok bool) {
	var d struct {
		Typename string `json:"__typename"`
		Message  *struct {
			Sender string `json:"sender_fbid"`
			At     string `json:"timestamp_ms"`
		} `json:"message"`
	}
	if json.Unmarshal(raw, &d) != nil || d.Message == nil {
		return 0, false, false
	}
	switch d.Typename {
	case "SlideUQPPNewMessage", "SlideUQPPNewRavenMessage", "SlideUQPPNewGenieMessage":
	default:
		return 0, false, false
	}
	sent, err := strconv.ParseInt(d.Message.At, 10, 64)
	return sent, d.Message.Sender == self, err == nil
}

// classify names why Instagram refused, and whether trying again later makes sense (the network) or not.
func classify(err error) (reason string, passing bool) {
	for _, c := range []struct {
		err    error
		reason string
	}{
		{httpclient.ErrTokenInvalidated, "logged out"}, {httpclient.ErrChallengeRequired, "challenge"},
		{httpclient.ErrCheckpointRequired, "checkpoint"}, {httpclient.ErrConsentRequired, "consent"},
		{httpclient.ErrAccountSuspended, "suspended"},
	} {
		if errors.Is(err, c.err) {
			return c.reason, false
		}
	}
	var netErr net.Error
	if errors.As(err, &netErr) || errors.Is(err, context.DeadlineExceeded) {
		return "network", true
	}
	if err != nil && strings.Contains(err.Error(), "another account") {
		return "another account", false
	}
	return "other", true
}

// C6: every request to Instagram, by GraphQL operation name, else method and path.
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
	c.add(map[string]int{name: 1})
	return c.next.RoundTrip(r)
}

func (c *counter) add(m map[string]int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for k, v := range m {
		c.n[k] += v
	}
}

func (c *counter) take() map[string]int {
	c.mu.Lock()
	defer c.mu.Unlock()
	m := c.n
	c.n = map[string]int{}
	return m
}

// The state file: accounts and their cookies, this user only. Written whole, through a temporary file.
func load() (*state, error) {
	stateMu.Lock()
	defer stateMu.Unlock()
	s := &state{Accounts: map[string]*stored{}}
	b, err := os.ReadFile(filepath.Join(dir, "state.json"))
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, s); err != nil {
		return nil, err
	}
	if s.Accounts == nil {
		s.Accounts = map[string]*stored{}
	}
	return s, nil
}

func save(s *state) error {
	stateMu.Lock()
	defer stateMu.Unlock()
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	path := filepath.Join(dir, "state.json")
	if err := os.WriteFile(path+".tmp", b, 0o600); err != nil {
		return err
	}
	return os.Rename(path+".tmp", path)
}

// record appends one line to the log: when, which account, what happened. Never text, senders, chats or cookies.
func record(account, event string, fields map[string]any) {
	line := map[string]any{"t": time.Now().UnixMilli(), "account": account, "event": event}
	maps.Copy(line, fields)
	b, _ := json.Marshal(line)
	logMu.Lock()
	defer logMu.Unlock()
	f, err := os.OpenFile(filepath.Join(dir, "gate.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.Write(append(b, '\n'))
}

// report sums the log up per day and account.
func report(out io.Writer) error {
	f, err := os.Open(filepath.Join(dir, "gate.log"))
	if errors.Is(err, os.ErrNotExist) {
		return errors.New("nothing logged yet: relaygate-login | relaygate add, then relaygate run")
	}
	if err != nil {
		return err
	}
	defer f.Close()
	s, _ := load()
	days := summarize(f)
	keys := slices.Sorted(maps.Keys(days))
	fmt.Fprintf(out, "%-10s  %-18s  %8s  %5s  %8s  %9s  %8s  %s\n", "day", "account", "checks", "drops", "messages", "worst", "requests", "notes")
	for _, k := range keys {
		d := days[k]
		name := d.account
		if s != nil && s.Accounts[d.account] != nil {
			name = "@" + s.Accounts[d.account].Username
		}
		fmt.Fprintf(out, "%-10s  %-18s  %3d of %-2d  %5d  %3d (+%d)  %8s  %8d  %s\n", d.day, name, d.connectedChecks, d.checks,
			d.drops, d.messages, d.own, time.Duration(d.worstMS)*time.Millisecond, d.requests, strings.Join(d.notes, ", "))
	}
	fmt.Fprintln(out, "\nchecks: hourly checks that found the socket connected, of those logged (a gap means the gate wasn't")
	fmt.Fprintln(out, "running or the Mac slept). messages: incoming (+ the account's own, sent from elsewhere). worst: the")
	fmt.Fprintln(out, "longest delay between a message's own time and its arrival.")
	return nil
}

type day struct {
	day, account                                  string
	checks, connectedChecks, drops, own, requests int
	messages                                      int
	worstMS                                       int64
	notes                                         []string
}

func summarize(r io.Reader) map[string]*day {
	days := map[string]*day{}
	scan := bufio.NewScanner(r)
	for scan.Scan() {
		var e struct {
			T         int64          `json:"t"`
			Account   string         `json:"account"`
			Event     string         `json:"event"`
			Connected bool           `json:"connected"`
			Own       bool           `json:"own"`
			DelayMS   int64          `json:"delay_ms"`
			Reason    string         `json:"reason"`
			Result    string         `json:"result"`
			Via       string         `json:"via"`
			Counts    map[string]int `json:"counts"`
		}
		if json.Unmarshal(scan.Bytes(), &e) != nil {
			continue
		}
		date := time.UnixMilli(e.T).Format("2006-01-02")
		d := days[date+" "+e.Account]
		if d == nil {
			d = &day{day: date, account: e.Account}
			days[date+" "+e.Account] = d
		}
		switch e.Event {
		case "check":
			d.checks++
			if e.Connected {
				d.connectedChecks++
			}
		case "disconnected":
			d.drops++
		case "message":
			if e.Own {
				d.own++
			} else {
				d.messages++
			}
			d.worstMS = max(d.worstMS, e.DelayMS)
		case "trouble", "start failed":
			d.notes = append(d.notes, e.Event+": "+e.Reason)
		case "resnapshot":
			d.notes = append(d.notes, "resnapshot")
		case "logout":
			d.notes = append(d.notes, "logout: "+e.Result+" "+e.Via)
		case "requests":
			for _, n := range e.Counts {
				d.requests += n
			}
		}
	}
	return days
}
