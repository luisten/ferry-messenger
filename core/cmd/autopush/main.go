// Spike helper: a minimal Mozilla autopush client. Registers a channel with Instagram's VAPID key, writes the
// endpoint to a file, waits for one push, decrypts it and exits.
// ponytail: one channel, one push, no reconnect; enough to see whether Instagram delivers to a standard service.
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
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

func main() {
	keysFile, endpointFile := os.Args[1], os.Args[2]
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Minute)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "wss://push.services.mozilla.com/", &websocket.DialOptions{Subprotocols: []string{"push-notification"}})
	if err != nil {
		fail("dial", err)
	}
	conn.SetReadLimit(1 << 20)
	send := func(v any) {
		b, _ := json.Marshal(v)
		if err := conn.Write(ctx, websocket.MessageText, b); err != nil {
			fail("write", err)
		}
	}
	read := func() msg {
		_, b, err := conn.Read(ctx)
		if err != nil {
			fail("read", err)
		}
		var m msg
		json.Unmarshal(b, &m)
		return m
	}

	send(map[string]any{"messageType": "hello", "use_webpush": true})
	hello := read()
	channel := uuid.NewString()
	send(map[string]any{"messageType": "register", "channelID": channel, "key": igVAPID})
	reg := read()
	if reg.Status != 200 || reg.PushEndpoint == "" {
		fail("register", fmt.Errorf("hello status %d, register status %d", hello.Status, reg.Status))
	}
	os.WriteFile(endpointFile, []byte(reg.PushEndpoint), 0o600)
	fmt.Println(time.Now().UTC().Format("15:04:05"), "registered; endpoint host:", strings.SplitN(strings.TrimPrefix(reg.PushEndpoint, "https://"), "/", 2)[0])

	for {
		m := read()
		if m.MessageType != "notification" {
			fmt.Println(time.Now().UTC().Format("15:04:05"), "message:", m.MessageType)
			continue
		}
		send(map[string]any{"messageType": "ack", "updates": []map[string]any{{"channelID": m.ChannelID, "version": m.Version, "code": 100}}})
		fmt.Println(time.Now().UTC().Format("15:04:05"), "PUSH ARRIVED; encoding:", m.Headers["encoding"])
		var keys pushcrypto.PushKeys
		b, _ := os.ReadFile(keysFile)
		json.Unmarshal(b, &keys)
		data, _ := base64.RawURLEncoding.DecodeString(strings.TrimRight(m.Data, "="))
		wpd, _ := json.Marshal(pushcrypto.WebPushData{Data: data, ContentEncoding: m.Headers["encoding"], CryptoKey: m.Headers["crypto_key"], Encryption: m.Headers["encryption"]})
		if res, err := keys.Decrypt(ctx, wpd); err != nil {
			fmt.Println("decrypt error:", err)
		} else {
			out, _ := json.MarshalIndent(res, "", "  ")
			fmt.Println(string(out))
		}
		send(map[string]any{"messageType": "unregister", "channelID": channel})
		time.Sleep(2 * time.Second)
		conn.Close(websocket.StatusNormalClosure, "")
		return
	}
}

func fail(what string, err error) {
	fmt.Println(time.Now().UTC().Format("15:04:05"), what, "failed:", err)
	os.Exit(1)
}
