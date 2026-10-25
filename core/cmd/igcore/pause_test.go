package main

import (
	"context"
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
