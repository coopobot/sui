package securechan

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"testing"
	"time"
)

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// TestSpikeVectorEnvelope 用 Spike-003 的向量证明**封装布局与 AAD 口径**与 Dart 端逐字节一致。
//
// 这是跨端互操作的回归门禁：布局 / 拼接顺序 / base64 任一处漂移都会在这里失败。
func TestSpikeVectorEnvelope(t *testing.T) {
	// poc-003/sui-crypto-v1.json：hkdf[app] → K；aesgcm / envelope 段。
	key := mustHex(t, "04da26d6647c364b952145871cc6cf3f547700e1096d0a209b75a71762767fde")
	nonce := mustHex(t, "000000000000000000000001")
	aad := []byte("nb-1|note-1|content")
	plain := []byte("随手记 Sui spike-003")
	want := "AQEAAAAAAAAAAAAAAAE7RQzjmheTxZ9NtvnqTKlpBceBXBtXhN/nZ5Ryql5t/G2uutGpaSs="

	env, err := Seal(key, nonce, plain, aad)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	if env != want {
		t.Fatalf("封装必须与 Spike 向量逐字节一致：\n got %s\nwant %s", env, want)
	}

	got, err := Open(key, env, aad)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if !bytes.Equal(got, plain) {
		t.Fatalf("解封内容不符：%q", got)
	}

	// AAD 不符（密文被搬到别的笔记 / 字段）必须失败。
	if _, err := Open(key, env, []byte("nb-1|note-2|content")); err == nil {
		t.Fatal("AAD 不符应拒绝解密")
	}
	// 算法标识位（ChaCha20，标识 0x02）不被实现，必须拒绝。
	raw, _ := base64.StdEncoding.DecodeString(env)
	raw[1] = AlgChaCha20Poly1305
	if _, err := Open(key, base64.StdEncoding.EncodeToString(raw), aad); err == nil {
		t.Fatal("未实现的算法标识应拒绝")
	}
}

// TestDeriveKChanAgrees 两侧（客户端临时私钥 / 服务端长期私钥）派生出的 K_chan 必须相同。
func TestDeriveKChanAgrees(t *testing.T) {
	server, err := NewEphemeralKey()
	if err != nil {
		t.Fatal(err)
	}
	clientPriv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	clientPubB64 := base64.StdEncoding.EncodeToString(clientPriv.PublicKey().Bytes())

	serverSide, err := DeriveKChan(server.private(), clientPubB64)
	if err != nil {
		t.Fatal(err)
	}
	// 客户端侧：用自己的私钥 + 服务端公钥（同一函数，参数对调）
	clientSide, err := DeriveKChan(clientPriv, server.PublicB64())
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(serverSide, clientSide) {
		t.Fatal("两侧 K_chan 必须相同")
	}
	if len(serverSide) != KeyLen {
		t.Fatalf("K_chan 长度应为 %d，实际 %d", KeyLen, len(serverSide))
	}
}

func TestFingerprintStableAndShort(t *testing.T) {
	k, err := NewEphemeralKey()
	if err != nil {
		t.Fatal(err)
	}
	fp := k.Fingerprint()
	if len(fp) != 19 { // 8 字节 = 16 hex + 3 个连字符
		t.Fatalf("指纹长度应为 19，实际 %d（%s）", len(fp), fp)
	}
	if fp != k.Fingerprint() {
		t.Fatal("同一密钥的指纹必须稳定")
	}
	k2, _ := NewEphemeralKey()
	if fp == k2.Fingerprint() {
		t.Fatal("不同密钥的指纹不应相同")
	}
}

func TestReplayCacheRejectsDuplicateAndStaysBounded(t *testing.T) {
	c := NewReplayCache(50*time.Millisecond, 4)
	if c.Seen("a") {
		t.Fatal("首次出现的 id 不应判为重放")
	}
	if !c.Seen("a") {
		t.Fatal("重复 id 必须判为重放")
	}
	// 容量有界：写入远超上限的量，缓存不得无界增长。
	for _, id := range []string{"b", "c", "d", "e", "f", "g", "h"} {
		c.Seen(id)
	}
	c.mu.Lock()
	n := len(c.seen)
	c.mu.Unlock()
	if n > 4 {
		t.Fatalf("缓存必须保持有界（<= 4），实际 %d", n)
	}
	// TTL 过期后同 id 可再次使用。
	time.Sleep(80 * time.Millisecond)
	if c.Seen("a") {
		t.Fatal("超过 TTL 的 id 不应再判为重放")
	}
}
