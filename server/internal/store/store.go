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
			notebook_id TEXT NOT NULL DEFAULT '', -- 所属笔记本（空表示未分组 / 收件箱）
			version INTEGER NOT NULL DEFAULT 0,   -- 服务端权威版本线
			is_deleted INTEGER NOT NULL DEFAULT 0, -- 墓碑
			source_device TEXT NOT NULL DEFAULT '', -- 最近一次修改的来源设备
			updated_at TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS revisions (
			id TEXT PRIMARY KEY,
			note_id TEXT NOT NULL,
			version INTEGER NOT NULL,
			title TEXT NOT NULL DEFAULT '',
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
		`CREATE TABLE IF NOT EXISTS attachments (
			id TEXT PRIMARY KEY,
			note_id TEXT NOT NULL,
			filename TEXT NOT NULL DEFAULT '',
			mime_kind TEXT NOT NULL DEFAULT '',
			byte_size INTEGER NOT NULL DEFAULT 0,
			sha256 TEXT NOT NULL DEFAULT '',
			storage_ref TEXT NOT NULL DEFAULT '',
			thumbnail_ref TEXT NOT NULL DEFAULT '',
			embedded_pos INTEGER NOT NULL DEFAULT 0,
			is_deleted INTEGER NOT NULL DEFAULT 0,
			created_at TEXT NOT NULL,
			updated_at TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS notebooks (
			id TEXT PRIMARY KEY,
			parent_id TEXT NOT NULL DEFAULT '',
			name TEXT NOT NULL DEFAULT '',
			sort_order INTEGER NOT NULL DEFAULT 0,
			is_deleted INTEGER NOT NULL DEFAULT 0,
			version INTEGER NOT NULL DEFAULT 0,
			source_device TEXT NOT NULL DEFAULT '',
			created_at TEXT NOT NULL,
			updated_at TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS tags (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL DEFAULT '',
			is_deleted INTEGER NOT NULL DEFAULT 0,
			version INTEGER NOT NULL DEFAULT 0,
			source_device TEXT NOT NULL DEFAULT '',
			created_at TEXT NOT NULL,
			updated_at TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS note_tags (
			note_id TEXT NOT NULL,
			tag_id TEXT NOT NULL,
			PRIMARY KEY (note_id, tag_id)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_notes_updated ON notes(updated_at)`,
		`CREATE INDEX IF NOT EXISTS idx_revisions_note ON revisions(note_id)`,
		`CREATE INDEX IF NOT EXISTS idx_revisions_note_ver ON revisions(note_id, version DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_notes_isdel ON notes(is_deleted, updated_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_attachments_note ON attachments(note_id)`,
		`CREATE INDEX IF NOT EXISTS idx_notebooks_updated ON notebooks(updated_at)`,
		`CREATE INDEX IF NOT EXISTS idx_tags_updated ON tags(updated_at)`,
		`CREATE INDEX IF NOT EXISTS idx_note_tags_note ON note_tags(note_id)`,
		`CREATE INDEX IF NOT EXISTS idx_note_tags_tag ON note_tags(tag_id)`,
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

// LoginUser 验证用户名密码，成功则生成并返回新 token。
func (s *Store) LoginUser(username, passwordHash string) (string, error) {
	var storedHash string
	err := s.db.QueryRow(
		`SELECT password_hash FROM users WHERE username = ?`, username,
	).Scan(&storedHash)
	if err != nil {
		return "", errors.New("user not found")
	}
	if storedHash != passwordHash {
		return "", errors.New("wrong password")
	}
	tok, _ := NewToken()
	_, err = s.db.Exec(`UPDATE users SET token = ? WHERE username = ?`, tok, username)
	if err != nil {
		return "", err
	}
	return tok, nil
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
	NotebookID      string
	Version         int
	IsDeleted       bool
	SourceDevice    string
	UpdatedAt       time.Time
}

// UpdatedSince 返回 updated_at > since 的所有笔记（增量拉取）。
func (s *Store) UpdatedSince(since time.Time) ([]NoteRow, error) {
	rows, err := s.db.Query(
		`SELECT id, title, content_markdown, notebook_id, version, is_deleted, source_device, updated_at
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
		if err := rows.Scan(&r.ID, &r.Title, &r.ContentMarkdown, &r.NotebookID, &r.Version, &del, &r.SourceDevice, &ts); err != nil {
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
		`SELECT id, title, content_markdown, notebook_id, version, is_deleted, source_device, updated_at
		 FROM notes WHERE id = ?`, id,
	).Scan(&r.ID, &r.Title, &r.ContentMarkdown, &r.NotebookID, &r.Version, &del, &r.SourceDevice, &ts)
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
func (s *Store) UpsertNote(noteID, title, content, notebookID string, isDeleted bool, sourceDevice string, version int) (int, error) {
	ts := time.Now().UTC().Format(time.RFC3339)
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	if err := upsert(tx,
		`INSERT INTO notes (id, title, content_markdown, notebook_id, version, is_deleted, source_device, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET
		   title=excluded.title, content_markdown=excluded.content_markdown,
		   notebook_id=excluded.notebook_id,
		   version=excluded.version, is_deleted=excluded.is_deleted,
		   source_device=excluded.source_device,
		   updated_at=excluded.updated_at`,
		noteID, title, content, notebookID, version, b2i(isDeleted), sourceDevice, ts,
	); err != nil {
		return 0, err
	}

	revID, _ := NewToken()
	if _, err := tx.Exec(
		`INSERT INTO revisions (id, note_id, version, title, content_markdown, source_device, is_conflict, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		revID[:16], noteID, version, title, content, sourceDevice, 0, ts,
	); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return version, nil
}

// ---- 笔记本分组 / 标签同步 ----

// NotebookRow 表示服务端笔记本分组的权威状态。
//
// 与笔记共用同一套版本线语义：version 为服务端权威版本，is_deleted 为墓碑，
// source_device 记录最近一次修改的来源设备，用于跨端增量收敛。
type NotebookRow struct {
	ID           string
	ParentID     string
	Name         string
	SortOrder    int
	IsDeleted    bool
	Version      int
	SourceDevice string
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

// TagRow 表示服务端标签的权威状态。
type TagRow struct {
	ID           string
	Name         string
	IsDeleted    bool
	Version      int
	SourceDevice string
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

// UpdatedNotebooksSince 返回 updated_at > since 的笔记本分组（增量拉取，含墓碑）。
func (s *Store) UpdatedNotebooksSince(since time.Time) ([]NotebookRow, error) {
	rows, err := s.db.Query(
		`SELECT id, parent_id, name, sort_order, is_deleted, version, source_device, created_at, updated_at
		 FROM notebooks WHERE updated_at > ? ORDER BY updated_at`,
		since.UTC().Format(time.RFC3339),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []NotebookRow
	for rows.Next() {
		var r NotebookRow
		var del int
		var created, updated string
		if err := rows.Scan(&r.ID, &r.ParentID, &r.Name, &r.SortOrder, &del, &r.Version, &r.SourceDevice, &created, &updated); err != nil {
			return nil, err
		}
		r.IsDeleted = del != 0
		r.CreatedAt = parseTime(created)
		r.UpdatedAt = parseTime(updated)
		out = append(out, r)
	}
	return out, rows.Err()
}

// GetNotebook 返回指定笔记本分组的服务端状态（不存在返回 nil, nil）。
func (s *Store) GetNotebook(id string) (*NotebookRow, error) {
	var r NotebookRow
	var del int
	var created, updated string
	err := s.db.QueryRow(
		`SELECT id, parent_id, name, sort_order, is_deleted, version, source_device, created_at, updated_at
		 FROM notebooks WHERE id = ?`, id,
	).Scan(&r.ID, &r.ParentID, &r.Name, &r.SortOrder, &del, &r.Version, &r.SourceDevice, &created, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	r.IsDeleted = del != 0
	r.CreatedAt = parseTime(created)
	r.UpdatedAt = parseTime(updated)
	return &r, nil
}

// UpsertNotebook 落库笔记本分组（增量）。created_at 只在首次插入时写入，
// 冲突更新时不覆盖，保持分组创建时间稳定。
func (s *Store) UpsertNotebook(id, parentID, name string, sortOrder int, isDeleted bool, sourceDevice string, version int) error {
	ts := time.Now().UTC().Format(time.RFC3339)
	return upsert(s.db,
		`INSERT INTO notebooks (id, parent_id, name, sort_order, is_deleted, version, source_device, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET
		   parent_id=excluded.parent_id, name=excluded.name, sort_order=excluded.sort_order,
		   is_deleted=excluded.is_deleted, version=excluded.version,
		   source_device=excluded.source_device, updated_at=excluded.updated_at`,
		id, parentID, name, sortOrder, b2i(isDeleted), version, sourceDevice, ts, ts,
	)
}

// UpdatedTagsSince 返回 updated_at > since 的标签（增量拉取，含墓碑）。
func (s *Store) UpdatedTagsSince(since time.Time) ([]TagRow, error) {
	rows, err := s.db.Query(
		`SELECT id, name, is_deleted, version, source_device, created_at, updated_at
		 FROM tags WHERE updated_at > ? ORDER BY updated_at`,
		since.UTC().Format(time.RFC3339),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TagRow
	for rows.Next() {
		var r TagRow
		var del int
		var created, updated string
		if err := rows.Scan(&r.ID, &r.Name, &del, &r.Version, &r.SourceDevice, &created, &updated); err != nil {
			return nil, err
		}
		r.IsDeleted = del != 0
		r.CreatedAt = parseTime(created)
		r.UpdatedAt = parseTime(updated)
		out = append(out, r)
	}
	return out, rows.Err()
}

// GetTag 返回指定标签的服务端状态（不存在返回 nil, nil）。
func (s *Store) GetTag(id string) (*TagRow, error) {
	var r TagRow
	var del int
	var created, updated string
	err := s.db.QueryRow(
		`SELECT id, name, is_deleted, version, source_device, created_at, updated_at
		 FROM tags WHERE id = ?`, id,
	).Scan(&r.ID, &r.Name, &del, &r.Version, &r.SourceDevice, &created, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	r.IsDeleted = del != 0
	r.CreatedAt = parseTime(created)
	r.UpdatedAt = parseTime(updated)
	return &r, nil
}

// UpsertTag 落库标签（增量）。created_at 只在首次插入时写入。
func (s *Store) UpsertTag(id, name string, isDeleted bool, sourceDevice string, version int) error {
	ts := time.Now().UTC().Format(time.RFC3339)
	return upsert(s.db,
		`INSERT INTO tags (id, name, is_deleted, version, source_device, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET
		   name=excluded.name, is_deleted=excluded.is_deleted, version=excluded.version,
		   source_device=excluded.source_device, updated_at=excluded.updated_at`,
		id, name, b2i(isDeleted), version, sourceDevice, ts, ts,
	)
}

// SyncNoteTags 以笔记为粒度整体替换其标签关联（先清后插，幂等）。
//
// 关联集合随所属笔记的版本线一起流动，因此本身不需要独立时间戳：
// 客户端只有在笔记被接受时才提交 tagIds，服务端整体替换即可收敛。
func (s *Store) SyncNoteTags(noteID string, tagIDs []string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM note_tags WHERE note_id = ?`, noteID); err != nil {
		return err
	}
	seen := map[string]bool{}
	for _, tagID := range tagIDs {
		if tagID == "" || seen[tagID] {
			continue
		}
		seen[tagID] = true
		if err := upsert(tx, `INSERT INTO note_tags (note_id, tag_id) VALUES (?, ?)`, noteID, tagID); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// ListNoteTagsForNotes 批量取多篇笔记的标签 id，按 note_id 分组（供随笔记下发）。
func (s *Store) ListNoteTagsForNotes(noteIDs []string) (map[string][]string, error) {
	out := map[string][]string{}
	if len(noteIDs) == 0 {
		return out, nil
	}
	args := make([]any, len(noteIDs))
	for i, id := range noteIDs {
		args[i] = id
	}
	rows, err := s.db.Query(
		`SELECT note_id, tag_id FROM note_tags WHERE note_id IN (`+placeholders(len(noteIDs))+`) ORDER BY note_id, tag_id`,
		args...,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var noteID, tagID string
		if err := rows.Scan(&noteID, &tagID); err != nil {
			return nil, err
		}
		out[noteID] = append(out[noteID], tagID)
	}
	return out, rows.Err()
}

// ---- 修订历史 ----

// RevisionRow 表示一条历史修订。
type RevisionRow struct {
	ID              string
	NoteID          string
	Version         int
	Title           string
	ContentMarkdown string
	SourceDevice    string
	IsConflict      bool
	CreatedAt       time.Time
}

// ListRevisions 返回指定笔记的修订列表，按 version 降序。
func (s *Store) ListRevisions(noteID string, limit int) ([]RevisionRow, error) {
	if limit <= 0 {
		limit = 50
	}
	rows, err := s.db.Query(
		`SELECT id, note_id, version, title, content_markdown, source_device, is_conflict, created_at
		 FROM revisions WHERE note_id = ? ORDER BY version DESC LIMIT ?`,
		noteID, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []RevisionRow
	for rows.Next() {
		var r RevisionRow
		var conf int
		var ts string
		if err := rows.Scan(&r.ID, &r.NoteID, &r.Version, &r.Title, &r.ContentMarkdown, &r.SourceDevice, &conf, &ts); err != nil {
			return nil, err
		}
		r.IsConflict = conf != 0
		r.CreatedAt = parseTime(ts)
		out = append(out, r)
	}
	return out, rows.Err()
}

// GetRevision 获取指定版本的修订。
func (s *Store) GetRevision(noteID string, version int) (*RevisionRow, error) {
	var r RevisionRow
	var conf int
	var ts string
	err := s.db.QueryRow(
		`SELECT id, note_id, version, title, content_markdown, source_device, is_conflict, created_at
		 FROM revisions WHERE note_id = ? AND version = ?`,
		noteID, version,
	).Scan(&r.ID, &r.NoteID, &r.Version, &r.Title, &r.ContentMarkdown, &r.SourceDevice, &conf, &ts)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	r.IsConflict = conf != 0
	r.CreatedAt = parseTime(ts)
	return &r, nil
}

// ---- 附件映射 ----

// AttachmentRow 表示服务端附件元数据。字节存 Blob（sha256 内容寻址），
// 这里只存映射与引用，因此可随笔记一起全量交换（数据极小）。
type AttachmentRow struct {
	ID           string
	NoteID       string
	Filename     string
	MimeKind     string
	ByteSize     int
	SHA256       string
	StorageRef   string
	ThumbnailRef string
	EmbeddedPos  int
	IsDeleted    bool
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

const attachmentCols = `id, note_id, filename, mime_kind, byte_size, sha256,
	storage_ref, thumbnail_ref, embedded_pos, is_deleted, created_at, updated_at`

func scanAttachment(scan func(dest ...any) error) (AttachmentRow, error) {
	var a AttachmentRow
	var del int
	var created, updated string
	if err := scan(&a.ID, &a.NoteID, &a.Filename, &a.MimeKind, &a.ByteSize, &a.SHA256,
		&a.StorageRef, &a.ThumbnailRef, &a.EmbeddedPos, &del, &created, &updated); err != nil {
		return a, err
	}
	a.IsDeleted = del != 0
	a.CreatedAt = parseTime(created)
	a.UpdatedAt = parseTime(updated)
	return a, nil
}

// ListAttachments 返回指定笔记的全部附件映射（含墓碑，供客户端收敛删除）。
func (s *Store) ListAttachments(noteID string) ([]AttachmentRow, error) {
	rows, err := s.db.Query(
		`SELECT `+attachmentCols+` FROM attachments WHERE note_id = ? ORDER BY embedded_pos, id`,
		noteID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AttachmentRow
	for rows.Next() {
		a, err := scanAttachment(rows.Scan)
		if err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// ListAttachmentsForNotes 批量取多篇笔记的附件映射，按 note_id 分组。
func (s *Store) ListAttachmentsForNotes(noteIDs []string) (map[string][]AttachmentRow, error) {
	out := map[string][]AttachmentRow{}
	if len(noteIDs) == 0 {
		return out, nil
	}
	args := make([]any, len(noteIDs))
	for i, id := range noteIDs {
		args[i] = id
	}
	q := `SELECT ` + attachmentCols + ` FROM attachments WHERE note_id IN (` +
		placeholders(len(noteIDs)) + `) ORDER BY note_id, embedded_pos, id`
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		a, err := scanAttachment(rows.Scan)
		if err != nil {
			return nil, err
		}
		out[a.NoteID] = append(out[a.NoteID], a)
	}
	return out, rows.Err()
}

// SyncAttachments 以 id 为键 upsert 一篇笔记的附件映射，并维护 blobs 引用计数。
//
// 引用计数语义：refcount = 指向该 sha256 的「有效」附件映射条数。
// 新增有效映射 +1；映射被墓碑化 -1；同一映射改指另一个 sha256 则旧 -1 新 +1。
// 计数只增不减的重复推送因此是幂等的。
func (s *Store) SyncAttachments(noteID string, items []AttachmentRow) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	ts := time.Now().UTC().Format(time.RFC3339)
	for _, it := range items {
		var prevHash string
		var prevDel int
		prevErr := tx.QueryRow(
			`SELECT sha256, is_deleted FROM attachments WHERE id = ?`, it.ID,
		).Scan(&prevHash, &prevDel)

		created := it.CreatedAt
		if created.IsZero() {
			created = time.Now()
		}
		if _, err := tx.Exec(
			`INSERT INTO attachments (`+attachmentCols+`)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			 ON CONFLICT(id) DO UPDATE SET
			   note_id=excluded.note_id, filename=excluded.filename,
			   mime_kind=excluded.mime_kind, byte_size=excluded.byte_size,
			   sha256=excluded.sha256, storage_ref=excluded.storage_ref,
			   thumbnail_ref=excluded.thumbnail_ref, embedded_pos=excluded.embedded_pos,
			   is_deleted=excluded.is_deleted, updated_at=excluded.updated_at`,
			it.ID, noteID, it.Filename, it.MimeKind, it.ByteSize, it.SHA256,
			it.StorageRef, it.ThumbnailRef, it.EmbeddedPos, b2i(it.IsDeleted),
			created.UTC().Format(time.RFC3339), ts,
		); err != nil {
			return err
		}

		wasActive := prevErr == nil && prevDel == 0 && prevHash != ""
		nowActive := !it.IsDeleted && it.SHA256 != ""
		switch {
		case !wasActive && nowActive:
			if err := adjustBlobRef(tx, it.SHA256, +1, it.ByteSize); err != nil {
				return err
			}
		case wasActive && !nowActive:
			if err := adjustBlobRef(tx, prevHash, -1, 0); err != nil {
				return err
			}
		case wasActive && nowActive && prevHash != it.SHA256:
			if err := adjustBlobRef(tx, prevHash, -1, 0); err != nil {
				return err
			}
			if err := adjustBlobRef(tx, it.SHA256, +1, it.ByteSize); err != nil {
				return err
			}
		}
	}
	return tx.Commit()
}

// adjustBlobRef 在事务内调整 blob 引用计数（不存在且 delta>0 时补建记录）。
func adjustBlobRef(tx *sql.Tx, hash string, delta, size int) error {
	if hash == "" || delta == 0 {
		return nil
	}
	var n int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM blobs WHERE sha256 = ?`, hash).Scan(&n); err != nil {
		return err
	}
	if n == 0 {
		if delta < 0 {
			return nil
		}
		_, err := tx.Exec(
			`INSERT INTO blobs (sha256, size, refcount, created_at) VALUES (?, ?, ?, ?)`,
			hash, size, delta, time.Now().UTC().Format(time.RFC3339),
		)
		return err
	}
	_, err := tx.Exec(
		`UPDATE blobs SET refcount = MAX(0, refcount + ?) WHERE sha256 = ?`, delta, hash,
	)
	return err
}

func placeholders(n int) string {
	if n <= 0 {
		return ""
	}
	out := "?"
	for i := 1; i < n; i++ {
		out += ",?"
	}
	return out
}

// execer 抽象 *sql.DB 与 *sql.Tx 的共同写入能力，
// 使 upsert 既能用于事务内多条语句，也能用于单条直写。
type execer interface {
	Exec(query string, args ...any) (sql.Result, error)
}

func upsert(e execer, q string, args ...any) error {
	_, err := e.Exec(q, args...)
	return err
}

// ---- Blob 引用计数 ----

// BlobExists 报告 sha256 是否已存在。
func (s *Store) BlobExists(hash string) (bool, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM blobs WHERE sha256 = ?`, hash).Scan(&n)
	return n > 0, err
}

// EnsureBlob 登记 blob 记录（幂等），返回此前是否已存在。
//
// 引用计数不在这里维护：refcount 唯一来源是附件映射（见 [Store.SyncAttachments]），
// 否则「上传字节」与「挂载附件」会对同一 blob 重复计数。
func (s *Store) EnsureBlob(hash string, size int) (exists bool, err error) {
	existing, err := s.BlobExists(hash)
	if err != nil {
		return false, err
	}
	if existing {
		return true, nil
	}
	_, err = s.db.Exec(
		`INSERT INTO blobs (sha256, size, refcount, created_at) VALUES (?, ?, 0, ?)`,
		hash, size, time.Now().UTC().Format(time.RFC3339),
	)
	return false, err
}

// BlobRefCount 返回 blob 当前引用计数（不存在返回 0）。
func (s *Store) BlobRefCount(hash string) (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT refcount FROM blobs WHERE sha256 = ?`, hash).Scan(&n)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	return n, err
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
