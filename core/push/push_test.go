package push

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"

	"go.mau.fi/mautrix-meta/pkg/messagix/pushcrypto"
)

// A fake Mozilla on step 1's captures (testdata/push_*_kivo.json, scrubbed): what Setup and Drain do with channels,
// held pushes, acks and a phone Mozilla forgot.

const tamo, kivo = "17841400000000301", "17841400000000302"

// fake is Mozilla as step 1 saw it: it holds pushes per phone until they're acked and sends them after each hello.
type fake struct {
	mu           sync.Mutex
	uaid         string
	channels     map[string]bool
	held         []msg
	unregistered []string
}

func start(t *testing.T) *fake {
	f := &fake{channels: map[string]bool{}}
	srv := httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(srv.Close)
	old := Server
	Server = "ws://" + strings.TrimPrefix(srv.URL, "http://")
	t.Cleanup(func() { Server = old })
	return f
}

func (f *fake) serve(w http.ResponseWriter, r *http.Request) {
	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{"push-notification"}})
	if err != nil {
		return
	}
	defer ws.CloseNow()
	ctx := r.Context()
	send := func(v any) { b, _ := json.Marshal(v); ws.Write(ctx, websocket.MessageText, b) }
	for {
		_, b, err := ws.Read(ctx)
		if err != nil {
			return
		}
		var m struct {
			MessageType, UAID, ChannelID string
			Updates                      []msg
		}
		json.Unmarshal(b, &m)
		f.mu.Lock()
		switch m.MessageType {
		case "hello":
			if f.uaid == "" || m.UAID != f.uaid {
				f.uaid, f.channels, f.held = uuid.NewString(), map[string]bool{}, nil
			}
			send(msg{MessageType: "hello", UAID: f.uaid, Status: 200})
			for _, h := range f.held {
				send(h)
			}
		case "register":
			f.channels[m.ChannelID] = true
			send(msg{MessageType: "register", ChannelID: m.ChannelID, Status: 200, PushEndpoint: "https://push.example/wpush/" + m.ChannelID})
		case "unregister":
			delete(f.channels, m.ChannelID)
			f.unregistered = append(f.unregistered, m.ChannelID)
			send(msg{MessageType: "unregister", ChannelID: m.ChannelID, Status: 200})
		case "ack":
			for _, u := range m.Updates {
				f.held = slices.DeleteFunc(f.held, func(h msg) bool { return h.Version == u.Version })
			}
		}
		f.mu.Unlock()
	}
}

// hold is a push Instagram sent to the channel: the fixture's payload, encrypted to its keys (aesgcm, as Instagram does).
func (f *fake) hold(t *testing.T, ch *Channel, payload []byte) {
	f.mu.Lock()
	defer f.mu.Unlock()
	m := encrypt(t, ch.Keys, payload)
	m.ChannelID, m.Version = ch.ID, uuid.NewString()
	f.held = append(f.held, m)
}

func (f *fake) waiting() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.held)
}

// encrypt is pushcrypto.Decrypt's inverse (legacy `aesgcm`, draft-ietf-webpush-encryption-04).
func encrypt(t *testing.T, keys pushcrypto.PushKeys, payload []byte) msg {
	t.Helper()
	server, _ := ecdh.P256().GenerateKey(rand.Reader)
	phone, err := ecdh.P256().NewPublicKey(keys.P256DH)
	if err != nil {
		t.Fatal(err)
	}
	shared, _ := server.ECDH(phone)
	salt := make([]byte, 16)
	rand.Read(salt)
	mac := func(key []byte, parts ...[]byte) []byte {
		h := hmac.New(sha256.New, key)
		for _, p := range parts {
			h.Write(p)
		}
		return h.Sum(nil)
	}
	info := func(label string) []byte {
		var b bytes.Buffer
		b.WriteString(label + "\x00P-256\x00\x00\x41")
		b.Write(keys.P256DH)
		b.WriteString("\x00\x41")
		b.Write(server.PublicKey().Bytes())
		return b.Bytes()
	}
	prk := mac(salt, mac(mac(keys.Auth, shared), []byte("Content-Encoding: auth\x00\x01")))
	block, _ := aes.NewCipher(mac(prk, info("Content-Encoding: aesgcm"), []byte{1})[:16])
	gcm, _ := cipher.NewGCM(block)
	sealed := gcm.Seal(nil, mac(prk, info("Content-Encoding: nonce"), []byte{1})[:12], append([]byte{0, 0}, payload...), nil)
	b64 := base64.RawURLEncoding.EncodeToString
	return msg{MessageType: "notification", Data: b64(sealed),
		Headers: map[string]string{"encoding": "aesgcm", "crypto_key": "dh=" + b64(server.PublicKey().Bytes()), "encryption": "salt=" + b64(salt)}}
}

func capture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "testdata", "push_"+name+"_kivo.json"))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// ts is a capture's time (ms), as Read takes it from `params.ts`.
func ts(t *testing.T, name string) int64 {
	var p struct {
		Params struct{ TS string } `json:"params"`
	}
	json.Unmarshal(capture(t, name), &p)
	ms, _ := strconv.ParseInt(p.Params.TS, 10, 64)
	return ms
}

var ctx = context.Background()

