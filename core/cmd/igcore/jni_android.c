// The Android app's JNI bridge (decision E6 in docs/PLAN-android.md): one function per export in main.go, for
// `object IGCore` in package fi.ferry.core of the ferry-messenger-android repo. cgo compiles this file only for
// GOOS=android (its name), so iOS builds never see it. Change it with any exported signature in main.go.
//
// Strings cross as UTF-8 byte arrays both ways, never jstring: JNI's modified UTF-8 sends emoji to Go as surrogate
// pairs (invalid UTF-8), and CheckJNI aborts on the 4-byte UTF-8 Go returns (docs/spikes/2026-10-19-android-core.md).
// A null array in is an empty string; a NULL result out (IGNextEvent's timeout) is null.
#include <jni.h>
#include <stdlib.h>
#include <string.h>

#include "_cgo_export.h"

// Kotlin's bytes as a C string for one call; free() it after.
static char *in(JNIEnv *env, jbyteArray a) {
  jsize n = a ? (*env)->GetArrayLength(env, a) : 0;
  char *s = malloc((size_t)n + 1);
  if (s == NULL) abort();
  if (n > 0) (*env)->GetByteArrayRegion(env, a, 0, n, (jbyte *)s);
  s[n] = 0;
  return s;
}

// The engine's result as bytes for Kotlin; the engine's copy is freed.
static jbyteArray out(JNIEnv *env, char *s) {
  if (s == NULL) return NULL;
  jsize n = (jsize)strlen(s);
  jbyteArray a = (*env)->NewByteArray(env, n);
  if (a != NULL) (*env)->SetByteArrayRegion(env, a, 0, n, (const jbyte *)s);
  IGFree(s);
  return a;
}

#define FN(name) JNICALL Java_fi_ferry_core_IGCore_##name

// One string in, a result out (most calls).
#define ONE(name, call)                                                  \
  JNIEXPORT jbyteArray FN(name)(JNIEnv *env, jclass c, jbyteArray x) { \
    char *a = in(env, x);                                                \
    jbyteArray r = out(env, call(a));                                    \
    free(a);                                                             \
    return r;                                                            \
  }

// Two strings in, a result out.
#define TWO(name, call)                                                                \
  JNIEXPORT jbyteArray FN(name)(JNIEnv *env, jclass c, jbyteArray x, jbyteArray y) { \
    char *a = in(env, x), *b = in(env, y);                                             \
    jbyteArray r = out(env, call(a, b));                                               \
    free(a), free(b);                                                                  \
    return r;                                                                          \
  }

ONE(login, IGLogin)
TWO(resume, IGResume)
ONE(openChat, IGOpenChat)
ONE(readChat, IGReadChat)
ONE(older, IGOlder)
ONE(accept, IGAccept)
ONE(deleteThread, IGDeleteThread)
TWO(search, IGSearch)
TWO(openDM, IGOpenDM)
TWO(resolveMedia, IGResolveMedia)
TWO(unsend, IGUnsend)
ONE(markRead, IGMarkRead)
ONE(session, IGSession)
TWO(registerPush, IGRegisterPush)

JNIEXPORT void FN(setCapture)(JNIEnv *env, jclass c, jbyteArray dir) {
  char *a = in(env, dir);
  IGSetCapture(a);
  free(a);
}

JNIEXPORT void FN(setDebug)(JNIEnv *env, jclass c, jboolean blockSends, jbyteArray requestRoom) {
  char *a = in(env, requestRoom);
  IGSetDebug(blockSends, a);
  free(a);
}

JNIEXPORT jbyteArray FN(nextEvent)(JNIEnv *env, jclass c, jint timeoutMS) { return out(env, IGNextEvent(timeoutMS)); }

JNIEXPORT jbyteArray FN(send)(JNIEnv *env, jclass c, jbyteArray room, jbyteArray text, jbyteArray replyTo,
                              jbyteArray otid) {
  char *a = in(env, room), *b = in(env, text), *d = in(env, replyTo), *e = in(env, otid);
  jbyteArray r = out(env, IGSend(a, b, d, e));
  free(a), free(b), free(d), free(e);
  return r;
}

JNIEXPORT jbyteArray FN(newOTID)(JNIEnv *env, jclass c) { return out(env, IGNewOTID()); }

JNIEXPORT jbyteArray FN(sendMedia)(JNIEnv *env, jclass c, jbyteArray room, jbyteArray path, jbyteArray mime,
                                   jboolean voice, jbyteArray replyTo, jbyteArray otid) {
  char *a = in(env, room), *b = in(env, path), *d = in(env, mime), *e = in(env, replyTo), *f = in(env, otid);
  jbyteArray r = out(env, IGSendMedia(a, b, d, voice, e, f));
  free(a), free(b), free(d), free(e), free(f);
  return r;
}

JNIEXPORT jbyteArray FN(react)(JNIEnv *env, jclass c, jbyteArray room, jbyteArray message, jbyteArray emoji,
                               jboolean remove) {
  char *a = in(env, room), *b = in(env, message), *d = in(env, emoji);
  jbyteArray r = out(env, IGReact(a, b, d, remove));
  free(a), free(b), free(d);
  return r;
}

JNIEXPORT jbyteArray FN(edit)(JNIEnv *env, jclass c, jbyteArray room, jbyteArray message, jbyteArray text) {
  char *a = in(env, room), *b = in(env, message), *d = in(env, text);
  jbyteArray r = out(env, IGEdit(a, b, d));
  free(a), free(b), free(d);
  return r;
}

JNIEXPORT jbyteArray FN(typing)(JNIEnv *env, jclass c, jbyteArray room, jboolean on) {
  char *a = in(env, room);
  jbyteArray r = out(env, IGTyping(a, on));
  free(a);
  return r;
}

JNIEXPORT jbyteArray FN(counts)(JNIEnv *env, jclass c) { return out(env, IGCounts()); }

JNIEXPORT void FN(stop)(JNIEnv *env, jclass c, jbyteArray acct) {
  char *a = in(env, acct);
  IGStop(a);
  free(a);
}

JNIEXPORT jbyteArray FN(stats)(JNIEnv *env, jclass c) { return out(env, IGStats()); }
