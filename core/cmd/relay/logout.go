package main

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"sync"

	"github.com/rs/zerolog"

	"go.mau.fi/mautrix-meta/pkg/instameow"
	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"go.mau.fi/mautrix-meta/pkg/messagix/cookies"
	"go.mau.fi/mautrix-meta/pkg/messagix/httpclient"
	"go.mau.fi/mautrix-meta/pkg/messagix/types"

	"github.com/luisten/ferry-messenger/core/engine"
)

// Ending a session at Instagram (R10), as relaygate's `remove` did at the end of step 1, where it ended both dummies'
// sessions. The library has no logout (upstream's bridge leaves it a TODO), so this sends instagram.com's own, as the
// website's Log out does. ponytail: copied from cmd/relaygate, which stays as step 1's record; one copy once it goes.

// The web logout isn't documented: the website's current path first, then its older one.
var logoutPaths = []string{"/api/v1/web/accounts/logout/ajax/", "/accounts/logout/ajax/"}

// logOutAtInstagram sends the logout for this session and returns "ended", "still open" or "unknown" with the path
// that ended it, and the requests it made (C6). One index load first gives the request the website's headers (the
// CSRF token among them).
func logOutAtInstagram(raw map[string]string) (result, via string, counts map[string]int) {
	ctx := context.Background()
	cli, c, n := client(raw)
	defer func() { counts = n.take() }()
	if _, _, err := cli.LoadIndex(ctx); err != nil {
		if errors.Is(err, httpclient.ErrTokenInvalidated) {
			return "ended", "already", nil
		}
		state, reason := engine.Classify(err)
		return "unknown (" + state + " " + reason + ")", "", nil
	}
	post := func(path string) {
		h := cli.GetHTTP()
		headers := h.BuildHeaders(true, false)
		headers.Set("x-requested-with", "XMLHttpRequest")
		headers.Set("referer", "https://www.instagram.com/")
		form := url.Values{"one_tap_app_login": {"0"}, "user_id": {c.Get(cookies.IGCookieDSUserID)}}
		_, _, _ = h.MakeRequest(ctx, "https://www.instagram.com"+path, http.MethodPost, headers, []byte(form.Encode()), types.FORM)
	}
	// The proof: a fresh client on the original cookies, as a copy of them would be used. The first client's own jar
	// may have dropped them on the logout's answer, which proves nothing about Instagram's side.
	alive := func() (bool, error) {
		fresh, _, m := client(raw)
		_, _, err := fresh.LoadIndex(ctx)
		n.add(m.take())
		if errors.Is(err, httpclient.ErrTokenInvalidated) {
			return false, nil
		}
		return err == nil, err
	}
	result, via = endSession(post, alive)
	return result, via, nil
}

// endSession tries each logout until the session itself says it's over: Instagram refusing it as logged out is the
// only answer that counts, whatever the logout request answered.
func endSession(post func(path string), alive func() (bool, error)) (result, via string) {
	result = "still open"
	for _, path := range logoutPaths {
		post(path)
		switch ok, err := alive(); {
		case !ok && err == nil:
			return "ended", path
		case err != nil:
			result = "unknown"
		}
	}
	return result, ""
}

// A client on these cookies with nothing logged (the library's logs can carry what Instagram sent), counting every
// request it makes (C6).
func client(raw map[string]string) (*instameow.Client, *cookies.Cookies, *counter) {
	c := &cookies.Cookies{Platform: types.Instagram}
	values := map[cookies.MetaCookieName]string{}
	for k, v := range raw {
		values[cookies.MetaCookieName(k)] = v
	}
	c.UpdateValues(values)
	noop := func(context.Context, slidetypes.ClientEvent) error { return nil }
	cli := instameow.NewClient(instameow.ClientParams{Cookies: c, Log: zerolog.Nop(), DisableTyping: true, EventHandler: noop})
	h := cli.GetHTTP()
	count := &counter{next: h.HTTP.Transport, n: map[string]int{}}
	h.HTTP.Transport = count
	return cli, c, count
}

// C6: every request to Instagram, by GraphQL operation name, else method and path.
type counter struct {
	next http.RoundTripper
	mu   sync.Mutex
	n    map[string]int
}

func (c *counter) RoundTrip(r *http.Request) (*http.Response, error) {
	name := r.Header.Get("x-fb-friendly-name")
	if name == "" {
		name = r.Method + " " + r.URL.Host + r.URL.Path
	}
	c.add(map[string]int{name: 1})
	return c.next.RoundTrip(r)
}

func (c *counter) add(m map[string]int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for k, v := range m {
		c.n[k] += v
	}
}

func (c *counter) take() map[string]int {
	c.mu.Lock()
	defer c.mu.Unlock()
	m := c.n
	c.n = map[string]int{}
	return m
}
