// Spike helper on the Mac: a minimal Mozilla autopush client (docs/PLAN-push.md step 1). Makes a channel with
// Instagram's VAPID key and keeps its UAID, so it can come back later and take what Mozilla held meanwhile, the way the
// app will after a wake.
//
//	autopush setup <state.json>                          new UAID and channel; the endpoint goes in the state
//	autopush drain <state.json> <keys.json> <dir> <s> [noack]
//	                                                      connects for s seconds, writes each push to dir (raw and
//	                                                      decrypted), prints a summary, acks unless noack
//	autopush drop <state.json>                           unregisters the channel
//
// The summary never prints a push's text or names, only its shape; dir holds the rest (outside the repo).
// ponytail: one channel, no reconnect; enough to see what Mozilla keeps for a client that isn't connected.
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"

	"go.mau.fi/mautrix-meta/pkg/messagix/pushcrypto"
)

const igVAPID = "BIBn3E_rWTci8Xn6P9Xj3btShT85Wdtne0LtwNUyRQ5XjFNkuTq9j4MPAVLvAFhXrUU1A9UxyxBA7YIOjqDIDHI" // igconnector/push.go

type msg struct {
	MessageType  string            `json:"messageType"`
	UAID         string            `json:"uaid,omitempty"`
	Status       int               `json:"status,omitempty"`
	ChannelID    string            `json:"channelID,omitempty"`
	PushEndpoint string            `json:"pushEndpoint,omitempty"`
	Version      string            `json:"version,omitempty"`
	Data         string            `json:"data,omitempty"`
	Headers      map[string]string `json:"headers,omitempty"`
}

type state struct {
	UAID     string `json:"uaid"`
	Channel  string `json:"channel"`
	Endpoint string `json:"endpoint"`
}

type conn struct{ ws *websocket.Conn }

func dial() *conn {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(ctx, "wss://push.services.mozilla.com/", &websocket.DialOptions{Subprotocols: []string{"push-notification"}})
	if err != nil {
		fail("dial", err)
	}
	ws.SetReadLimit(1 << 20)
	return &conn{ws}
}

func (c *conn) send(v any) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	b, _ := json.Marshal(v)
	if err := c.ws.Write(ctx, websocket.MessageText, b); err != nil {
		fail("write", err)
	}
}

// read is the next message, or ok false once ctx ends.
func (c *conn) read(ctx context.Context) (m msg, ok bool) {
	_, b, err := c.ws.Read(ctx)
	if err != nil {
		if ctx.Err() != nil {
			return m, false
		}
		fail("read", err)
	}
	json.Unmarshal(b, &m)
	return m, true
}

// next is the next message within 10 s.
func (c *conn) next() msg {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	m, ok := c.read(ctx)
	if !ok {
		fail("read", ctx.Err())
	}
	return m
}

// hello with the saved UAID and channel (none for a new one): Mozilla answers the UAID it knows us by.
func (c *conn) hello(s state) string {
	h := map[string]any{"messageType": "hello", "use_webpush": true}
	if s.UAID != "" {
		h["uaid"], h["channelIDs"] = s.UAID, []string{s.Channel}
	}
	c.send(h)
	m := c.next()
	if m.MessageType != "hello" || m.Status != 200 {
		fail("hello", fmt.Errorf("status %d", m.Status))
	}
	return m.UAID
}

