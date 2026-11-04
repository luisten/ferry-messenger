// The C API the apps call: core/engine, exported as IG<Name> for each engine.<Name> (its docs say what each does),
// JSON in and out. Only the C edges live here: strings in, a JSON result or `{error, code, reason}` out, which the app
// frees with IGFree. jni_android.c wraps these for Android: change it with any signature here.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"runtime"
	"time"
	"unsafe"

	"github.com/luisten/ferry-messenger/core/engine"
)

func jsonOut(v any) *C.char {
	b, err := json.Marshal(v)
	if err != nil {
		return fail(err)
	}
	return C.CString(string(b))
}

func fail(err error) *C.char {
	state, reason := engine.Classify(err)
	b, _ := json.Marshal(map[string]string{"error": err.Error(), "code": state, "reason": reason})
	return C.CString(string(b))
}

// result is an engine call's answer for the app.
func result[T any](v T, err error) *C.char {
	if err != nil {
		return fail(err)
	}
	return jsonOut(v)
}

func str(s *C.char) string { return C.GoString(s) }

//export IGSetCapture
func IGSetCapture(dir *C.char) { engine.SetCapture(str(dir)) }

//export IGLogin
func IGLogin(cookiesJSON *C.char) *C.char { return result(engine.Login(str(cookiesJSON))) }

//export IGResume
func IGResume(acct, cookiesJSON *C.char) *C.char {
	return result(engine.Resume(str(acct), str(cookiesJSON)))
}

//export IGSetDebug
func IGSetDebug(blockSends C.int, requestRoom *C.char) {
	engine.SetDebug(blockSends != 0, str(requestRoom))
}

//export IGNextEvent
func IGNextEvent(timeoutMS C.int) *C.char {
	b := engine.NextEvent(time.Duration(timeoutMS) * time.Millisecond)
	if b == nil {
		return nil
	}
	return C.CString(string(b))
}

//export IGOpenChat
func IGOpenChat(room *C.char) *C.char { return result(engine.OpenChat(str(room))) }

//export IGReadChat
func IGReadChat(room *C.char) *C.char { return result(engine.ReadChat(str(room))) }

//export IGOlder
func IGOlder(room *C.char) *C.char { return result(engine.Older(str(room))) }

//export IGSend
func IGSend(room, text, replyTo, otid *C.char) *C.char {
	return result(engine.Send(str(room), str(text), str(replyTo), str(otid)))
}

//export IGNewOTID
func IGNewOTID() *C.char { return C.CString(engine.NewOTID()) }

//export IGAccept
func IGAccept(room *C.char) *C.char { return result(engine.Accept(str(room))) }

//export IGDeleteThread
func IGDeleteThread(room *C.char) *C.char { return result(engine.DeleteThread(str(room))) }

//export IGSearch
func IGSearch(acct, query *C.char) *C.char { return result(engine.Search(str(acct), str(query))) }

//export IGOpenDM
func IGOpenDM(acct, contactJSON *C.char) *C.char {
	return result(engine.OpenDM(str(acct), str(contactJSON)))
}

//export IGSendMedia
func IGSendMedia(room, path, mime *C.char, voice C.int, replyTo, otid *C.char) *C.char {
	return result(engine.SendMedia(str(room), str(path), str(mime), voice != 0, str(replyTo), str(otid)))
}

//export IGResolveMedia
func IGResolveMedia(room, message *C.char) *C.char {
	return result(engine.ResolveMedia(str(room), str(message)))
}

//export IGReact
func IGReact(room, message, emoji *C.char, remove C.int) *C.char {
	return result(engine.React(str(room), str(message), str(emoji), remove != 0))
}

//export IGEdit
func IGEdit(room, message, text *C.char) *C.char {
	return result(engine.Edit(str(room), str(message), str(text)))
}

//export IGUnsend
func IGUnsend(room, message *C.char) *C.char { return result(engine.Unsend(str(room), str(message))) }

//export IGMarkRead
func IGMarkRead(room *C.char) *C.char { return result(engine.MarkRead(str(room))) }

//export IGTyping
func IGTyping(room *C.char, on C.int) *C.char { return result(engine.Typing(str(room), on != 0)) }

//export IGCounts
func IGCounts() *C.char {
	b, _ := json.Marshal(engine.Counts())
	return C.CString(string(b))
}

// Never captured, never logged (decision C3).
//
//export IGSession
func IGSession(acct *C.char) *C.char {
	b, err := engine.Session(str(acct))
	if err != nil {
		return fail(err)
	}
	return C.CString(string(b))
}

//export IGPause
func IGPause() { engine.Pause() }

//export IGUnpause
func IGUnpause() { engine.Unpause() }

//export IGStop
func IGStop(acct *C.char) { engine.Stop(str(acct)) }

//export IGStats
func IGStats() *C.char {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	b, _ := json.Marshal(map[string]any{"heapMB": float64(m.HeapAlloc) / 1e6, "goSysMB": float64(m.Sys) / 1e6, "goroutines": runtime.NumGoroutine()})
	return C.CString(string(b))
}

//export IGFree
func IGFree(p *C.char) { C.free(unsafe.Pointer(p)) }

func main() {}
