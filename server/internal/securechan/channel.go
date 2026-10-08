package securechan

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"sync"
	"time"
)

// 封装格式与算法标识（与客户端、Spike-003 向量一致，见 auth.md §9.6）。
const (
	// FormatVersion 是封装格式版本。
	FormatVersion = 0x01
	// AlgAES256GCM 是唯一实现的算法（Go 仅标准库）。
	AlgAES256GCM = 0x01
	// AlgChaCha20Poly1305 仅保留标识位：服务端**不实现**（Go 标准库无此原语）。
	AlgChaCha20Poly1305 = 0x02

	nonceLen = 12
	tagLen   = 16

	// KeyLen 是 K_chan 长度。
	KeyLen = 32

	kdfInfo = "sui-channel-v1"
)

// ErrChannel 是通道层的统一失败错误。
//
// **对外不区分原因**（解密失败 / AAD 不符 / 封装非法 / 缺头）——避免给探测者反馈（§9.6）。
var ErrChannel = errors.New("invalid channel message")

// DeriveKChan 由「本端私钥 + 对端公钥（base64）」派生会话通道密钥（§9.6）。
//
// `K_chan = HKDF-SHA256(ECDH(...), salt = 空, info = "sui-channel-v1")`；salt 传 nil 时
// HKDF 以 HashLen 个零字节代入（RFC 5869 §2.2），与客户端口径一致。
func DeriveKChan(priv *ecdh.PrivateKey, peerPubB64 string) ([]byte, error) {
	raw, err := base64.StdEncoding.DecodeString(peerPubB64)
	if err != nil {
		return nil, fmt.Errorf("%w: eph 不是合法 base64", ErrChannel)
	}
	peer, err := ecdh.X25519().NewPublicKey(raw)
	if err != nil {
		return nil, fmt.Errorf("%w: eph 不是合法 X25519 公钥", ErrChannel)
	}
	shared, err := priv.ECDH(peer)
	if err != nil {
		return nil, fmt.Errorf("%w: ECDH 失败", ErrChannel)
	}
	key, err := hkdf.Key(sha256.New, shared, nil, kdfInfo, KeyLen)
	if err != nil {
		return nil, err
	}
	return key, nil
}

// AAD 构造附加认证数据：`method \n path \n reqId`（§9.6）。
//
// 绑定「哪个方法、哪个路径、哪次请求」，防止密文被搬到别的端点复用；响应复用同一 AAD。
func AAD(method, path, reqID string) []byte {
	return []byte(method + "\n" + path + "\n" + reqID)
}

// Seal 用 K_chan 加密并返回 base64 自描述封装 `ver|alg|nonce|ct|tag`。
func Seal(key, nonce, plaintext, aad []byte) (string, error) {
	if len(nonce) != nonceLen {
		return "", fmt.Errorf("%w: nonce 长度", ErrChannel)
	}
	aead, err := newAEAD(key)
	if err != nil {
		return "", err
	}
	sealed := aead.Seal(nil, nonce, plaintext, aad)
	env := make([]byte, 0, 2+nonceLen+len(sealed))
	env = append(env, FormatVersion, AlgAES256GCM)
	env = append(env, nonce...)
	env = append(env, sealed...)
	return base64.StdEncoding.EncodeToString(env), nil
}

// Open 解封；任何异常（base64 / 版本 / 算法 / tag 校验）都归一为 [ErrChannel]。
func Open(key []byte, envB64 string, aad []byte) ([]byte, error) {
	raw, err := base64.StdEncoding.DecodeString(envB64)
	if err != nil || len(raw) < 2+nonceLen+tagLen {
		return nil, ErrChannel
	}
	if raw[0] != FormatVersion || raw[1] != AlgAES256GCM {
		return nil, ErrChannel
	}
	nonce := raw[2 : 2+nonceLen]
	sealed := raw[2+nonceLen:]
	aead, err := newAEAD(key)
	if err != nil {
		return nil, err
	}
	out, err := aead.Open(nil, nonce, sealed, aad)
	if err != nil {
		return nil, ErrChannel
	}
	return out, nil
}

func newAEAD(key []byte) (cipher.AEAD, error) {
	if len(key) != KeyLen {
		return nil, fmt.Errorf("%w: K_chan 长度", ErrChannel)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// NewNonce 生成 12 字节随机 nonce（每次加密一条）。
func NewNonce() ([]byte, error) { return randomBytes(nonceLen) }

// NewReqID 生成请求 id（16 字节随机，base64）。
func NewReqID() (string, error) {
	b, err := randomBytes(16)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(b), nil
}

func randomBytes(n int) ([]byte, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return nil, err
	}
	return b, nil
}

// ReplayCache 是有界的请求 id 缓存（§9.6：TTL 5 分钟、上限 4096）。
//
// 只对**已成功解密**的请求登记（见 [Middleware]）：否则攻击者可用随机 id 灌满缓存。
type ReplayCache struct {
	mu   sync.Mutex
	ttl  time.Duration
	cap  int
	seen map[string]time.Time
}

// NewReplayCache 创建缓存；ttl <= 0 或 capacity <= 0 时取默认值。
func NewReplayCache(ttl time.Duration, capacity int) *ReplayCache {
	if ttl <= 0 {
		ttl = 5 * time.Minute
	}
	if capacity <= 0 {
		capacity = 4096
	}
	return &ReplayCache{ttl: ttl, cap: capacity, seen: make(map[string]time.Time)}
}

// Seen 报告 id 是否**已经出现过**；首次出现则登记并返回 false。
func (c *ReplayCache) Seen(id string) bool {
	if c == nil {
		return false
	}
	now := time.Now()
	c.mu.Lock()
	defer c.mu.Unlock()
	c.evictLocked(now)
	if t, ok := c.seen[id]; ok && now.Sub(t) < c.ttl {
		return true
	}
	if len(c.seen) >= c.cap {
		// 容量已满：先按 TTL 清理，仍满则丢弃最旧的一条（保证有界，不因攻击者灌入而无界增长）。
		c.evictLocked(now)
		if len(c.seen) >= c.cap {
			oldestKey, oldest := "", now
			for k, t := range c.seen {
				if t.Before(oldest) || oldestKey == "" {
					oldestKey, oldest = k, t
				}
			}
			delete(c.seen, oldestKey)
		}
	}
	c.seen[id] = now
	return false
}

func (c *ReplayCache) evictLocked(now time.Time) {
	for k, t := range c.seen {
		if now.Sub(t) >= c.ttl {
			delete(c.seen, k)
		}
	}
}
