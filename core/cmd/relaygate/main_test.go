package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// The recorded live events (P0's capture): the three new messages count, with whether they're the account's own;
// reactions, edits, deletes, read marks and the rest don't.
func TestIncomingReadsOnlyNewMessages(t *testing.T) {
	b, err := os.ReadFile("../../testdata/ig_events_tamo.json")
	if err != nil {
		t.Fatal(err)
	}
	var events []struct {
		Account string          `json:"account"`
		Kind    string          `json:"kind"`
		Delta   json.RawMessage `json:"delta"`
	}
	if err := json.Unmarshal(b, &events); err != nil {
		t.Fatal(err)
	}
	messages, own := 0, 0
	for _, e := range events {
		if e.Kind != "Delta" {
			continue
		}
		sent, mine, ok := incoming(e.Delta, e.Account)
		if !ok {
			continue
		}
		if sent < 1_700_000_000_000 {
			t.Errorf("sent at %d", sent)
		}
		messages++
		if mine {
			own++
		}
	}
	if messages != 3 {
		t.Errorf("%d new messages, want 3", messages)
	}
	if own == messages {
		t.Error("every message read as the account's own")
	}
	if _, _, ok := incoming([]byte(`{"__typename":"SlideUQPPCreateReaction","message":{"sender_fbid":"1","timestamp_ms":"1"}}`), "1"); ok {
		t.Error("a reaction read as a message")
	}
}

func TestSummarizeADay(t *testing.T) {
	at := time.Date(2026, 11, 1, 12, 0, 0, 0, time.Local).UnixMilli()
	lines := []map[string]any{
		{"t": at, "account": "7", "event": "check", "connected": true},
		{"t": at + 1, "account": "7", "event": "check", "connected": false},
		{"t": at + 2, "account": "7", "event": "disconnected", "failures": 1},
		{"t": at + 3, "account": "7", "event": "message", "own": false, "delay_ms": 900},
		{"t": at + 4, "account": "7", "event": "message", "own": false, "delay_ms": 4000},
		{"t": at + 5, "account": "7", "event": "message", "own": true, "delay_ms": 100},
		{"t": at + 6, "account": "7", "event": "requests", "counts": map[string]int{"socket connect": 2, "GET www.instagram.com/direct/inbox/": 1}},
		{"t": at + 7, "account": "7", "event": "trouble", "reason": "checkpoint"},
	}
	var log strings.Builder
	for _, l := range lines {
		b, _ := json.Marshal(l)
		log.Write(append(b, '\n'))
	}
	d := summarize(strings.NewReader(log.String()))["2026-11-01 7"]
	if d == nil {
		t.Fatal("no day")
	}
	if d.checks != 2 || d.connectedChecks != 1 || d.drops != 1 || d.messages != 2 || d.own != 1 || d.worstMS != 4000 || d.requests != 3 {
		t.Errorf("%+v", *d)
	}
	if len(d.notes) != 1 || d.notes[0] != "trouble: checkpoint" {
		t.Errorf("notes %v", d.notes)
	}
}

// The state file holds sessions: this user only, also after a rewrite.
func TestTheStateFileIsPrivate(t *testing.T) {
	dir = t.TempDir()
	s := &state{Accounts: map[string]*stored{"7": {Username: "tamoveska", Cookies: nil}}}
	for range 2 {
		if err := save(s); err != nil {
			t.Fatal(err)
		}
	}
	info, err := os.Stat(filepath.Join(dir, "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", info.Mode().Perm())
	}
	back, err := load()
	if err != nil || back.Accounts["7"].Username != "tamoveska" {
		t.Errorf("%v %+v", err, back)
	}
}

// Only the session itself proves a logout: a request that "worked" while the session still loads is still open.
func TestEndSessionTrustsOnlyTheSession(t *testing.T) {
	for _, c := range []struct {
		name        string
		endsAfter   int   // posts until the session stops loading; 0 never
		err         error // what checking the session says otherwise
		result, via string
		posts       int
	}{
		{"the current path ends it", 1, nil, "ended", logoutPaths[0], 1},
		{"only the older path does", 2, nil, "ended", logoutPaths[1], 2},
		{"neither does", 0, nil, "still open", "", 2},
		{"the check can't reach Instagram", 0, errors.New("network"), "unknown", "", 2},
	} {
		posts := 0
		result, via := endSession(func(string) { posts++ }, func() (bool, error) {
			if c.endsAfter > 0 && posts >= c.endsAfter {
				return false, nil
			}
			return c.err == nil, c.err
		})
		if result != c.result || via != c.via || posts != c.posts {
			t.Errorf("%s: %q %q after %d posts", c.name, result, via, posts)
		}
	}
}

// A logout while `run` listens would read as Instagram ending the session: remove waits for run to stop.
func TestRemoveWaitsForRun(t *testing.T) {
	dir = t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "run.pid"), []byte(strconv.Itoa(os.Getpid())), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := remove("tamoveska"); err == nil || !strings.Contains(err.Error(), "stop relaygate run first") {
		t.Errorf("remove during run: %v", err)
	}
}
