package securechan

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"testing"
)

// v0.11.3：**无正文请求**（GET/HEAD）走通道的门禁。
//
// 现实约束：浏览器 `fetch` 不允许 GET/HEAD 带 body
// （`Request with GET/HEAD method cannot have body`），而同步 `pull` 正是 GET。故客户端在这类请求上
// 只声明通道、不发封装；服务端必须把「声明通道 + 空正文」当作**空明文**处理，且**响应仍加密**
// （否则同步数据会明文返回）。旧客户端发的「空明文封装」仍走解封分支（既有加密 body 门禁已覆盖该路径）。
func TestEmptyBodyRequestIsAcceptedAndResponseEncrypted(t *testing.T) {
	serverKey, err := NewEphemeralKey()
	if err != nil {
		t.Fatalf("server key: %v", err)
	}
	clientPriv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("client key: %v", err)
	}
	clientPubB64 := base64.StdEncoding.EncodeToString(clientPriv.PublicKey().Bytes())

	var seenBody []byte
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		buf := make([]byte, 16)
		n, _ := r.Body.Read(buf)
		seenBody = buf[:n]
		if r.ContentLength != 0 {
			t.Errorf("下游应看到 ContentLength=0，实际 %d", r.ContentLength)
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"ok":true,"n":42}`))
	})
	h := MiddlewareWithReplay(serverKey, next, NewReplayCache(0, 0))

	reqID := base64.StdEncoding.EncodeToString([]byte("reqid-0123456789"))
	req := httptest.NewRequest(http.MethodGet, "/api/v1/sync/pull", nil)
	req.Header.Set(HeaderEnc, "1")
	req.Header.Set(HeaderEph, clientPubB64)
	req.Header.Set(HeaderReqID, reqID)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("空正文的通道请求应被接受，实际 %d（body=%q）", rec.Code, rec.Body.String())
	}
	if len(seenBody) != 0 {
		t.Fatalf("下游应看到空正文，实际 %q", string(seenBody))
	}
	if rec.Header().Get(HeaderEnc) != "1" {
		t.Fatal("响应必须仍被加密（否则同步数据明文返回）")
	}
	k, err := DeriveKChan(clientPriv, serverKey.PublicB64())
	if err != nil {
		t.Fatalf("derive K_chan: %v", err)
	}
	plain, err := Open(k, rec.Body.String(), AAD(http.MethodGet, "/api/v1/sync/pull", reqID))
	if err != nil {
		t.Fatalf("响应应可用同一 K_chan 解封：%v", err)
	}
	if string(plain) != `{"ok":true,"n":42}` {
		t.Fatalf("解封内容不符：%q", string(plain))
	}
}
