package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"go.mau.fi/mautrix-meta/pkg/messagix/httpclient"
)

// The relay on fakes: the engine and the web logout record what they're asked (and never reach Instagram), and APNs is
// an HTTP/2 server that checks the provider token.

type fakes struct {
	t          *testing.T
	mu         sync.Mutex
	calls      []string                  // in order: "login <sessionid>", "session <id>", "stop <id>", "logout <sessionid>"
	pushes     []pushed                  // what the fake APNs got
	answer     func(n int) (int, string) // APNs' answer to its nth request (from 1)
	loginErr   error
	logOutDone chan struct{}
}

type pushed struct {
	path    string
	header  http.Header
	payload map[string]any
}

func (f *fakes) call(s string) {
	f.mu.Lock()
	f.calls = append(f.calls, s)
	f.mu.Unlock()
}

func (f *fakes) called() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.calls)
}

// The fake engine: cookies `{"ds_user_id": <account>, "sessionid": …}` log in as that account, `@user<account>`, and
// the session it keeps has rotated one cookie.
func setup(t *testing.T) (*relay, *httptest.Server, *fakes, *bytes.Buffer) {
	f := &fakes{t: t, answer: func(int) (int, string) { return 200, "" }, logOutDone: make(chan struct{}, 10)}
	logs := &bytes.Buffer{}
	logMu.Lock()
	logTo, retryWait = logs, 0
	logMu.Unlock()
	login = func(cookies string) (map[string]any, error) {
		var c map[string]string
		_ = json.Unmarshal([]byte(cookies), &c)
		f.call("login " + c["sessionid"])
		if f.loginErr != nil {
			return nil, f.loginErr
		}
		return map[string]any{"account": c["ds_user_id"], "viewer": map[string]any{"username": "user" + c["ds_user_id"]}}, nil
	}
	resume = func(id, cookies string) (map[string]any, error) { f.call("resume " + id); return login(cookies) }
	session = func(id string) ([]byte, error) {
		f.call("session " + id)
		return json.Marshal(map[string]string{"ds_user_id": id, "sessionid": "s-" + id, "rur": "rotated"})
	}
	stopAccount = func(id string) { f.call("stop " + id) }
	logOut = func(c map[string]string) (string, string, map[string]int) {
		f.call("logout " + c["sessionid"] + " " + c["rur"])
		f.logOutDone <- struct{}{}
		return "ended", logoutPaths[0], map[string]int{"POST www.instagram.com/x": 1}
	}

	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	var n int
	fake := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.ProtoMajor != 2 {
			t.Errorf("APNs over HTTP/%d", req.ProtoMajor)
		}
		if !validJWT(req.Header.Get("authorization"), &key.PublicKey) {
			t.Error("a bad provider token")
		}
		var p map[string]any
		_ = json.NewDecoder(req.Body).Decode(&p)
		f.mu.Lock()
		n++
		code, reason := f.answer(n)
		f.pushes = append(f.pushes, pushed{req.URL.Path, req.Header.Clone(), p})
		f.mu.Unlock()
		w.WriteHeader(code)
		if reason != "" {
			fmt.Fprintf(w, `{"reason":%q}`, reason)
		}
	}))
	fake.EnableHTTP2 = true
	fake.StartTLS()
	t.Cleanup(fake.Close)
	push := &apns{key: key, keyID: "KEY1234567", team: "TEAM123456", topic: "com.example.ferry-messenger",
		client: fake.Client(), production: fake.URL, sandbox: fake.URL + "/sandbox"}

	r := newRelay(&store{path: t.TempDir() + "/relay.json"}, push)
	api := httptest.NewServer(r.routes())
	t.Cleanup(api.Close)
	return r, api, f, logs
}

func validJWT(auth string, pub *ecdsa.PublicKey) bool {
	parts := strings.Split(strings.TrimPrefix(auth, "bearer "), ".")
	if len(parts) != 3 {
		return false
	}
	var header, claims map[string]any
	h, _ := base64.RawURLEncoding.DecodeString(parts[0])
	c, _ := base64.RawURLEncoding.DecodeString(parts[1])
	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	if json.Unmarshal(h, &header) != nil || json.Unmarshal(c, &claims) != nil || len(sig) != 64 {
		return false
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	ok := ecdsa.Verify(pub, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:]))
	return ok && header["alg"] == "ES256" && header["kid"] == "KEY1234567" && claims["iss"] == "TEAM123456" && claims["iat"] != nil
}

