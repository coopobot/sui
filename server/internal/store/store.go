// Package store 提供 Sui 服务端的数据访问层（SQLite）。
//
// 服务端元数据表与客户端共享 schema 对齐（notes 公共字段），并保留服务端
// 私有状态（version 权威版本线、墓碑 tombstone、blob refcount）。
package store

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"time"

	_ "modernc.org/sqlite"
)

// Store 封装服务端 SQLite 连接与数据访问。
type Store struct {
	db *sql.DB
}

// Open 打开（必要时创建）服务端数据库。
func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1) // SQLite 单写
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) migrate() error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS users (
			id TEXT PRIMARY KEY,
			username TEXT NOT NULL UNIQUE,
			password_hash TEXT NOT NULL,
			token TEXT NOT NULL UNIQUE,
			created_at TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS notes (
			id TEXT PRIMARY KEY,
			title TEXT NOT NULL DEFAULT '',
			content_markdown TEXT NOT NULL DEFAULT '',
			version INTEGER NOT NULL DEFAULT 0,   -- 服务端权威版本线
			is_deleted INTEGER NOT NULL DEFAULT 0, -- 墓碑
			updated_at TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS revisions (
			id TEXT PRIMARY KEY,
			note_id TEXT NOT NULL,
			version INTEGER NOT NULL,
			content_markdown TEXT NOT NULL DEFAULT '',
			source_device TEXT NOT NULL DEFAULT '',
			is_conflict INTEGER NOT NULL DEFAULT 0,
			created_at TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS blobs (
			sha256 TEXT PRIMARY KEY,
			size INTEGER NOT NULL,
			refcount INTEGER NOT NULL DEFAULT 0,
			created_at TEXT NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_notes_updated ON notes(updated_at)`,
		`CREATE INDEX IF NOT EXISTS idx_revisions_note ON revisions(note_id)`,
	}
	for _, st := range stmts {
		if _, err := s.db.Exec(st); err != nil {
			return err
		}
	}
	return nil
}

// Close 关闭数据库。
func (s *Store) Close() error { return s.db.Close() }

// ---- 用户 / 设备鉴权 ----

// VerifyToken 校验 token 并返回 username；无效返回 (false, "").
func (s *Store) VerifyToken(token string) (bool, string) {
	var username string
	err := s.db.QueryRow(
		`SELECT username FROM users WHERE token = ?`, token,
	).Scan(&username)
	if err != nil {
		return false, ""
	}
	return true, username
}

// CreateUser 创建用户，返回新 token。
func (s *Store) CreateUser(username, passwordHash string) (token string, err error) {
	tok, _ := NewToken()
	_, err = s.db.Exec(
		`INSERT INTO users (id, username, password_hash, token, created_at)
		 VALUES (?, ?, ?, ?, ?)`,
		tok[:16], username, passwordHash, tok, time.Now().UTC().Format(time.RFC3339),
	)
	return tok, err
}

// NewToken 生成一个伪随机 token（hex 编码 32 字节）。
func NewToken() (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw), nil
}

// ---- 笔记同步 ----

// NoteRow 表示服务端笔记的权威状态。
type NoteRow struct {
	ID              string
	Title           string
	ContentMarkdown string
	Version         int
	IsDeleted       bool
	UpdatedAt       time.Time
}

// UpdatedSince 返回 updated_at > since 的所有笔记（增量拉取）。
func (s *Store) UpdatedSince(since time.Time) ([]NoteRow, error) {
	rows, err := s.db.Query(
		`SELECT id, title, content_markdown, version, is_deleted, updated_at
		 FROM notes WHERE updated_at > ? ORDER BY updated_at`,
		since.UTC().Format(time.RFC3339),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []NoteRow
	for rows.Next() {
		var r NoteRow
		var del int
		var ts string
		if err := rows.Scan(&r.ID, &r.Title, &r.ContentMarkdown, &r.Version, &del, &ts); err != nil {
			return nil, err
		}
		r.IsDeleted = del != 0
		r.UpdatedAt = parseTime(ts)
		out = append(out, r)
	}
	return out, rows.Err()
}

// GetNote 返回指定笔记的服务端状态。
func (s *Store) GetNote(id string) (*NoteRow, error) {
	var r NoteRow
	var del int
	var ts string
	err := s.db.QueryRow(
		`SELECT id, title, content_markdown, version, is_deleted, updated_at
		 FROM notes WHERE id = ?`, id,
	).Scan(&r.ID, &r.Title, &r.ContentMarkdown, &r.Version, &del, &ts)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	r.IsDeleted = del != 0
	r.UpdatedAt = parseTime(ts)
	return &r, nil
}

// UpsertNote 落库笔记（增量），同时记录一条修订。返回新版本号。
func (s *Store) UpsertNote(noteID, title, content string, isDeleted bool, sourceDevice string, version int) (int, error) {
	ts := time.Now().UTC().Format(time.RFC3339)
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	if err := upsert(tx,
		`INSERT INTO notes (id, title, content_markdown, version, is_deleted, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET
		   title=excluded.title, content_markdown=excluded.content_markdown,
		   version=excluded.version, is_deleted=excluded.is_deleted,
		   updated_at=excluded.updated_at`,
		noteID, title, content, version, b2i(isDeleted), ts,
	); err != nil {
		return 0, err
	}

	revID, _ := NewToken()
	if _, err := tx.Exec(
		`INSERT INTO revisions (id, note_id, version, content_markdown, source_device, is_conflict, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?)`,
		revID[:16], noteID, version, content, sourceDevice, 0, ts,
	); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return version, nil
}

func upsert(tx *sql.Tx, q string, args ...any) error {
	_, err := tx.Exec(q, args...)
	return err
}

// ---- Blob 引用计数 ----

// BlobExists 报告 sha256 是否已存在。
func (s *Store) BlobExists(hash string) (bool, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM blobs WHERE sha256 = ?`, hash).Scan(&n)
	return n > 0, err
}

// AddBlobRef 记录新 blob（幂等），或对已存在的引用计数 +1。返回是否存在。
func (s *Store) AddBlobRef(hash string, size int) (exists bool, err error) {
	existing, err := s.BlobExists(hash)
	if err != nil {
		return false, err
	}
	if existing {
		_, err = s.db.Exec(`UPDATE blobs SET refcount = refcount + 1 WHERE sha256 = ?`, hash)
		return true, err
	}
	_, err = s.db.Exec(
		`INSERT INTO blobs (sha256, size, refcount, created_at) VALUES (?, ?, 1, ?)`,
		hash, size, time.Now().UTC().Format(time.RFC3339),
	)
	return false, err
}

// GC 清理 refcount<=0 的孤儿 blob，返回被清理的 hash。
func (s *Store) GCOrphanBlobs() ([]string, error) {
	rows, err := s.db.Query(`SELECT sha256 FROM blobs WHERE refcount <= 0`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var hashes []string
	for rows.Next() {
		var h string
		if err := rows.Scan(&h); err != nil {
			return nil, err
		}
		hashes = append(hashes, h)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for _, h := range hashes {
		if _, err := s.db.Exec(`DELETE FROM blobs WHERE sha256 = ?`, h); err != nil {
			return nil, err
		}
	}
	return hashes, nil
}

// HashBytes 返回内容 sha256 的 hex。
func HashBytes(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// ---- helpers ----

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

func parseTime(s string) time.Time {
	t, _ := time.Parse(time.RFC3339, s)
	return t
}