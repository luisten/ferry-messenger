// Package push is the phone's side of Instagram's web push (docs/PLAN-push.md): a Mozilla autopush client that makes
// a channel per account and, each time the app wakes, takes what Mozilla held while the phone wasn't connected, and
// what each push says. Instagram pushes to Mozilla; Mozilla holds each push until it's acked (step 1: one per message,
// 2 h and more). Nothing here talks to Instagram: registering a channel there is `IGRegisterPush`'s, under rules.go.
package push

import (
	"cmp"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"

	"go.mau.fi/mautrix-meta/pkg/messagix/pushcrypto"
)

// Server is Mozilla's push service; tests point it at their own.
var Server = "wss://push.services.mozilla.com/"

// Instagram's web push key (igconnector/push.go): only Instagram can push to a channel registered with it.
const igVAPID = "BIBn3E_rWTci8Xn6P9Xj3btShT85Wdtne0LtwNUyRQ5XjFNkuTq9j4MPAVLvAFhXrUU1A9UxyxBA7YIOjqDIDHI"

// State is the phone's push identity: Mozilla's ID for it and a channel per account. It holds private keys, so it
// leaves the engine only for the app to write straight to the Keychain (as the cookies, decision C3), never logged.
type State struct {
	UAID     string              `json:"uaid,omitempty"`
	Accounts map[string]*Channel `json:"accounts,omitempty"`
}

// Channel is one account's: where Instagram pushes, the keys its pushes are encrypted to, and the last registration
// with Instagram (rules.go's PushRegister decides the next).
type Channel struct {
	ID                 string              `json:"id"`
	Endpoint           string              `json:"endpoint"`
	Keys               pushcrypto.PushKeys `json:"keys"`
	RegisteredEndpoint string              `json:"registeredEndpoint,omitempty"`
	RegisteredAt       int64               `json:"registeredAt,omitempty"`
}

// Push is one held push, read: who sent what, in which chat. Only messages notify, and only ones newer than the last
// time the app was open (Instagram pushes while it's connected too, step 1).
type Push struct {
	Account string `json:"account"`
	Kind    string `json:"kind"`            // Instagram's type (messageKinds, or one that isn't a message)
	Sender  string `json:"sender"`          // their handle
	Group   string `json:"group,omitempty"` // a group's name (`aud_gn`; never captured, no group on the dummies)
	Text    string `json:"text"`            // the message, or Instagram's line for media ("Sent a photo")
	Thread  string `json:"thread"`          // the thread's long ID (`t_id`), for `PushRoom`
	User    string `json:"user"`            // the sender's Instagram user ID
	Message string `json:"message"`         // Instagram's message ID: one notification per message
	Time    int64  `json:"time"`            // ms
	Notify  bool   `json:"notify"`
}

// The types step 1 saw for messages. Reactions, likes and Instagram's in-chat camera sent none.
var messageKinds = []string{"direct_v2_text", "direct_v2_media", "direct_v2_voice_message"}

// Setup makes a channel and keys for each listed account that has none and drops the channels of accounts that
// aren't listed, over one connection. A UAID Mozilla no longer knows comes back new with every channel gone: they're
// made again, and their new endpoints get registered again.
func Setup(ctx context.Context, s State, accounts []string) (State, error) {
	c, err := dial(ctx)
	if err != nil {
		return s, err
	}
	defer c.ws.Close(websocket.StatusNormalClosure, "")
	if s, err = c.hello(ctx, s); err != nil {
		return s, err
	}
	for id, ch := range s.Accounts {
		if slices.Contains(accounts, id) {
			continue
		}
		if err := c.send(ctx, map[string]any{"messageType": "unregister", "channelID": ch.ID}); err != nil {
			return s, err
		}
		if _, err := c.await(ctx, "unregister"); err != nil {
			return s, err
		}
		delete(s.Accounts, id)
	}
	for _, id := range accounts {
		if s.Accounts[id] != nil {
			continue
		}
		ch, err := c.register(ctx)
		if err != nil {
			return s, err
		}
		if s.Accounts == nil {
			s.Accounts = map[string]*Channel{}
		}
		s.Accounts[id] = ch
	}
	return s, nil
}

// Drain takes what Mozilla held (until `quiet` passes with nothing more, `limit` at most), acks it and reads it with
// its account's keys. Mozilla only. A push that can't be read is acked and left out.
// ponytail: acked before the app posts it, so a wake killed in between loses those notifications (never the
// messages); an IGPushAck after posting if that's ever seen.
func Drain(ctx context.Context, s State, since int64, quiet, limit time.Duration) (State, []Push, error) {
	if s.UAID == "" || len(s.Accounts) == 0 {
		return s, nil, nil
	}
	c, err := dial(ctx)
	if err != nil {
		return s, nil, err
	}
	defer c.ws.Close(websocket.StatusNormalClosure, "")
	if s, err = c.hello(ctx, s); err != nil || len(s.Accounts) == 0 {
		return s, nil, err
	}
	byChannel := map[string]string{}
	for id, ch := range s.Accounts {
		byChannel[ch.ID] = id
	}
	end := time.Now().Add(limit)
	var out []Push
	for {
		wait := min(quiet, time.Until(end))
		if wait <= 0 {
			break
		}
		rctx, cancel := context.WithTimeout(ctx, wait)
		m, err := c.next(rctx)
		cancel()
		if err != nil {
			if ctx.Err() == nil && rctx.Err() != nil {
				break // quiet: everything held has come
			}
			return s, out, err
		}
		if m.MessageType != "notification" {
			continue
		}
		if err := c.send(ctx, map[string]any{"messageType": "ack",
			"updates": []map[string]any{{"channelID": m.ChannelID, "version": m.Version, "code": 100}}}); err != nil {
			return s, out, err
		}
		account := byChannel[m.ChannelID]
		if account == "" {
			continue
		}
		if p, err := decrypt(ctx, &s.Accounts[account].Keys, m); err == nil {
			out = append(out, Read(p, account, since))
		}
	}
	return s, out, nil
}