func TestSetupMakesAndDropsChannels(t *testing.T) {
	f := start(t)
	s, err := Setup(ctx, State{}, []string{tamo, kivo})
	if err != nil || s.UAID == "" || len(s.Accounts) != 2 {
		t.Fatalf("%+v (%v)", s, err)
	}
	ch := s.Accounts[tamo]
	if ch.Endpoint != "https://push.example/wpush/"+ch.ID || len(ch.Keys.P256DH) != 65 || len(ch.Keys.Auth) != 16 || len(ch.Keys.Private) != 32 {
		t.Errorf("tamo's channel %+v", ch)
	}
	// The state goes to the Keychain and back as JSON.
	b, _ := json.Marshal(s)
	var back State
	if json.Unmarshal(b, &back) != nil || !bytes.Equal(back.Accounts[tamo].Keys.Private, ch.Keys.Private) {
		t.Error("the keys don't survive the Keychain")
	}
	again, err := Setup(ctx, back, []string{tamo, kivo})
	if err != nil || again.UAID != s.UAID || again.Accounts[tamo].ID != ch.ID || again.Accounts[kivo].ID != s.Accounts[kivo].ID {
		t.Errorf("a second setup made new channels: %+v (%v)", again, err)
	}
	dropped := again.Accounts[kivo].ID
	one, err := Setup(ctx, again, []string{tamo})
	if err != nil || len(one.Accounts) != 1 || one.Accounts[tamo] == nil || !slices.Equal(f.unregistered, []string{dropped}) {
		t.Errorf("Remove Account: %+v, unregistered %v (%v)", one, f.unregistered, err)
	}
}

// Everything held comes in one drain and is acked; only messages newer than the last open notify; what can't be read
// is acked and left out.
func TestDrainReadsWhatWasHeld(t *testing.T) {
	f := start(t)
	s, err := Setup(ctx, State{}, []string{tamo, kivo})
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"text", "photo", "voice", "video"} {
		f.hold(t, s.Accounts[tamo], capture(t, name))
	}
	like := bytes.Replace(capture(t, "text"), []byte(`"type": "direct_v2_text"`), []byte(`"type": "like"`), 1)
	f.hold(t, s.Accounts[kivo], like)
	f.hold(t, &Channel{ID: "unknown", Keys: s.Accounts[tamo].Keys}, capture(t, "text"))
	garbled := encrypt(t, s.Accounts[tamo].Keys, capture(t, "text"))
	garbled.ChannelID, garbled.Version, garbled.Data = s.Accounts[tamo].ID, "garbled", "AAAA"
	f.mu.Lock()
	f.held = append(f.held, garbled)
	f.mu.Unlock()

	since := ts(t, "photo") - 1 // the app was last open after the text, before the photo
	s, pushes, err := Drain(ctx, s, since, 200*time.Millisecond, 3*time.Second)
	if err != nil || len(pushes) != 5 {
		t.Fatalf("%d pushes (%v): %+v", len(pushes), err, pushes)
	}
	want := Push{Account: tamo, Kind: "direct_v2_text", Sender: "kivostudio", Text: "Push test 2",
		Thread: "340282366841710300000000000000000000301", User: "4200000302", Message: "mid.$push-text-0001", Time: ts(t, "text")}
	if pushes[0] != want {
		t.Errorf("the text: %+v", pushes[0])
	}
	var notify []string
	for _, p := range pushes {
		if p.Notify {
			notify = append(notify, p.Text)
		}
	}
	if !slices.Equal(notify, []string{"Sent a photo", "Sent a voice message", "Sent a video"}) {
		t.Errorf("notifies %q", notify)
	}
	if pushes[4].Account != kivo || pushes[4].Kind != "like" || pushes[4].Notify {
		t.Errorf("a like: %+v", pushes[4])
	}
	if n := f.waiting(); n != 0 {
		t.Errorf("%d pushes not acked", n)
	}
	if _, again, err := Drain(ctx, s, since, 200*time.Millisecond, 3*time.Second); err != nil || len(again) != 0 {
		t.Errorf("a second drain: %+v (%v)", again, err)
	}
}

// A phone Mozilla no longer knows comes back with a new UAID and no channels; the next setup makes new ones, whose
// new endpoints then get registered with Instagram again (rules.go's PushRegister).
func TestAForgottenPhoneStartsOver(t *testing.T) {
	f := start(t)
	s, err := Setup(ctx, State{}, []string{tamo})
	if err != nil {
		t.Fatal(err)
	}
	f.mu.Lock()
	f.uaid = ""
	f.mu.Unlock()
	forgotten, pushes, err := Drain(ctx, s, 0, 200*time.Millisecond, time.Second)
	if err != nil || forgotten.UAID == s.UAID || len(forgotten.Accounts) != 0 || len(pushes) != 0 {
		t.Fatalf("%+v %v (%v)", forgotten, pushes, err)
	}
	fresh, err := Setup(ctx, forgotten, []string{tamo})
	if err != nil || fresh.Accounts[tamo] == nil || fresh.Accounts[tamo].Endpoint == s.Accounts[tamo].Endpoint {
		t.Errorf("%+v (%v)", fresh, err)
	}
}

func TestNothingToDrainConnectsToNothing(t *testing.T) {
	Server = "ws://127.0.0.1:1" // unreachable: a dial would fail
	t.Cleanup(func() { Server = "wss://push.services.mozilla.com/" })
	if s, pushes, err := Drain(ctx, State{}, 0, time.Second, time.Second); err != nil || pushes != nil || s.UAID != "" {
		t.Errorf("%+v %v (%v)", s, pushes, err)
	}
}
