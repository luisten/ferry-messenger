// Command relay is Ferry Messenger's notification relay (docs/PLAN-relay.md §2): an always-on, listen-only Instagram
// client with its own web session per account, which turns each new message into an APNs alert for the phone that
// turned notifications on. It never sends, reads, types or marks anything at Instagram; the one thing it changes there
// is ending its own session when notifications are turned off (R10).
//
//	relay serve    the API and the listening, until stopped
//	relay invite   a one-time code for pairing a phone, valid for a day
//
// Config comes from flags or the environment (RELAY_*). The state file (accounts and their sessions, phones' token
// hashes, invites) is the only data on disk, readable by the relay's user alone; Let's Encrypt's certificates, when the
// relay gets its own, are cached in `certs` beside it. The log (stderr) holds counts and errors, never cookies, tokens,
// message text, senders or chats.
package main

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"maps"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"golang.org/x/crypto/acme/autocert"

	"github.com/luisten/ferry-messenger/core/engine"
)

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

var (
	statePath = flag.String("state", env("RELAY_STATE", "relay.json"), "the state file (RELAY_STATE)")
	listen    = flag.String("listen", env("RELAY_LISTEN", ":8443"), "address to listen on (RELAY_LISTEN)")
	tlsMode   = flag.String("tls", env("RELAY_TLS", ""), "acme (Let's Encrypt, with -domain), files (-cert, -key) or none: plain HTTP, only behind your own TLS proxy (RELAY_TLS)")
	domain    = flag.String("domain", env("RELAY_DOMAIN", ""), "the relay's public name, for -tls acme (RELAY_DOMAIN)")
	certFile  = flag.String("cert", env("RELAY_CERT", ""), "certificate file, for -tls files (RELAY_CERT)")
	keyFile   = flag.String("key", env("RELAY_KEY", ""), "its key file (RELAY_KEY)")
	apnsKey   = flag.String("apns-key", env("RELAY_APNS_KEY", ""), "the APNs key (.p8); none: pushes are logged and dropped (RELAY_APNS_KEY)")
	apnsKeyID = flag.String("apns-key-id", env("RELAY_APNS_KEY_ID", ""), "its key ID (RELAY_APNS_KEY_ID)")
	teamID    = flag.String("team-id", env("RELAY_TEAM_ID", ""), "the Apple team ID (RELAY_TEAM_ID)")
	bundleID  = flag.String("bundle-id", env("RELAY_BUNDLE_ID", ""), "the app's bundle ID, the push topic (RELAY_BUNDLE_ID)")
)

func main() {
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: relay [flags] serve | invite")
		flag.PrintDefaults()
	}
	flag.Parse()
	st := &store{path: *statePath}
	var err error
	switch flag.Arg(0) {
	case "serve":
		err = serve(st)
	case "invite":
		err = invite(st, os.Stdout)
	default:
		flag.Usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "relay:", err)
		os.Exit(1)
	}
}

// invite adds a one-time pairing code, valid for 24 hours, and prints it for the operator to give a friend.
func invite(st *store, out io.Writer) error {
	code := rand.Text()[:10] // 50 bits; failed tries are rate-limited
	expires := time.Now().Add(24 * time.Hour)
	if err := st.update(func(s *state) error {
		s.Invites[hash(code)] = expires.UnixMilli()
		return nil
	}); err != nil {
		return err
	}
	fmt.Fprintf(out, "%s-%s (until %s)\n", code[:5], code[5:], expires.Format("2006-01-02 15:04"))
	return nil
}

func serve(st *store) error {
	var push *apns
	if *apnsKey != "" {
		var err error
		if push, err = newAPNs(*apnsKey, *apnsKeyID, *teamID, *bundleID); err != nil {
			return fmt.Errorf("APNs: %w", err)
		}
	} else {
		record("", "warning", map[string]any{"what": "no APNs key: pushes are logged and dropped"})
	}
	srv := &http.Server{
		Addr: *listen, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second,
		WriteTimeout: time.Minute, IdleTimeout: time.Minute, MaxHeaderBytes: 8 << 10,
	}
	var start func() error
	switch *tlsMode {
	case "acme":
		if *domain == "" {
			return errors.New("-tls acme needs -domain")
		}
		m := &autocert.Manager{
			Prompt: autocert.AcceptTOS, HostPolicy: autocert.HostWhitelist(*domain),
			Cache: autocert.DirCache(filepath.Join(filepath.Dir(*statePath), "certs")),
		}
		srv.TLSConfig = m.TLSConfig() // TLS-ALPN-01: no port 80
		srv.TLSConfig.MinVersion = tls.VersionTLS13
		start = func() error { return srv.ListenAndServeTLS("", "") }
	case "files":
		srv.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS13}
		start = func() error { return srv.ListenAndServeTLS(*certFile, *keyFile) }
	case "none":
		record("", "warning", map[string]any{"what": "plain HTTP: only behind your own TLS proxy (pairing carries Instagram sessions)"})
		start = srv.ListenAndServe
	default:
		return errors.New("choose -tls acme, files or none")
	}
	if _, err := st.read(); err != nil { // also makes the lock file
		return err
	}

	engine.ListenOnly()
	r := newRelay(st, push)
	srv.Handler = r.routes()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go r.listen(ctx)
	if err := r.start(); err != nil {
		return err
	}
	go func() {
		cookies, daily := time.NewTicker(10*time.Minute), time.NewTicker(24*time.Hour)
		for {
			select {
			case <-cookies.C:
				r.keepCookies()
			case <-daily.C:
				logCounts()
			case <-ctx.Done():
				return
			}
		}
	}()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sig
		r.keepCookies()
		logCounts()
		cancel()
		shut, done := context.WithTimeout(context.Background(), 5*time.Second)
		defer done()
		_ = srv.Shutdown(shut)
	}()
	record("", "serving", map[string]any{"listen": *listen, "tls": *tlsMode})
	if err := start(); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// C6: the requests each account made since its client logged in, by operation. ponytail: cumulative since that login,
// not per day; a re-login starts it again.
func logCounts() {
	for id, n := range counts() {
		record(id, "requests", map[string]any{"counts": n})
	}
}

var (
	logMu sync.Mutex
	logTo io.Writer = os.Stderr
)

// record writes one line to the log: when, which account, what happened. Never text, senders, chats, cookies or
// tokens.
func record(account, what string, fields map[string]any) {
	line := map[string]any{"t": time.Now().UTC().Format(time.RFC3339Nano), "event": what}
	if account != "" {
		line["account"] = account
	}
	maps.Copy(line, fields)
	b, _ := json.Marshal(line)
	logMu.Lock()
	defer logMu.Unlock()
	_, _ = logTo.Write(append(b, '\n'))
}
