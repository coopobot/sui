package securechan

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
)

// 通道请求头（§9.6）。
const (
	// HeaderEnc 声明「本请求正文为通道密文」。
	HeaderEnc = "X-Sui-Enc"
	// HeaderEph 承载客户端本次请求的临时 X25519 公钥（base64）。
	HeaderEph = "X-Sui-Eph"
	// HeaderReqID 承载本次请求的随机 id（base64），用于重放拒绝。
	HeaderReqID = "X-Sui-Req-Id"
)

// MaxEncryptedBody 是**密文**正文上限：明文上限（blob 32 MiB）base64 后约 4/3，再留余量。
//
// 通道整包缓冲（§9.6 已记录该边界），故上限必须显式，不能无界读。
const MaxEncryptedBody = 48 << 20

var defaultReplay = NewReplayCache(0, 0)

// Middleware 包裹 handler：**仅当**请求带头 `X-Sui-Enc: 1` 时解封请求正文并加密响应正文。
//
// 未声明时**原样透传**——通道是加成而非强制（同一二进制要服务未升级客户端，§9.6）。
func Middleware(key *Key, next http.Handler) http.Handler {
	return MiddlewareWithReplay(key, next, defaultReplay)
}

// MiddlewareWithReplay 与 [Middleware] 相同，但可注入重放缓存（测试用）。
func MiddlewareWithReplay(key *Key, next http.Handler, replay *ReplayCache) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.TrimSpace(r.Header.Get(HeaderEnc)) != "1" {
			next.ServeHTTP(w, r)
			return
		}
		if key == nil {
			writeChannelError(w)
			return
		}
		k, err := DeriveKChan(key.private(), r.Header.Get(HeaderEph))
		if err != nil {
			writeChannelError(w)
			return
		}
		reqID := strings.TrimSpace(r.Header.Get(HeaderReqID))
		if reqID == "" {
			writeChannelError(w)
			return
		}
		aad := AAD(r.Method, r.URL.Path, reqID)

		body, err := io.ReadAll(io.LimitReader(r.Body, MaxEncryptedBody+1))
		if err != nil || len(body) > MaxEncryptedBody {
			writeChannelError(w)
			return
		}
		// **无正文**请求（GET/HEAD 等）：浏览器 fetch 不允许这两类方法带 body，故客户端在这类
		// 请求上只声明通道、不发封装——此时明文正文就是空，无需解封；**响应照旧加密**。
		// 兼容：旧客户端仍会发「空明文的封装」，走下面这条解封分支。
		var plain []byte
		if len(body) > 0 {
			plain, err = Open(k, string(body), aad)
			if err != nil {
				writeChannelError(w)
				return
			}
		}
		// 重放检查放在**解密成功之后**：否则攻击者可用随机 reqId 灌满缓存。
		if replay.Seen(reqID) {
			writeJSON(w, http.StatusConflict, map[string]any{"ok": false, "error": "replayed"})
			return
		}

		r.Body = io.NopCloser(bytes.NewReader(plain))
		r.ContentLength = int64(len(plain))

		cw := &captureWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(cw, r)

		if cw.body.Len() == 0 {
			w.WriteHeader(cw.status)
			return
		}
		nonce, err := NewNonce()
		if err != nil {
			writeChannelError(w)
			return
		}
		env, err := Seal(k, nonce, cw.body.Bytes(), aad)
		if err != nil {
			writeChannelError(w)
			return
		}
		w.Header().Set(HeaderEnc, "1")
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Content-Length", strconv.Itoa(len(env)))
		w.WriteHeader(cw.status)
		_, _ = io.WriteString(w, env)
	})
}

// captureWriter 缓冲内层 handler 的响应，供整体加密后写出。
//
// 暴露 [Unwrap]：内层 handler 会用 `http.ResponseController` 延长读写期限
// （见 input-validation.md §8），控制器依赖 Unwrap 才能拿到真实连接。
type captureWriter struct {
	http.ResponseWriter
	status int
	wrote  bool
	body   bytes.Buffer
}

func (c *captureWriter) WriteHeader(code int) {
	if c.wrote {
		return
	}
	c.status = code
	c.wrote = true
}

func (c *captureWriter) Write(b []byte) (int, error) {
	c.wrote = true
	return c.body.Write(b)
}

// Unwrap 供 http.ResponseController 透传到真实 ResponseWriter。
func (c *captureWriter) Unwrap() http.ResponseWriter { return c.ResponseWriter }

// Flush 空实现：响应被整体缓冲后加密，期间不向客户端输出任何字节。
func (c *captureWriter) Flush() {}

func writeChannelError(w http.ResponseWriter) {
	writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid-channel"})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
