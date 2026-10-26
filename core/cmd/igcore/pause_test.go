package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"

	"go.mau.fi/mautrix-meta/pkg/messagix/dgw"
)

// What IGPause and IGUnpause rely on in the library: a socket whose context ends dials again on the next Connect,
// while one stopped with Disconnect never does (Connect returns at once, as if closed cleanly). 1.6.0 paused with
// Disconnect, so after the app's first return no message, typing or echo arrived until a relaunch.
func TestASocketReconnectsAfterItsContextEnds(t *testing.T) {
	var dials atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		dials.Add(1)
		defer c.CloseNow()
		_, _, _ = c.Read(r.Context()) // until the client goes
	}))
	defer srv.Close()
	sock := dgw.NewSocket(dgw.SocketOptions{
		WSURL:      "ws" + strings.TrimPrefix(srv.URL, "http"),
		GetCookies: func() string { return "" },
		OnConnect:  func(context.Context, func(error)) error { return nil },
	})
	connect := func(ctx context.Context) chan error {
		done := make(chan error, 1)
		go func() { done <- sock.Connect(ctx) }()
		return done
	}
	waitFor := func(n int32) {
		for deadline := time.Now().Add(5 * time.Second); dials.Load() < n; time.Sleep(10 * time.Millisecond) {
			if time.Now().After(deadline) {
				t.Fatalf("%d dials, want %d", dials.Load(), n)
			}
		}
	}

	ctx, pause := context.WithCancel(context.Background())
	done := connect(ctx)
	waitFor(1)
	pause()
	<-done
	ctx, pause = context.WithCancel(context.Background())
	done = connect(ctx)
	waitFor(2) // unpaused: the same socket is back

	sock.Disconnect()
	<-done
	if err := <-connect(context.Background()); err != nil || dials.Load() != 2 {
		t.Fatalf("after Disconnect: err %v, %d dials; if it reconnects now, IGPause could use it again", err, dials.Load())
	}
	pause()
}

// A retry that comes due in the background waits for the app: IGUnpause starts it again 30 s on, so the app's own
// connect on return (IGResume, whose stopRetry cancels it) goes first. A removed account never retries.
func TestARetryWaitsForTheAppToComeBack(t *testing.T) {
	offline := &net.OpError{Op: "dial", Err: errors.New("no network")}
	started := func(id string) (kept, running bool) {
		mu.Lock()
		defer mu.Unlock()
		r := retries[id]
		return r != nil, r != nil && r.timer != nil
	}
	paused.Store(true)
	defer paused.Store(false)

	retryLater("1", "{}", offline)
	if kept, running := started("1"); !kept || running {
		t.Fatalf("in the background: kept %v, started %v", kept, running)
	}
	IGUnpause()
	if _, running := started("1"); !running {
		t.Fatal("back in the app: not started")
	}
	IGPause()
	if kept, running := started("1"); !kept || running {
		t.Fatalf("in the background again: kept %v, started %v", kept, running)
	}
	stopRetry("1") // IGResume, first thing
	if kept, _ := started("1"); kept {
		t.Fatal("the app's connect didn't cancel it")
	}

	mu.Lock()
	removed["2"] = true
	mu.Unlock()
	retryLater("2", "{}", offline)
	if kept, _ := started("2"); kept {
		t.Fatal("a removed account retries")
	}
	mu.Lock()
	delete(removed, "2")
	mu.Unlock()
}
