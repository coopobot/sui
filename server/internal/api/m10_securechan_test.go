package api

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"sui/note-server/internal/securechan"
)

// ---- 受保护通道客户端夹具（M10-T27 / FR-50，auth.md §9.6） ----
//
// 与服务端长期公钥协商 `K_chan`，按 §9.6 封装请求 / 解封响应；用于端到端验证服务端实现。
type chanClient struct {
	t   *testing.T
	key []byte
	eph string // 客户端本次请求的临时 X25519 公钥（base64）
}

func newChanClient(t *testing.T, serverPubB64 string) *chanClient {
	t.Helper()
	priv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	key, err := securechan.DeriveKChan(priv, serverPubB64)
	if err != nil {
		t.Fatal(err)
	}
	return &chanClient{
		t:   t,
		key: key,
		eph: base64.StdEncoding.EncodeToString(priv.PublicKey().Bytes()),
	}
}

// sealFor 用指定 AAD 的 path 封装（用于 AAD 错配的负向用例）。
func (c *chanClient) sealFor(method, aadPath, reqID string, body []byte) string {
	c.t.Helper()
	nonce, err := securechan.NewNonce()
	if err != nil {
		c.t.Fatal(err)
	}
	env, err := securechan.Seal(c.key, nonce, body, securechan.AAD(method, aadPath, reqID))
	if err != nil {
		c.t.Fatal(err)
	}
	return env
}

// do 发送一次加密请求，返回状态码与**解封后**的正文（未声明密文的响应原样返回）。
func (c *chanClient) do(srv *Server, method, path string, body []byte) (int, []byte, string) {
	c.t.Helper()
	reqID, err := securechan.NewReqID()
	if err != nil {
		c.t.Fatal(err)
	}
	env := c.sealFor(method, path, reqID, body)
	code, out, enc := c.doRaw(srv, method, path, reqID, env)
	if enc == "1" {
		plain, err := securechan.Open(c.key, out, securechan.AAD(method, path, reqID))
		if err != nil {
			c.t.Fatalf("解封响应失败：%v", err)
		}
		return code, plain, enc
	}
	return code, []byte(out), enc
}

// doRaw 发送**原样**密文（篡改 / 重放 / AAD 错配等负向用例）。
func (c *chanClient) doRaw(srv *Server, method, path, reqID, env string) (int, string, string) {
	c.t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(env))
	req.Header.Set(securechan.HeaderEnc, "1")
	req.Header.Set(securechan.HeaderEph, c.eph)
	req.Header.Set(securechan.HeaderReqID, reqID)
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, req)
	return rec.Code, rec.Body.String(), rec.Header().Get(securechan.HeaderEnc)
}

func channelServer(t *testing.T) (*Server, *securechan.Key) {
	t.Helper()
	srv, _, _ := newM10Server(t)
	key, err := securechan.NewEphemeralKey()
	if err != nil {
		t.Fatal(err)
	}
	srv.SetChannelKey(key)
	return srv, key
}

