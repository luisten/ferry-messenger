package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"syscall"
)

// The state file, the relay's only data on disk (PLAN-relay §2), readable by its own user alone: the phones (by their
// token's hash), the accounts with their sessions, the invites (by their code's hash). Every change locks it, reads
// it, changes it and renames a new copy into place, so `relay invite` can add a code while `relay serve` runs.
type state struct {
	Phones   map[string]*phone   `json:"phones"`   // by the SHA-256 of the phone's token
	Accounts map[string]*account `json:"accounts"` // by Instagram account ID
	Invites  map[string]int64    `json:"invites"`  // the SHA-256 of a code → when it expires (ms)
}

type phone struct {
	APNs    string `json:"apns,omitempty"` // its device token
	Sandbox bool   `json:"sandbox,omitempty"`
}

type account struct {
	Phone    string            `json:"phone"` // the owner's token hash
	Username string            `json:"username"`
	Cookies  map[string]string `json:"cookies"`
	// Why the relay stopped listening for it (Instagram ended the session, or wants a checkpoint): it keeps the
	// cookies until the phone drops it, so turning notifications off still tries the logout.
	Stopped string `json:"stopped,omitempty"`
}

type store struct{ path string }

func hash(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

// lock holds the lock file (next to the state, empty) until the returned func is called. A lock on the state file
// itself would be lost to the rename.
func (s *store) lock(how int) (func(), error) {
	f, err := os.OpenFile(s.path+".lock", os.O_CREATE|os.O_RDONLY, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), how); err != nil {
		f.Close()
		return nil, err
	}
	return func() { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN); f.Close() }, nil
}

func (s *store) load() (*state, error) {
	st := &state{}
	b, err := os.ReadFile(s.path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if err == nil {
		if err := json.Unmarshal(b, st); err != nil {
			return nil, err
		}
	}
	if st.Phones == nil {
		st.Phones = map[string]*phone{}
	}
	if st.Accounts == nil {
		st.Accounts = map[string]*account{}
	}
	if st.Invites == nil {
		st.Invites = map[string]int64{}
	}
	return st, nil
}

// read is the state as it is now.
func (s *store) read() (*state, error) {
	unlock, err := s.lock(syscall.LOCK_SH)
	if err != nil {
		return nil, err
	}
	defer unlock()
	return s.load()
}

// update changes the state and writes it, unless `change` fails (its error is returned).
func (s *store) update(change func(st *state) error) error {
	unlock, err := s.lock(syscall.LOCK_EX)
	if err != nil {
		return err
	}
	defer unlock()
	st, err := s.load()
	if err != nil {
		return err
	}
	if err := change(st); err != nil {
		return err
	}
	b, err := json.Marshal(st)
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}
