// Package securechan 实现 M10 的**受保护通道**（FR-50，详见 auth.md §9）。
//
// 分层：本节保护**线路**（服务端可解密）；笔记内容本身的端到端加密见 encrypted-notebook。
//
// 设计要点（§9.6 已固化）：
//   - 服务端持有**长期 X25519 密钥**（信任根，TOFU + 指纹，不依赖 CA）；
//   - 客户端**逐请求**生成临时 X25519 密钥对，与服务端长期公钥 ECDH → HKDF-SHA256 → `K_chan`；
//   - 正文 = `base64(ver|alg|nonce|ct|tag)`，AES-256-GCM（Go 仅标准库，故不支持 ChaCha20）；
//   - AAD = `method \\n path \\n reqId`，把密文绑定到具体请求；
//   - 服务端维护有界请求 id 缓存以拒绝重放。
package securechan

import (
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// Key 是服务端长期 X25519 密钥。
type Key struct {
	priv *ecdh.PrivateKey
}

// LoadOrCreateKey 读取 path 处的私钥；不存在 / 长度不对则生成并持久化（0600）。
//
// 私钥**不入库**而是落盘单文件：通道信任根与业务数据解耦，便于备份 / 轮换。
func LoadOrCreateKey(path string) (*Key, error) {
	if raw, err := os.ReadFile(path); err == nil && len(raw) == 32 {
		priv, perr := ecdh.X25519().NewPrivateKey(raw)
		if perr != nil {
			return nil, perr
		}
		return &Key{priv: priv}, nil
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	priv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	if dir := filepath.Dir(path); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return nil, err
		}
	}
	if err := os.WriteFile(path, priv.Bytes(), 0o600); err != nil {
		return nil, err
	}
	return &Key{priv: priv}, nil
}

// NewEphemeralKey 生成内存中的临时密钥（**测试 / 自检**用；服务端长期密钥请用 LoadOrCreateKey）。
func NewEphemeralKey() (*Key, error) {
	priv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	return &Key{priv: priv}, nil
}

func (k *Key) private() *ecdh.PrivateKey { return k.priv }

// PublicB64 返回公钥 base64（握手响应字段 `serverPub`）。
func (k *Key) PublicB64() string {
	return base64.StdEncoding.EncodeToString(k.priv.PublicKey().Bytes())
}

// Fingerprint 返回 `sha256(公钥)` 前 8 字节的短码（形如 `AB12-CD34-EF56-7890`），供 TOFU 核对。
func (k *Key) Fingerprint() string {
	sum := sha256.Sum256(k.priv.PublicKey().Bytes())
	short := strings.ToUpper(hex.EncodeToString(sum[:8]))
	var b strings.Builder
	for i := 0; i < len(short); i += 4 {
		if i > 0 {
			b.WriteByte('-')
		}
		b.WriteString(short[i : i+4])
	}
	return b.String()
}