// do sends a request as a phone (token "" for none) and decodes the answer.
func do(t *testing.T, api *httptest.Server, method, path, token string, body any) (int, map[string]any) {
	t.Helper()
	var r io.Reader
	switch b := body.(type) {
	case nil:
	case []byte:
		r = bytes.NewReader(b)
	default:
		j, _ := json.Marshal(b)
		r = bytes.NewReader(j)
	}
	req, _ := http.NewRequest(method, api.URL+path, r)
	if token != "" {
		req.Header.Set("authorization", "Bearer "+token)
	}
	resp, err := api.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

// paired is a new phone's token, from a fresh invite.
func paired(t *testing.T, r *relay, api *httptest.Server) string {
	t.Helper()
	var b bytes.Buffer
	if err := invite(r.store, &b); err != nil {
		t.Fatal(err)
	}
	code, out := do(t, api, "POST", "/v1/pair", "", map[string]string{"invite": strings.Fields(b.String())[0]})
	if code != 200 {
		t.Fatalf("pair: %d %v", code, out)
	}
	return out["token"].(string)
}

func sessionOf(account, sessionid string) map[string]any {
	return map[string]any{"cookies": map[string]string{"ds_user_id": account, "sessionid": sessionid}}
}

func addAccount(t *testing.T, api *httptest.Server, token, account, sessionid string) {
	t.Helper()
	if code, out := do(t, api, "PUT", "/v1/accounts", token, sessionOf(account, sessionid)); code != 200 || out["account"] != account {
		t.Fatalf("add: %d %v", code, out)
	}
}

const device = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

// MARK: The store

func TestTheStateFileIsPrivateAndTakesTwoWriters(t *testing.T) {
	path := t.TempDir() + "/relay.json"
	serve, operator := &store{path: path}, &store{path: path} // `relay serve` and `relay invite`, each its own
	var wg sync.WaitGroup
	for i := range 40 {
		wg.Go(func() {
			s := serve
			if i%2 == 1 {
				s = operator
			}
			if err := s.update(func(st *state) error { st.Invites[fmt.Sprint(i)] = 1; return nil }); err != nil {
				t.Error(err)
			}
		})
	}
	wg.Wait()
	st, err := serve.read()
	if err != nil || len(st.Invites) != 40 {
		t.Fatalf("%d invites (%v): a write was lost", len(st.Invites), err)
	}
	for _, p := range []string{path, path + ".lock"} {
		if info, err := os.Stat(p); err != nil || info.Mode().Perm() != 0o600 {
			t.Errorf("%s: %v %v", p, info.Mode(), err)
		}
	}
	// A change that fails writes nothing.
	_ = serve.update(func(st *state) error { st.Invites = nil; return errors.New("no") })
	if st, _ := serve.read(); len(st.Invites) != 40 {
		t.Error("a failed change was written")
	}
}

// MARK: The API, pairing and tokens

func TestPairingTakesAOneTimeInvite(t *testing.T) {
	r, api, _, logs := setup(t)
	var b bytes.Buffer
	_ = invite(r.store, &b)
	code := strings.Fields(b.String())[0]
	if len(code) != 11 || code[5] != '-' {
		t.Fatalf("invite %q", code)
	}
	typed := strings.ToLower(strings.ReplaceAll(code, "-", " "))
	status, out := do(t, api, "POST", "/v1/pair", "", map[string]string{"invite": typed})
	token, _ := out["token"].(string)
	if status != 200 || len(token) < 40 {
		t.Fatalf("pair: %d %v", status, out)
	}
	if status, _ := do(t, api, "POST", "/v1/pair", "", map[string]string{"invite": code}); status != 401 {
		t.Errorf("the invite worked twice: %d", status)
	}
	_ = r.store.update(func(st *state) error {
		st.Invites[hash("EXPIREDXYZ")] = time.Now().Add(-time.Second).UnixMilli()
		return nil
	})
	if status, _ := do(t, api, "POST", "/v1/pair", "", map[string]string{"invite": "EXPIREDXYZ"}); status != 401 {
		t.Errorf("an expired invite: %d", status)
	}
	if st, _ := r.store.read(); len(st.Invites) != 0 || st.Phones[hash(token)] == nil || strings.Contains(fmt.Sprint(st), token) {
		t.Error("the state keeps an invite or the token itself, or lacks the phone")
	}
	for _, tok := range []string{"", "nope", token + "x"} {
		if status, _ := do(t, api, "GET", "/v1/status", tok, nil); status != 401 {
			t.Errorf("token %q: %d", tok, status)
		}
	}
	if status, out := do(t, api, "GET", "/v1/status", token, nil); status != 200 || len(out["accounts"].([]any)) != 0 {
		t.Errorf("status: %d %v", status, out)
	}
	if strings.Contains(logs.String(), token) || strings.Contains(logs.String(), code[:5]) {
		t.Error("the log holds a token or an invite")
	}
}

func TestFailedAttemptsAreLimitedPerIP(t *testing.T) {
	r, api, _, _ := setup(t)
	for range maxFailures {
		do(t, api, "GET", "/v1/status", "wrong", nil)
	}
	var b bytes.Buffer
	_ = invite(r.store, &b)
	if status, _ := do(t, api, "POST", "/v1/pair", "", map[string]string{"invite": strings.Fields(b.String())[0]}); status != 429 {
		t.Errorf("after %d failures: %d", maxFailures, status)
	}
	r.limit.m["127.0.0.1"].until = time.Now().Add(-time.Second) // the window ends
	if status, _ := do(t, api, "POST", "/v1/pair", "", map[string]string{"invite": strings.Fields(b.String())[0]}); status != 200 {
		t.Errorf("after the window: %d", status)
	}
}

func TestRequestsAreSmall(t *testing.T) {
	r, api, _, _ := setup(t)
	token := paired(t, r, api)
	big := []byte(`{"cookies":{"x":"` + strings.Repeat("a", maxBody) + `"}}`)
	if status, _ := do(t, api, "PUT", "/v1/accounts", token, big); status != 413 {
		t.Errorf("a big body: %d", status)
	}
	if status, _ := do(t, api, "PUT", "/v1/apns", token, map[string]any{"token": "not hex at all, and too short"}); status != 400 {
		t.Errorf("a bad APNs token: %d", status)
	}
	if status, _ := do(t, api, "PUT", "/v1/apns", token, map[string]any{"token": device, "sandbox": true}); status != 200 {
		t.Errorf("an APNs token: %d", status)
	}
	if st, _ := r.store.read(); st.Phones[hash(token)].APNs != device || !st.Phones[hash(token)].Sandbox {
		t.Error("the APNs token isn't kept")
	}
}

// Another phone's account answers exactly as one that doesn't exist.
func TestAccountsBelongToTheirPhone(t *testing.T) {
	r, api, f, _ := setup(t)
	mine, theirs := paired(t, r, api), paired(t, r, api)
	addAccount(t, api, mine, "1001", "s1")
	_, unknown := do(t, api, "DELETE", "/v1/accounts/9999", theirs, nil)
	status, other := do(t, api, "DELETE", "/v1/accounts/1001", theirs, nil)
	if status != 404 || fmt.Sprint(other) != fmt.Sprint(unknown) {
		t.Errorf("another phone's account: %d %v, unknown: %v", status, other, unknown)
	}
	if _, out := do(t, api, "GET", "/v1/status", theirs, nil); len(out["accounts"].([]any)) != 0 {
		t.Errorf("another phone sees %v", out)
	}
	_, out := do(t, api, "GET", "/v1/status", mine, nil)
	if a := out["accounts"].([]any); len(a) != 1 || a[0].(map[string]any)["username"] != "user1001" {
		t.Errorf("status %v", out)
	}
	if slices.ContainsFunc(f.called(), func(c string) bool { return strings.HasPrefix(c, "stop") || strings.HasPrefix(c, "logout") }) {
		t.Errorf("another phone ended it: %v", f.called())
	}
}

func TestAddRefusesWhatInstagramRefuses(t *testing.T) {
	r, api, f, _ := setup(t)
	token := paired(t, r, api)
	f.loginErr = fmt.Errorf("index: %w", httpclient.ErrTokenInvalidated)
	if status, out := do(t, api, "PUT", "/v1/accounts", token, sessionOf("1001", "s1")); status != 422 || !strings.Contains(out["error"].(string), "logged_out") {
		t.Errorf("a signed-out session: %d %v", status, out)
	}
	f.loginErr = &net.OpError{Op: "dial", Err: errors.New("down")}
	if status, _ := do(t, api, "PUT", "/v1/accounts", token, sessionOf("1001", "s1")); status != 502 {
		t.Errorf("no network: %d", status)
	}
	if status, _ := do(t, api, "PUT", "/v1/accounts", token, map[string]any{"cookies": map[string]string{}}); status != 400 {
		t.Errorf("no cookies: %d", status)
	}
	if st, _ := r.store.read(); len(st.Accounts) != 0 {
		t.Error("a refused session was kept")
	}
}

// MARK: Ending a session (R10)

func TestDropEndsTheSessionInOrder(t *testing.T) {
	r, api, f, logs := setup(t)
	token := paired(t, r, api)
	do(t, api, "PUT", "/v1/apns", token, map[string]any{"token": device})
	addAccount(t, api, token, "1001", "s1")
	addAccount(t, api, token, "1002", "s2")
	before := len(f.called())
	status, out := do(t, api, "DELETE", "/v1/accounts/1001", token, nil)
	if status != 200 || out["socket"] != "closed" || out["logout"] != "ended" || out["deleted"] != true {
		t.Fatalf("drop: %d %v", status, out)
	}
	// The current (rotated) cookies are the ones logged out, after the socket closed.
	if got := f.called()[before:]; !slices.Equal(got, []string{"session 1001", "stop 1001", "logout s-1001 rotated"}) {
		t.Errorf("order %v", got)
	}
	st, _ := r.store.read()
	if st.Accounts["1001"] != nil || st.Accounts["1002"] == nil || st.Phones[hash(token)].APNs != device {
		t.Error("the state after the first drop")
	}
	do(t, api, "DELETE", "/v1/accounts/1002", token, nil)
	if st, _ := r.store.read(); len(st.Accounts) != 0 || st.Phones[hash(token)].APNs != "" {
		t.Error("the last drop leaves an account or the device token")
	}
	if strings.Contains(logs.String(), "s-1001") || strings.Contains(logs.String(), "rotated") {
		t.Error("the log holds cookies")
	}
}

// Adding an account the relay has moves it to the new session and ends the old one (unless it's the same session).
func TestReAddingEndsTheOldSession(t *testing.T) {
	r, api, f, logs := setup(t)
	token := paired(t, r, api)
	addAccount(t, api, token, "1001", "s1")
	addAccount(t, api, token, "1001", "s-1001") // the session the relay kept (rotated): the same one
	addAccount(t, api, token, "1001", "s2")
	select {
	case <-f.logOutDone:
	case <-time.After(5 * time.Second):
		t.Fatal("the old session wasn't ended")
	}
	for logged := false; !logged; time.Sleep(10 * time.Millisecond) { // its log line, written after
		logMu.Lock()
		logged = strings.Contains(logs.String(), "replaced session ended")
		logMu.Unlock()
	}
	logouts := slices.DeleteFunc(f.called(), func(c string) bool { return !strings.HasPrefix(c, "logout") })
	if !slices.Equal(logouts, []string{"logout s-1001 rotated"}) {
		t.Errorf("logouts %v", logouts)
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

// MARK: Pushes (R5, R6 through the engine's Notify events), against the fake APNs

func notifyEvent(account, room, from, group, body string) []byte {
	b, _ := json.Marshal(map[string]any{"kind": "Notify", "account": account, "room": room, "from": from, "group": group, "body": body, "at": 1})
	return b
}

func TestANewMessageBecomesAnAlert(t *testing.T) {
	r, api, f, logs := setup(t)
	token := paired(t, r, api)
	do(t, api, "PUT", "/v1/apns", token, map[string]any{"token": device, "sandbox": true})
	addAccount(t, api, token, "1001", "s1")
	room := "!ig-1001-17000"
	r.event(notifyEvent("1001", room, "@sample.sam", "", "a secret hello"))
	if len(f.pushes) != 1 {
		t.Fatalf("%d pushes", len(f.pushes))
	}
	p := f.pushes[0]
	aps := p.payload["aps"].(map[string]any)
	a := aps["alert"].(map[string]any)
	if p.path != "/sandbox/3/device/"+device || p.header.Get("apns-push-type") != "alert" ||
		p.header.Get("apns-topic") != "com.example.ferry-messenger" || aps["thread-id"] != room || p.payload["room"] != room ||
		a["title"] != "@sample.sam" || a["body"] != "a secret hello" || a["subtitle"] != nil {
		t.Errorf("push %s %v %v", p.path, p.header, p.payload)
	}
	// A second account on the phone: "To @account"; a group: its name, and who said it.
	addAccount(t, api, token, "1002", "s2")
	r.event(notifyEvent("1002", "!ig-1002-1", "@sample.sam", "Sample group", "hi all"))
	a = f.pushes[1].payload["aps"].(map[string]any)["alert"].(map[string]any)
	if a["title"] != "Sample group" || a["subtitle"] != "To @user1002" || a["body"] != "@sample.sam: hi all" {
		t.Errorf("group alert %v", a)
	}
	if l := logs.String(); strings.Contains(l, "secret") || strings.Contains(l, "sample.sam") || strings.Contains(l, room) || strings.Contains(l, device) {
		t.Errorf("the log holds what was said, who, where or the device: %s", l)
	}
}

func TestApplesAnswers(t *testing.T) {
	r, api, f, _ := setup(t)
	token := paired(t, r, api)
	do(t, api, "PUT", "/v1/apns", token, map[string]any{"token": device})
	addAccount(t, api, token, "1001", "s1")
	send := func(answers ...[2]any) int {
		k := 0
		f.mu.Lock()
		f.pushes, f.answer = nil, func(int) (int, string) {
			k++
			a := answers[min(k, len(answers))-1]
			return a[0].(int), a[1].(string)
		}
		f.mu.Unlock()
		r.event(notifyEvent("1001", "!ig-1001-1", "@sample.sam", "", "hi"))
		return len(f.pushes)
	}
	if n := send([2]any{403, "ExpiredProviderToken"}, [2]any{200, ""}); n != 2 || f.pushes[0].header.Get("authorization") == f.pushes[1].header.Get("authorization") {
		t.Errorf("an expired provider token: %d tries, renewed: %v", n, n == 2)
	}
	if n := send([2]any{503, "ServiceUnavailable"}, [2]any{200, ""}); n != 2 {
		t.Errorf("Apple unavailable: %d tries", n)
	}
	if n := send([2]any{400, "BadTopic"}); n != 1 {
		t.Errorf("a bad request: %d tries", n)
	}
	if st, _ := r.store.read(); st.Phones[hash(token)].APNs != device {
		t.Fatal("the device token went early")
	}
	send([2]any{410, "Unregistered"})
	if st, _ := r.store.read(); st.Phones[hash(token)].APNs != "" {
		t.Error("an unregistered token is kept")
	}
	if n := send([2]any{200, ""}); n != 0 {
		t.Error("pushed without a device token")
	}
}

// A session Instagram ends stops the account with one push, keeps its cookies for the logout, and notifies nothing more.
func TestASignedOutSessionStopsWithOnePush(t *testing.T) {
	r, api, f, _ := setup(t)
	token := paired(t, r, api)
	do(t, api, "PUT", "/v1/apns", token, map[string]any{"token": device})
	addAccount(t, api, token, "1001", "s1")
	signedOut := []byte(`{"kind":"AuthError","account":"1001","code":"BAD_CREDENTIALS","reason":"logged_out"}`)
	r.event(signedOut)
	r.event(signedOut)
	r.event(notifyEvent("1001", "!ig-1001-1", "@sample.sam", "", "hi"))
	if len(f.pushes) != 1 || f.pushes[0].payload["stopped"] != "logged_out" ||
		f.pushes[0].payload["aps"].(map[string]any)["alert"].(map[string]any)["body"] != "Notifications for @user1001 stopped: open Ferry." {
		t.Fatalf("pushes %v", f.pushes)
	}
	if !slices.Contains(f.called(), "stop 1001") {
		t.Error("still listening")
	}
	st, _ := r.store.read()
	if a := st.Accounts["1001"]; a == nil || a.Stopped != "logged_out" || len(a.Cookies) == 0 {
		t.Errorf("the account after: %+v", a)
	}
	if _, out := do(t, api, "GET", "/v1/status", token, nil); out["accounts"].([]any)[0].(map[string]any)["error"] != "logged_out" {
		t.Errorf("status %v", out)
	}
	// The network passing is no reason to stop.
	addAccount(t, api, token, "1002", "s2")
	r.event([]byte(`{"kind":"LoginFailed","account":"1002","code":"TRANSIENT_DISCONNECT","reason":"network"}`))
	if st, _ := r.store.read(); st.Accounts["1002"].Stopped != "" {
		t.Error("a network failure stopped it")
	}
}

// A restart resumes every account that hasn't stopped.
func TestStartResumesAccountsThatHaventStopped(t *testing.T) {
	r, _, f, _ := setup(t)
	_ = r.store.update(func(st *state) error {
		st.Accounts["1001"] = &account{Phone: "p", Cookies: map[string]string{"ds_user_id": "1001"}}
		st.Accounts["1002"] = &account{Phone: "p", Cookies: map[string]string{"ds_user_id": "1002"}, Stopped: "checkpoint"}
		return nil
	})
	if err := r.start(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	if c := f.called(); !slices.Contains(c, "resume 1001") || slices.Contains(c, "resume 1002") {
		t.Errorf("resumed %v", c)
	}
}
