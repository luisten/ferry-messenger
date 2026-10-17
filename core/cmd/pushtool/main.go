// Spike helper on the Mac: makes web push keys and decrypts what webhook.site received.
package main

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"

	"go.mau.fi/mautrix-meta/pkg/messagix/pushcrypto"
)

func main() {
	switch os.Args[1] {
	case "gen": // gen <keys.json>
		pk, _ := ecdh.P256().GenerateKey(rand.Reader)
		auth := make([]byte, 16)
		rand.Read(auth)
		keys := pushcrypto.PushKeys{P256DH: pk.PublicKey().Bytes(), Auth: auth, Private: pk.Bytes()}
		b, _ := json.Marshal(keys)
		os.WriteFile(os.Args[2], b, 0o600)
		fmt.Println(base64.RawURLEncoding.EncodeToString(keys.P256DH), base64.RawURLEncoding.EncodeToString(keys.Auth))
	case "decrypt": // decrypt <keys.json> <body file> <content-encoding> <crypto-key> <encryption>
		var keys pushcrypto.PushKeys
		b, _ := os.ReadFile(os.Args[2])
		json.Unmarshal(b, &keys)
		body, _ := os.ReadFile(os.Args[3])
		wpd, _ := json.Marshal(pushcrypto.WebPushData{Data: body, ContentEncoding: os.Args[4], CryptoKey: os.Args[5], Encryption: os.Args[6]})
		res, err := keys.Decrypt(context.Background(), wpd)
		if err != nil {
			fmt.Println("error:", err)
			os.Exit(1)
		}
		out, _ := json.MarshalIndent(res, "", "  ")
		fmt.Println(string(out))
	}
}
