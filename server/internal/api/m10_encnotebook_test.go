package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
)

// M10-T29：加密笔记本的线上字段**透传**（服务端零解密分支，encrypted-notebook.md §8 / §10）。
//
// 要点：服务端只搬运、不解析、不解密——故这里用「看起来像密文的字符串」验证**逐字节保真**，
// 并验证旧客户端（不带新字段）仍然工作（默认 false）。
func TestM10EncryptedNotebookPassThrough(t *testing.T) {
	srv, _, _ := newM10Server(t)
	token := register(t, srv)

	const (
		cryptoMeta = `{"v":1,"kdf":"argon2id","m":65536,"t":3,"p":1,` +
			`"salt":"AAECAwQFBgcICQoLDA0ODw==","verifier":"qrvM3e7/AAECAwQFBgcICQoLDA0ODw=="}`
		// 真实的封装形态（ver|alg|nonce|ct|tag 的 base64），含 `+` / `/` / `=` 等 URL 敏感字符。
		cipherTitle = "AQEAAAAAAAAAAAAAAAE7RQzjmheTxZ9NtvnqTKlpBceBXBtXhN/nZ5Ryql5t/G2uutGpaSs="
		cipherBody  = "AQEAAAAAAAAAAAAAAAE7RQzjmheTxZ9NtvnqTKlpBceBXBtXhN/nZ5Ryql5t/G2uutGpaSs="
	)

	push, _ := json.Marshal(map[string]any{
		"clientId": "dev-a",
		"items": []map[string]any{{
			"id": "note-enc-1", "title": cipherTitle, "content": cipherBody,
			"baseVersion": 0, "version": 1, "sourceDevice": "dev-a",
			"notebookId": "nb-enc-1", "encrypted": true,
		}},
		"notebooks": []map[string]any{{
			"id": "nb-enc-1", "parentId": "", "name": "私密", "sortOrder": 0,
			"baseVersion": 0, "version": 1, "sourceDevice": "dev-a",
			"encrypted": true, "cryptoMeta": cryptoMeta,
		}},
	})
	if rec := authReq(srv, token, http.MethodPost, "/api/v1/sync/push", push); rec.Code != http.StatusOK {
		t.Fatalf("push 应 200，实际 %d %s", rec.Code, rec.Body.String())
	}

	rec := authReq(srv, token, http.MethodGet, "/api/v1/sync/pull?since=1970-01-01T00:00:00Z", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("pull 应 200，实际 %d", rec.Code)
	}
	raw := rec.Body.Bytes()
	// 密文必须**逐字节**出现在响应里（服务端不得做任何转义 / 解码 / 改写）
	if !bytes.Contains(raw, []byte(cipherBody)) {
		t.Errorf("密文正文未逐字节透传")
	}

	var out struct {
		Notes []struct {
			ID        string `json:"id"`
			Title     string `json:"title"`
			Content   string `json:"content"`
			Encrypted bool   `json:"encrypted"`
		} `json:"notes"`
		Notebooks []struct {
			ID         string `json:"id"`
			Name       string `json:"name"`
			Encrypted  bool   `json:"encrypted"`
			CryptoMeta string `json:"cryptoMeta"`
		} `json:"notebooks"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("decode pull: %v", err)
	}

	var noteOK, nbOK bool
	for _, n := range out.Notes {
		if n.ID != "note-enc-1" {
			continue
		}
		noteOK = true
		if n.Title != cipherTitle || n.Content != cipherBody {
			t.Errorf("密文被改写：title=%q content=%q", n.Title, n.Content)
		}
		if !n.Encrypted {
			t.Errorf("notes[].encrypted 应透传为 true")
		}
	}
	for _, nb := range out.Notebooks {
		if nb.ID != "nb-enc-1" {
			continue
		}
		nbOK = true
		if !nb.Encrypted {
			t.Errorf("notebooks[].encrypted 应透传为 true")
		}
		if nb.CryptoMeta != cryptoMeta {
			t.Errorf("cryptoMeta 应逐字节透传：\n got %s\nwant %s", nb.CryptoMeta, cryptoMeta)
		}
		if nb.Name != "私密" {
			t.Errorf("笔记本名称保持明文（便于辨认该解锁哪个），实际 %q", nb.Name)
		}
	}
	if !noteOK || !nbOK {
		t.Fatalf("pull 未返回加密笔记 / 笔记本（note=%v nb=%v）", noteOK, nbOK)
	}
}

// 旧客户端（不带新字段）照旧工作：新字段缺省为 false / 空串（向后兼容）。
func TestM10PlainNotebookDefaultsUnencrypted(t *testing.T) {
	srv, _, _ := newM10Server(t)
	token := register(t, srv)

	push, _ := json.Marshal(map[string]any{
		"clientId":  "dev-old",
		"items":     []map[string]any{{"id": "n1", "title": "t", "content": "c", "baseVersion": 0, "version": 1}},
		"notebooks": []map[string]any{{"id": "nb1", "name": "普通", "baseVersion": 0, "version": 1}},
	})
	if rec := authReq(srv, token, http.MethodPost, "/api/v1/sync/push", push); rec.Code != http.StatusOK {
		t.Fatalf("push 应 200，实际 %d %s", rec.Code, rec.Body.String())
	}

	rec := authReq(srv, token, http.MethodGet, "/api/v1/sync/pull?since=1970-01-01T00:00:00Z", nil)
	var out struct {
		Notes []struct {
			Encrypted bool `json:"encrypted"`
		} `json:"notes"`
		Notebooks []struct {
			Encrypted  bool   `json:"encrypted"`
			CryptoMeta string `json:"cryptoMeta"`
		} `json:"notebooks"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode pull: %v", err)
	}
	for _, n := range out.Notes {
		if n.Encrypted {
			t.Errorf("未声明加密的笔记不应是加密态")
		}
	}
	for _, nb := range out.Notebooks {
		if nb.Encrypted || nb.CryptoMeta != "" {
			t.Errorf("未声明加密的笔记本应为普通态，实际 encrypted=%v cryptoMeta=%q", nb.Encrypted, nb.CryptoMeta)
		}
	}
}