func main() {
	if len(os.Args) < 3 {
		fail("usage", fmt.Errorf("autopush setup|drain|drop <state.json> …"))
	}
	stateFile := os.Args[2]
	switch os.Args[1] {
	case "setup":
		c := dial()
		s := state{UAID: c.hello(state{}), Channel: uuid.NewString()}
		c.send(map[string]any{"messageType": "register", "channelID": s.Channel, "key": igVAPID})
		reg := c.next()
		if reg.Status != 200 || reg.PushEndpoint == "" {
			fail("register", fmt.Errorf("status %d", reg.Status))
		}
		s.Endpoint = reg.PushEndpoint
		save(stateFile, s)
		c.ws.Close(websocket.StatusNormalClosure, "")
		say("channel made; endpoint host " + strings.SplitN(strings.TrimPrefix(s.Endpoint, "https://"), "/", 2)[0])
	case "drain":
		if len(os.Args) < 6 {
			fail("usage", fmt.Errorf("autopush drain <state.json> <keys.json> <dir> <seconds> [noack]"))
		}
		s := load(stateFile)
		var keys pushcrypto.PushKeys
		b, err := os.ReadFile(os.Args[3])
		if err != nil || json.Unmarshal(b, &keys) != nil {
			fail("keys", fmt.Errorf("can't read %s", os.Args[3]))
		}
		dir := os.Args[4]
		seconds, _ := strconv.Atoi(os.Args[5])
		ack := !slices.Contains(os.Args[6:], "noack")
		os.MkdirAll(dir, 0o700)
		c := dial()
		if uaid := c.hello(s); uaid != s.UAID {
			say("Mozilla answered with a new UAID: the old one and its channel are gone")
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), time.Duration(seconds)*time.Second)
		defer cancel()
		n := 0
		for {
			m, ok := c.read(ctx)
			if !ok {
				break
			}
			if m.MessageType != "notification" {
				say("message: " + m.MessageType)
				continue
			}
			n++
			write(filepath.Join(dir, fmt.Sprintf("push-%s-%d-raw.json", time.Now().UTC().Format("150405"), n)), m)
			say(fmt.Sprintf("push %d: %s", n, summary(ctx, &keys, m, dir, n)))
			if ack {
				c.send(map[string]any{"messageType": "ack", "updates": []map[string]any{{"channelID": m.ChannelID, "version": m.Version, "code": 100}}})
			}
		}
		c.ws.Close(websocket.StatusNormalClosure, "")
		say(fmt.Sprintf("%d pushes in %d s (acked: %v)", n, seconds, ack))
	case "drop":
		s := load(stateFile)
		c := dial()
		c.hello(s)
		c.send(map[string]any{"messageType": "unregister", "channelID": s.Channel})
		m := c.next()
		c.ws.Close(websocket.StatusNormalClosure, "")
		say(fmt.Sprintf("channel dropped (%s %d)", m.MessageType, m.Status))
	default:
		fail("usage", fmt.Errorf("unknown command %q", os.Args[1]))
	}
}

// summary decrypts a push, writes it beside the raw one, and describes it without its text or names: type, how old
// it was when it came, the params' keys.
func summary(ctx context.Context, keys *pushcrypto.PushKeys, m msg, dir string, n int) string {
	data, _ := base64.RawURLEncoding.DecodeString(strings.TrimRight(m.Data, "="))
	wpd, _ := json.Marshal(pushcrypto.WebPushData{Data: data, ContentEncoding: m.Headers["encoding"], CryptoKey: m.Headers["crypto_key"], Encryption: m.Headers["encryption"]})
	res, err := keys.Decrypt(ctx, wpd)
	if err != nil {
		return "can't decrypt: " + err.Error()
	}
	write(filepath.Join(dir, fmt.Sprintf("push-%s-%d.json", time.Now().UTC().Format("150405"), n)), res)
	params := make([]string, 0, len(res.Params))
	for k := range res.Params {
		params = append(params, k)
	}
	slices.Sort(params)
	age := time.Since(res.Time.Time).Round(time.Second)
	return fmt.Sprintf("type %s, %s old, %d bytes of text, params %s", res.Type, age, len(res.Message), strings.Join(params, " "))
}

func save(file string, s state) {
	b, _ := json.MarshalIndent(s, "", "  ")
	if err := os.WriteFile(file, b, 0o600); err != nil {
		fail("save", err)
	}
}

func load(file string) state {
	var s state
	b, err := os.ReadFile(file)
	if err != nil || json.Unmarshal(b, &s) != nil || s.UAID == "" {
		fail("state", fmt.Errorf("can't read %s", file))
	}
	return s
}

func write(file string, v any) {
	b, _ := json.MarshalIndent(v, "", "  ")
	os.WriteFile(file, b, 0o600)
}

func say(s string) { fmt.Println(time.Now().UTC().Format("15:04:05"), s) }

func fail(what string, err error) {
	say(what + " failed: " + err.Error())
	os.Exit(1)
}