// Read is what a decrypted push says.
func Read(d *pushcrypto.DecryptedPushData, account string, since int64) Push {
	p := d.Params
	ms, _ := strconv.ParseInt(p["ts"], 10, 64)
	if ms == 0 {
		ms = d.Time.UnixMilli()
	}
	out := Push{Account: account, Kind: d.Type, Sender: cmp.Or(p["it"], d.ThreadName), Group: p["aud_gn"],
		Text: cmp.Or(d.Message, p["im"]), Thread: p["t_id"], User: p["u"], Message: cmp.Or(p["mid"], d.MessageID), Time: ms}
	out.Notify = slices.Contains(messageKinds, out.Kind) && ms > since
	return out
}

func decrypt(ctx context.Context, keys *pushcrypto.PushKeys, m msg) (*pushcrypto.DecryptedPushData, error) {
	data, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(m.Data, "="))
	if err != nil || len(data) == 0 {
		return nil, errors.New("push without data")
	}
	raw, _ := json.Marshal(pushcrypto.WebPushData{Data: data, ContentEncoding: m.Headers["encoding"],
		CryptoKey: m.Headers["crypto_key"], Encryption: m.Headers["encryption"]})
	return keys.Decrypt(ctx, raw)
}

// The autopush protocol (as Firefox speaks it): hello, register, unregister, notification, ack.
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

type conn struct{ ws *websocket.Conn }

func dial(ctx context.Context) (*conn, error) {
	ws, _, err := websocket.Dial(ctx, Server, &websocket.DialOptions{Subprotocols: []string{"push-notification"}})
	if err != nil {
		return nil, err
	}
	ws.SetReadLimit(1 << 20)
	return &conn{ws}, nil
}

func (c *conn) send(ctx context.Context, v any) error {
	b, _ := json.Marshal(v)
	return c.ws.Write(ctx, websocket.MessageText, b)
}

func (c *conn) next(ctx context.Context) (m msg, err error) {
	_, b, err := c.ws.Read(ctx)
	if err == nil {
		err = json.Unmarshal(b, &m)
	}
	return m, err
}

// await is the next answer of that type with status 200. Pushes Mozilla sends meanwhile aren't acked, so it sends
// them again at the next drain.
func (c *conn) await(ctx context.Context, kind string) (msg, error) {
	for {
		m, err := c.next(ctx)
		if err != nil {
			return m, err
		}
		if m.MessageType != kind {
			continue
		}
		if m.Status != 200 {
			return m, fmt.Errorf("push service: %s answered %d", kind, m.Status)
		}
		return m, nil
	}
}

// hello names the phone (its UAID and channels). A different UAID back means Mozilla forgot the old one: its
// channels are gone too.
func (c *conn) hello(ctx context.Context, s State) (State, error) {
	h := map[string]any{"messageType": "hello", "use_webpush": true}
	if s.UAID != "" {
		ids := make([]string, 0, len(s.Accounts))
		for _, ch := range s.Accounts {
			ids = append(ids, ch.ID)
		}
		h["uaid"], h["channelIDs"] = s.UAID, ids
	}
	if err := c.send(ctx, h); err != nil {
		return s, err
	}
	m, err := c.await(ctx, "hello")
	if err != nil {
		return s, err
	}
	if m.UAID != s.UAID {
		s = State{UAID: m.UAID}
	}
	return s, nil
}

// register makes a channel with Instagram's key, and the keys its pushes get encrypted to.
func (c *conn) register(ctx context.Context) (*Channel, error) {
	pk, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	auth := make([]byte, 16)
	rand.Read(auth)
	ch := &Channel{ID: uuid.NewString(), Keys: pushcrypto.PushKeys{P256DH: pk.PublicKey().Bytes(), Auth: auth, Private: pk.Bytes()}}
	if err := c.send(ctx, map[string]any{"messageType": "register", "channelID": ch.ID, "key": igVAPID}); err != nil {
		return nil, err
	}
	m, err := c.await(ctx, "register")
	if err != nil {
		return nil, err
	}
	if m.PushEndpoint == "" {
		return nil, errors.New("push service: no endpoint for the new channel")
	}
	ch.Endpoint = m.PushEndpoint
	return ch, nil
}
