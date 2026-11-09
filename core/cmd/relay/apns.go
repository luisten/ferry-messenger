package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
	"time"
	"unicode/utf8"
)

// apns sends alerts to Apple's push service over HTTP/2 with a provider token (ES256 JWT) from the operator's key.
type apns struct {
	key                 *ecdsa.PrivateKey
	keyID, team, topic  string
	client              *http.Client
	production, sandbox string // hosts

	mu   sync.Mutex
	jwt  string
	made time.Time
}

// How long a failed push waits before its one retry (Apple's 429 and 5xx).
var retryWait = time.Second

func newAPNs(keyPath, keyID, team, topic string) (*apns, error) {
	b, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(b)
	if block == nil {
		return nil, errors.New("the APNs key isn't a .p8 (PEM) file")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := k.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("the APNs key isn't an ES256 key")
	}
	if keyID == "" || team == "" || topic == "" {
		return nil, errors.New("APNs needs the key ID, team ID and bundle ID too")
	}
	return &apns{
		key: key, keyID: keyID, team: team, topic: topic,
		client: &http.Client{Timeout: 15 * time.Second, Transport: &http.Transport{
			ForceAttemptHTTP2: true, TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12},
		}},
		production: "https://api.push.apple.com", sandbox: "https://api.sandbox.push.apple.com",
	}, nil
}

// token is the provider token, made again after 50 minutes (Apple wants one between 20 and 60 minutes old) or when
// Apple says it expired.
func (a *apns) token(renew bool) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if !renew && a.jwt != "" && time.Since(a.made) < 50*time.Minute {
		return a.jwt, nil
	}
	enc := base64.RawURLEncoding.EncodeToString
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": a.keyID})
	now := time.Now()
	claims, _ := json.Marshal(map[string]any{"iss": a.team, "iat": now.Unix()})
	input := enc(header) + "." + enc(claims)
	digest := sha256.Sum256([]byte(input))
	r, s, err := ecdsa.Sign(rand.Reader, a.key, digest[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	a.jwt, a.made = input+"."+enc(sig), now
	return a.jwt, nil
}

// send pushes one alert and returns Apple's status and reason ("" when it took it).
func (a *apns) send(device string, sandbox bool, payload []byte) (status int, reason string, err error) {
	host := a.production
	if sandbox {
		host = a.sandbox
	}
	renew := false
	for attempt := range 2 {
		if attempt > 0 && !renew {
			time.Sleep(retryWait)
		}
		jwt, err := a.token(renew)
		if err != nil {
			return 0, "", err
		}
		req, _ := http.NewRequest(http.MethodPost, host+"/3/device/"+device, bytes.NewReader(payload))
		req.Header.Set("authorization", "bearer "+jwt)
		req.Header.Set("apns-push-type", "alert")
		req.Header.Set("apns-topic", a.topic)
		req.Header.Set("apns-priority", "10")
		req.Header.Set("content-type", "application/json")
		resp, err := a.client.Do(req)
		if err != nil {
			return 0, "", err
		}
		var answer struct {
			Reason string `json:"reason"`
		}
		_ = json.NewDecoder(io.LimitReader(resp.Body, 4<<10)).Decode(&answer)
		resp.Body.Close()
		status, reason = resp.StatusCode, answer.Reason
		renew = status == http.StatusForbidden && reason == "ExpiredProviderToken"
		if !renew && status != http.StatusTooManyRequests && status < 500 {
			break
		}
	}
	return status, reason, nil
}

// gone says the device token is no longer any good: the app was removed, or the token isn't for this environment.
func gone(status int, reason string) bool {
	return status == http.StatusGone || reason == "Unregistered" || reason == "BadDeviceToken"
}

// alert is an alert's payload (R5): one stack per chat (`thread-id`), and the chat's room ID for the tap. Text is cut
// to stay well within Apple's 4 KB.
func alert(title, subtitle, body, room, account string) []byte {
	a := map[string]any{"title": clip(title, 200), "body": clip(body, 1500)}
	if subtitle != "" {
		a["subtitle"] = clip(subtitle, 200)
	}
	aps := map[string]any{"alert": a, "sound": "default"}
	p := map[string]any{"aps": aps, "account": account}
	if room != "" {
		aps["thread-id"], p["room"] = room, room
	}
	b, _ := json.Marshal(p)
	return b
}

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n] + "…"
}

// stoppedAlert says the relay stopped listening for an account (§2 "Problems come as pushes"), and why.
func stoppedAlert(username, account, reason string) []byte {
	b, _ := json.Marshal(map[string]any{"aps": map[string]any{"alert": map[string]any{
		"title": "Notifications stopped", "body": fmt.Sprintf("Notifications for @%s stopped: open Ferry.", username),
	}, "sound": "default"}, "account": account, "stopped": reason})
	return b
}