func TestM10HandshakeReturnsStableKeyAndFingerprint(t *testing.T) {
	srv, key := channelServer(t)

	for i := 0; i < 2; i++ { // 两次调用必须一致（客户端据指纹做 TOFU 核对）
		req := httptest.NewRequest(http.MethodGet, "/api/v1/crypto/handshake", nil)
		rec := httptest.NewRecorder()
		srv.Router().ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("握手应 200，实际 %d %s", rec.Code, rec.Body.String())
		}
		var resp struct {
			OK          bool   `json:"ok"`
			Alg         string `json:"alg"`
			ServerPub   string `json:"serverPub"`
			Fingerprint string `json:"fingerprint"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
			t.Fatal(err)
		}
		if !resp.OK || resp.Alg != "x25519" {
			t.Fatalf("握手响应异常：%+v", resp)
		}
		if resp.ServerPub != key.PublicB64() {
			t.Fatal("serverPub 必须是服务端长期公钥")
		}
		if resp.Fingerprint != key.Fingerprint() {
			t.Fatal("fingerprint 必须与长期公钥一致（TOFU 信任根）")
		}
	}
}

// 受保护通道的核心价值：**口令与令牌在线上是密文**，且响应同样加密。
func TestM10SecureLoginEncryptsRequestAndResponse(t *testing.T) {
	srv, key := channelServer(t)
	register(t, srv) // 明文注册（兼容路径）建立账号

	cc := newChanClient(t, key.PublicB64())
	body, _ := json.Marshal(map[string]string{"username": "u1", "password": "pw"})
	code, plain, enc := cc.do(srv, http.MethodPost, "/api/v1/login", body)

	if code != http.StatusOK {
		t.Fatalf("加密登录应 200，实际 %d %s", code, plain)
	}
	if enc != "1" {
		t.Fatal("响应应声明为通道密文")
	}
	var out struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
	}
	if err := json.Unmarshal(plain, &out); err != nil {
		t.Fatalf("解封后应为 JSON：%v（%s）", err, plain)
	}
	if out.AccessToken == "" || out.RefreshToken == "" {
		t.Fatalf("解封后应含双令牌：%s", plain)
	}
}

func TestM10PlainRequestsStillAccepted(t *testing.T) {
	srv, _ := channelServer(t)
	if token := register(t, srv); token == "" {
		t.Fatal("未声明通道的明文请求必须照常工作（通道是加成而非强制）")
	}
}

func TestM10TamperedCiphertextRejected(t *testing.T) {
	srv, key := channelServer(t)
	register(t, srv)
	cc := newChanClient(t, key.PublicB64())

	reqID, _ := securechan.NewReqID()
	body, _ := json.Marshal(map[string]string{"username": "u1", "password": "pw"})
	env := cc.sealFor(http.MethodPost, "/api/v1/login", reqID, body)
	raw, err := base64.StdEncoding.DecodeString(env)
	if err != nil {
		t.Fatal(err)
	}
	raw[len(raw)-1] ^= 0x01 // 篡改 tag

	code, out, _ := cc.doRaw(srv, http.MethodPost, "/api/v1/login", reqID,
		base64.StdEncoding.EncodeToString(raw))
	if code != http.StatusBadRequest || !strings.Contains(out, "invalid-channel") {
		t.Fatalf("篡改密文应 400 invalid-channel，实际 %d %s", code, out)
	}
}

func TestM10ReplayedRequestRejected(t *testing.T) {
	srv, key := channelServer(t)
	register(t, srv)
	cc := newChanClient(t, key.PublicB64())

	reqID, _ := securechan.NewReqID()
	body, _ := json.Marshal(map[string]string{"username": "u1", "password": "pw"})
	env := cc.sealFor(http.MethodPost, "/api/v1/login", reqID, body)

	if code, out, _ := cc.doRaw(srv, http.MethodPost, "/api/v1/login", reqID, env); code != http.StatusOK {
		t.Fatalf("首次请求应成功，实际 %d %s", code, out)
	}
	code, out, _ := cc.doRaw(srv, http.MethodPost, "/api/v1/login", reqID, env)
	if code != http.StatusConflict || !strings.Contains(out, "replayed") {
		t.Fatalf("重放应 409 replayed，实际 %d %s", code, out)
	}
}

func TestM10AADMismatchRejected(t *testing.T) {
	srv, key := channelServer(t)
	register(t, srv)
	cc := newChanClient(t, key.PublicB64())

	// 用 /api/v1/login 的 AAD 封装，却发到 /api/v1/register → AAD 不符必须拒绝。
	reqID, _ := securechan.NewReqID()
	body, _ := json.Marshal(map[string]string{"username": "u1", "password": "pw"})
	env := cc.sealFor(http.MethodPost, "/api/v1/login", reqID, body)

	code, out, _ := cc.doRaw(srv, http.MethodPost, "/api/v1/register", reqID, env)
	if code != http.StatusBadRequest || !strings.Contains(out, "invalid-channel") {
		t.Fatalf("AAD 不符应 400 invalid-channel，实际 %d %s", code, out)
	}
}

func TestM10ChannelDisabledWithoutKey(t *testing.T) {
	srv, _, _ := newM10Server(t) // 未注入通道密钥

	req := httptest.NewRequest(http.MethodGet, "/api/v1/crypto/handshake", nil)
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("未启用通道时握手应 503，实际 %d", rec.Code)
	}

	// 加密请求在未启用通道时必须被拒绝（不能静默当明文处理 ✗ 否则等于把密文写进库）。
	req = httptest.NewRequest(http.MethodPost, "/api/v1/login", strings.NewReader("AQEAAAA="))
	req.Header.Set(securechan.HeaderEnc, "1")
	rec = httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized && rec.Code != http.StatusBadRequest {
		t.Fatalf("未启用通道时的加密请求应被拒绝，实际 %d %s", rec.Code, rec.Body.String())
	}
}
