// Package store 提供 Sui 服务端的数据访问层（SQLite）。
//
// 服务端元数据表与客户端共享 schema 对齐（notes 公共字段），并保留服务端
// 私有状态（version 权威版本线、墓碑 tombstone、blob refcount）。
package store

import (
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"errors"
	"os"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

// Store 封装服务端 SQLite 连接与数据访问。
type Store struct {
	db *sql.DB
}

// Open 打开（必要时创建）服务端数据库。
func Open(path string) (*Store, error) {
	// 忙等待：驱动默认 busy_timeout=0（并发写立即 SQLITE_BUSY）。下面的单连接设置
	// 只保证「一个连接」，并不让并发的写排队等待——等一会儿再失败才是正确语义。
	// 放在 DSN 上而不是 Open 后 Exec：连接被重建时同样生效。
	dsn := path
	sep := "?"
	if strings.Contains(dsn, "?") {
		sep = "&"
	}
	db, err := sql.Open("sqlite", dsn+sep+"_pragma=busy_timeout(5000)")
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
	// M10/ADR-014 决策 8：sessions 由「单一永久 token」演进为「短时访问令牌 + 可撤销刷新令牌」。
	// 老库（存在 token 列 / 缺 access_token_hash 列）整表重建 = 清空既有会话，用户需重新登录一次；
	// 重建后不再满足判定条件，故重启不会再次清空（幂等）。必须在建表语句之前执行。
	if err := s.migrateSessions(); err != nil {
		return err
	}
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS users (
			id TEXT PRIMARY KEY,
			username TEXT NOT NULL UNIQUE,
			password_hash TEXT NOT NULL,
			password_salt TEXT NOT NULL DEFAULT '',
			created_at TEXT NOT NULL
		)`,
		// M10/ADR-014：短时访问令牌 + 可撤销刷新令牌（双令牌，只存哈希）。
		`CREATE TABLE IF NOT EXISTS sessions (
			id TEXT PRIMARY KEY,
			username TEXT NOT NULL,
			access_token_hash TEXT NOT NULL DEFAULT '',
			refresh_token_hash TEXT NOT NULL DEFAULT '',
			prev_refresh_token_hash TEXT NOT NULL DEFAULT '',
			access_expires_at TEXT NOT NULL DEFAULT '',
			refresh_expires_at TEXT NOT NULL DEFAULT '',
			created_at TEXT NOT NULL,
			last_used_at TEXT NOT NULL DEFAULT '',
			revoked_at TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE TABLE IF NOT EXISTS notes (
			id TEXT PRIMARY KEY,
			title TEXT NOT NULL DEFAULT '',
			content_markdown TEXT NOT NULL DEFAULT '',
			notebook_id TEXT NOT NULL DEFAULT '', -- 所属笔记本（空表示未分组 / 收件箱）
			version INTEGER NOT NULL DEFAULT 0,   -- 服务端权威版本线
			is_deleted INTEGER NOT NULL DEFAULT 0, -- 墓碑
			archived INTEGER NOT NULL DEFAULT 0,  -- 归档状态（FR-25）
			source_device TEXT NOT NULL DEFAULT '', -- 最近一次修改的来源设备
			source_url TEXT, -- 剪藏专用幂等键（普通笔记为 NULL，M4/BR-34.3）
			encrypted INTEGER NOT NULL DEFAULT 0, -- M10-T29：所属笔记本是否为加密笔记本（镜像，FR-51）
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
			-- M10-T29（FR-51）：加密笔记本标记 + **非敏感**加密元数据（JSON；不含任何密钥）。
			encrypted INTEGER NOT NULL DEFAULT 0,
			crypto_meta TEXT NOT NULL DEFAULT '',
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
		// M12（FR-55）：实例元数据键值。当前存 `instance_id` —— **云端实例身份**，
		// 用于「换库 / 重建 / 回滚」判定（客户端据此提示用户，而不是静默上传）。
		`CREATE TABLE IF NOT EXISTS meta (
			key TEXT PRIMARY KEY,
			value TEXT NOT NULL,
			updated_at TEXT NOT NULL
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
		`CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(username)`,
		`CREATE INDEX IF NOT EXISTS idx_sessions_access ON sessions(access_token_hash)`,
		`CREATE INDEX IF NOT EXISTS idx_sessions_refresh ON sessions(refresh_token_hash)`,
		`CREATE INDEX IF NOT EXISTS idx_sessions_prev_refresh ON sessions(prev_refresh_token_hash)`,
	}
	for _, st := range stmts {
		if _, err := s.db.Exec(st); err != nil {
			return err
		}
	}
	// FR-25：notes 新增归档状态列。既有库用 PRAGMA 探测 + ALTER TABLE 幂等补列，
	// 新建库的 CREATE TABLE 亦含该列，两条路径都安全。
	if err := s.ensureColumn("notes", "archived", "INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	// M4/BR-36.1：users 幂等补列 password_salt（每用户随机盐），老库不掉数据。
	if err := s.ensureColumn("users", "password_salt", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	// M4/BR-34.3：notes 幂等补列 source_url（剪藏专用幂等键，可空）。
	if err := s.ensureColumn("notes", "source_url", "TEXT"); err != nil {
		return err
	}
	// M10-T29（FR-51）：加密笔记本的标记与非敏感元数据（老库幂等补列，不掉数据）。
	if err := s.ensureColumn("notebooks", "encrypted", "INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	if err := s.ensureColumn("notebooks", "crypto_meta", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("notes", "encrypted", "INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	return nil
}

// migrateSessions 处理 M10 的 sessions 形状演进（ADR-014 决策 8）。
//
// 判定：**存在旧列 `token`** 或 **缺少新列 `access_token_hash`** → 命中即整表重建
// （旧永久 Token 全部失效，用户需重新登录一次）。重建后不再满足判定条件，重复执行安全。
func (s *Store) migrateSessions() error {
	hasOld, err := s.hasColumn("sessions", "token")
	if err != nil {
		return err
	}
	hasNew, err := s.hasColumn("sessions", "access_token_hash")
	if err != nil {
		return err
	}
	if !hasOld && hasNew {
		return nil
	}
	_, err = s.db.Exec(`DROP TABLE IF EXISTS sessions`)
	return err
}

// hasColumn 报告表是否存在指定列（表不存在时返回 false）。
func (s *Store) hasColumn(table, column string) (bool, error) {
	rows, err := s.db.Query(`PRAGMA table_info(` + table + `)`)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	for rows.Next() {
		var cid, notNull, pk int
		var name, colType string
		var dflt sql.NullString
		if err := rows.Scan(&cid, &name, &colType, &notNull, &dflt, &pk); err != nil {
			return false, err
		}
		if name == column {
			return true, nil
		}
	}
	return false, rows.Err()
}

// ensureColumn 幂等补列：已存在则跳过，否则 ALTER TABLE 追加。
// SQLite 无 ADD COLUMN IF NOT EXISTS，故先 PRAGMA table_info 探测，重复执行安全。
func (s *Store) ensureColumn(table, column, decl string) error {
	rows, err := s.db.Query(`PRAGMA table_info(` + table + `)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var cid, notNull, pk int
		var name, colType string
		var dflt sql.NullString
		if err := rows.Scan(&cid, &name, &colType, &notNull, &dflt, &pk); err != nil {
			return err
		}
		if name == column {
			return nil
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if _, err := s.db.Exec(`ALTER TABLE ` + table + ` ADD COLUMN ` + column + ` ` + decl); err != nil {
		return err
	}
	return nil
}

// Close 关闭数据库。
func (s *Store) Close() error { return s.db.Close() }

// ---- 用户 / 设备鉴权 ----

// ---- 会话与令牌（M10：短时访问令牌 + 可撤销刷新令牌，ADR-014 / FR-49）----
//
// 会话以 sessions 表为唯一真源：一个用户可持有多行会话（多设备 / 多 profile）。
// 令牌**只存 sha256 哈希**（BR-49.4），明文仅在签发 / 刷新的响应里出现一次。

// AccessTTL 返回访问令牌有效期（SUI_ACCESS_TTL，默认 30 分钟）。
func AccessTTL() time.Duration { return envDuration("SUI_ACCESS_TTL", 30*time.Minute) }

// RefreshTTL 返回刷新令牌有效期（SUI_REFRESH_TTL，默认 30 天）。
func RefreshTTL() time.Duration { return envDuration("SUI_REFRESH_TTL", 30*24*time.Hour) }

// envDuration 解析时长环境变量；空值 / 非法值 / 非正数一律回落默认值。
func envDuration(key string, def time.Duration) time.Duration {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return def
	}
	d, err := time.ParseDuration(raw)
	if err != nil || d <= 0 {
		return def
	}
	return d
}

// 刷新失败的两类语义（§5：客户端据 error 字段决策重新登录）。
var (
	// ErrRefreshExpired 刷新令牌未命中或已自然过期 → 401 refresh-expired。
	ErrRefreshExpired = errors.New("refresh-expired")
	// ErrRefreshRevoked 刷新令牌已被换发（重放）或会话已吊销 → 401 refresh-revoked。
	ErrRefreshRevoked = errors.New("refresh-revoked")
)

// RefreshRevokedError 是 ErrRefreshRevoked 的具体形态，额外携带**被吊销的会话 id**，
// 供上层关闭该会话的 WebSocket 连接（§4.5：撤销即时生效）。
//
// 同时满足 errors.Is(err, ErrRefreshRevoked) 与 errors.As(err, &RefreshRevokedError{})。
type RefreshRevokedError struct{ SessionID string }

func (e *RefreshRevokedError) Error() string { return "refresh-revoked" }

// Is 让 errors.Is(err, ErrRefreshRevoked) 对具体形态同样成立。
func (e *RefreshRevokedError) Is(target error) bool { return target == ErrRefreshRevoked }

// AuthStatus 是一次访问令牌鉴定的结果（§8.5）。
type AuthStatus int

const (
	// AuthOK：命中且未过期、未吊销。
	AuthOK AuthStatus = iota
	// AuthExpired：命中但访问令牌已过期（客户端应刷新后重试）。
	AuthExpired
	// AuthInvalid：未命中 / 已吊销。
	AuthInvalid
)

// TokenPair 是一次签发的结果（明文不落库）。
type TokenPair struct {
	SessionID     string
	AccessToken   string
	RefreshToken  string
	AccessExpiry  time.Time
	RefreshExpiry time.Time
}

// ExpiresIn 返回访问令牌剩余有效秒数（响应体的 expires_in）。
func (p *TokenPair) ExpiresIn() int {
	secs := int(time.Until(p.AccessExpiry).Seconds())
	if secs < 0 {
		return 0
	}
	return secs
}

// hashToken 计算令牌在库中的存储形态。
func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// CreateSession 为该用户签发一个新会话（登录 / 注册，§8.2）。
//
// 只**新增**一行，不影响该用户其他会话（BR-07.1 / BR-33.3）。顺带清理已失效会话行
// （治理用途，不影响正确性）。
func (s *Store) CreateSession(username string) (*TokenPair, error) {
	access, err := NewToken()
	if err != nil {
		return nil, err
	}
	refresh, err := NewToken()
	if err != nil {
		return nil, err
	}
	id, err := NewToken()
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	pair := &TokenPair{
		SessionID:     id[:32],
		AccessToken:   access,
		RefreshToken:  refresh,
		AccessExpiry:  now.Add(AccessTTL()),
		RefreshExpiry: now.Add(RefreshTTL()),
	}
	if _, err := s.db.Exec(
		`INSERT INTO sessions (id, username, access_token_hash, refresh_token_hash,
			prev_refresh_token_hash, access_expires_at, refresh_expires_at, created_at, last_used_at, revoked_at)
		 VALUES (?, ?, ?, ?, '', ?, ?, ?, ?, '')`,
		pair.SessionID, username, hashToken(access), hashToken(refresh),
		pair.AccessExpiry.Format(time.RFC3339), pair.RefreshExpiry.Format(time.RFC3339),
		now.Format(time.RFC3339), now.Format(time.RFC3339),
	); err != nil {
		return nil, err
	}
	_ = s.CleanupExpiredSessions()
	return pair, nil
}

// Authenticate 以访问令牌鉴定会话（§8.5）：命中且未过期未吊销 → 更新 last_used_at。
//
// 返回（结果, 用户名, 会话 id）；后两者仅在 AuthOK 时有效。
func (s *Store) Authenticate(accessToken string) (AuthStatus, string, string) {
	if accessToken == "" {
		return AuthInvalid, "", ""
	}
	var id, username, expiresAt, revokedAt, lastUsed string
	err := s.db.QueryRow(
		`SELECT id, username, access_expires_at, revoked_at, last_used_at
		 FROM sessions WHERE access_token_hash = ?`,
		hashToken(accessToken),
	).Scan(&id, &username, &expiresAt, &revokedAt, &lastUsed)
	if err != nil || revokedAt != "" {
		// 未命中 / 已吊销：对外一律 invalid_token（§8.5，不区分内部原因）。
		return AuthInvalid, "", ""
	}
	if !parseTime(expiresAt).After(time.Now().UTC()) {
		return AuthExpired, username, id
	}
	// last_used_at 只做**节流**更新：鉴权是热路径（轮询接口每请求一次），
	// 每次都写会在单写 SQLite 上与同步事务争用，而审计并不需要秒级精度。
	if time.Since(parseTime(lastUsed)) >= lastUsedThrottle {
		_, _ = s.db.Exec(`UPDATE sessions SET last_used_at = ? WHERE id = ?`,
			time.Now().UTC().Format(time.RFC3339), id)
	}
	return AuthOK, username, id
}

// lastUsedThrottle 是 last_used_at 的最小更新间隔（审计精度 vs 写放大）。
const lastUsedThrottle = 60 * time.Second

// RefreshSession 以刷新令牌轮换出新的双令牌（§8.3，单次使用 + 重放即吊销）。
func (s *Store) RefreshSession(refreshToken string) (*TokenPair, error) {
	if refreshToken == "" {
		return nil, ErrRefreshExpired
	}
	h := hashToken(refreshToken)
	var id, username, curHash, prevHash, refreshExp, revokedAt string
	err := s.db.QueryRow(
		`SELECT id, username, refresh_token_hash, prev_refresh_token_hash, refresh_expires_at, revoked_at
		 FROM sessions WHERE refresh_token_hash = ? OR prev_refresh_token_hash = ?`,
		h, h,
	).Scan(&id, &username, &curHash, &prevHash, &refreshExp, &revokedAt)
	if err != nil {
		// 两个哈希都未命中：不区分「从未存在」与「更早世代」（§8.3 已知边界）。
		return nil, ErrRefreshExpired
	}
	if revokedAt != "" || (prevHash != "" && prevHash == h) {
		// 已吊销，或该令牌**已被换发过**（重放 = 凭证泄漏）→ 吊销整个会话（fail-safe）。
		if _, err := s.db.Exec(`UPDATE sessions SET revoked_at = ? WHERE id = ?`,
			time.Now().UTC().Format(time.RFC3339), id); err != nil {
			return nil, err
		}
		return nil, &RefreshRevokedError{SessionID: id}
	}
	if !parseTime(refreshExp).After(time.Now().UTC()) {
		// 自然过期：不额外吊销（该会话已不可用）。
		return nil, ErrRefreshExpired
	}
	newAccess, err := NewToken()
	if err != nil {
		return nil, err
	}
	newRefresh, err := NewToken()
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	pair := &TokenPair{
		SessionID:     id,
		AccessToken:   newAccess,
		RefreshToken:  newRefresh,
		AccessExpiry:  now.Add(AccessTTL()),
		RefreshExpiry: now.Add(RefreshTTL()),
	}
	if _, err := s.db.Exec(
		`UPDATE sessions SET access_token_hash = ?, refresh_token_hash = ?,
			prev_refresh_token_hash = ?, access_expires_at = ?, refresh_expires_at = ?, last_used_at = ?
		 WHERE id = ?`,
		hashToken(newAccess), hashToken(newRefresh), curHash,
		pair.AccessExpiry.Format(time.RFC3339), pair.RefreshExpiry.Format(time.RFC3339),
		now.Format(time.RFC3339), id,
	); err != nil {
		return nil, err
	}
	return pair, nil
}

// RevokeSessionByAccess 登出：吊销当前访问令牌所属会话，返回其 sessionID（供关闭 WS 连接）。
//
// 未命中（令牌本就无效）时返回空 id 且不报错——登出是幂等的。
func (s *Store) RevokeSessionByAccess(accessToken string) (string, error) {
	if accessToken == "" {
		return "", nil
	}
	var id string
	if err := s.db.QueryRow(`SELECT id FROM sessions WHERE access_token_hash = ?`,
		hashToken(accessToken)).Scan(&id); err != nil {
		return "", nil
	}
	_, err := s.db.Exec(`UPDATE sessions SET revoked_at = ? WHERE id = ?`,
		time.Now().UTC().Format(time.RFC3339), id)
	return id, err
}

// RevokeAllSessions 吊销该用户全部会话（logout-all，§8.4），返回被吊销的 sessionID。
func (s *Store) RevokeAllSessions(username string) ([]string, error) {
	rows, err := s.db.Query(`SELECT id FROM sessions WHERE username = ? AND revoked_at = ''`, username)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	ts := time.Now().UTC().Format(time.RFC3339)
	for _, id := range ids {
		if _, err := s.db.Exec(`UPDATE sessions SET revoked_at = ? WHERE id = ?`, ts, id); err != nil {
			return nil, err
		}
	}
	return ids, nil
}

// CleanupExpiredSessions 删除刷新令牌已过期的历史会话行（治理，非正确性所需）。
func (s *Store) CleanupExpiredSessions() error {
	_, err := s.db.Exec(`DELETE FROM sessions WHERE refresh_expires_at != '' AND refresh_expires_at < ?`,
		time.Now().UTC().Format(time.RFC3339))
	return err
}

// passwordIterations 为 PBKDF2 迭代次数（M4/BR-36.1）。
const passwordIterations = 100000

// HashPassword 以 PBKDF2-HMAC-SHA256 + 每用户随机盐派生密码摘要（M4/BR-36.1）。
// 返回十六进制编码的 salt 与 hash。
func HashPassword(password string) (salt, hash string, err error) {
	raw := make([]byte, 16)
	if _, err = rand.Read(raw); err != nil {
		return "", "", err
	}
	key, err := pbkdf2.Key(sha256.New, password, raw, passwordIterations, 32)
	if err != nil {
		return "", "", err
	}
	return hex.EncodeToString(raw), hex.EncodeToString(key), nil
}

// verifyPassword 以常量时间比较校验密码（M4/BR-36.1）。
func verifyPassword(password, saltHex, hashHex string) bool {
	salt, err := hex.DecodeString(saltHex)
	if err != nil {
		return false
	}
	want, err := hex.DecodeString(hashHex)
	if err != nil {
		return false
	}
	got, err := pbkdf2.Key(sha256.New, password, salt, passwordIterations, len(want))
	if err != nil {
		return false
	}
	return subtle.ConstantTimeCompare(got, want) == 1
}

// HasAnyUser 报告实例是否已有用户（单用户实例注册网关判定，M4/BR-33.2）。
func (s *Store) HasAnyUser() (bool, error) {
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(1) FROM users`).Scan(&n); err != nil {
		return false, err
	}
	return n > 0, nil
}

// CreateUser 创建用户并签发首个会话（密码以 PBKDF2 哈希存储；M10 起返回双令牌，§8.2）。
//
// 用户行单条 INSERT 自身即原子；会话行在用户落库后创建——若会话创建失败，用户仍可正常登录。
func (s *Store) CreateUser(username, password string) (*TokenPair, error) {
	salt, hash, err := HashPassword(password)
	if err != nil {
		return nil, err
	}
	id, _ := NewToken()
	ts := time.Now().UTC().Format(time.RFC3339)
	if _, err = s.db.Exec(
		`INSERT INTO users (id, username, password_hash, password_salt, created_at) VALUES (?, ?, ?, ?, ?)`,
		id[:16], username, hash, salt, ts,
	); err != nil {
		return nil, err
	}
	return s.CreateSession(username)
}

// LoginUser 验证用户名密码，成功则新增一个独立会话并返回新令牌对（§8.2）。
//
// 登录只追加会话行，不影响该用户其他已登录会话（多设备 / 多 profile 可同时在线）。
// M4/BR-36.2：若命中旧明文前缀实现（"plain:"），校验通过后顺手幂等升级为 PBKDF2 哈希。
func (s *Store) LoginUser(username, password string) (*TokenPair, error) {
	var storedHash, salt string
	err := s.db.QueryRow(
		`SELECT password_hash, password_salt FROM users WHERE username = ?`, username,
	).Scan(&storedHash, &salt)
	if err != nil {
		return nil, errors.New("user not found")
	}
	if strings.HasPrefix(storedHash, "plain:") {
		if storedHash != "plain:"+password {
			return nil, errors.New("wrong password")
		}
		if newSalt, newHash, herr := HashPassword(password); herr == nil {
			_, _ = s.db.Exec(
				`UPDATE users SET password_hash = ?, password_salt = ? WHERE username = ?`,
				newHash, newSalt, username,
			)
		}
	} else if !verifyPassword(password, salt, storedHash) {
		return nil, errors.New("wrong password")
	}
	return s.CreateSession(username)
}

// NewToken 生成一个伪随机 token（hex 编码 32 字节）。
func NewToken() (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw), nil
}

// InstanceID 返回本实例的**云端实例身份**（首次调用生成并持久化，此后恒定）。
//
// M12 / FR-55（ADR-019 决策 4）：同一数据目录内保持稳定；**更换数据目录 / 重建库必然变化**，
// 客户端据此识别「云端数据已更换」并要求用户决策（用本地补齐 / 以云端为准），
// 而不是静默上传或静默清库。该值**非敏感**（不含任何密钥），但仅在鉴权后返回。
func (s *Store) InstanceID() (string, error) {
	var id string
	err := s.db.QueryRow(`SELECT value FROM meta WHERE key = 'instance_id'`).Scan(&id)
	if err == nil && id != "" {
		return id, nil
	}
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	fresh := "inst-" + hex.EncodeToString(raw)
	// 并发首次调用：冲突即放弃写入，随后重读已有值，保证身份唯一且稳定。
	if _, err := s.db.Exec(
		`INSERT INTO meta (key, value, updated_at) VALUES ('instance_id', ?, ?)
		 ON CONFLICT(key) DO NOTHING`,
		fresh, time.Now().UTC().Format(time.RFC3339),
	); err != nil {
		return "", err
	}
	if err := s.db.QueryRow(`SELECT value FROM meta WHERE key = 'instance_id'`).Scan(&id); err != nil {
		return "", err
	}
	return id, nil
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
	Archived        bool
	// Encrypted 表示该笔记所属笔记本是否为加密笔记本（M10-T29；正文 / 标题届时为密文）。
	Encrypted    bool
	SourceDevice string
	SourceURL    string
	UpdatedAt    time.Time
}

// UpdatedSince 返回 updated_at > since 的所有笔记（增量拉取）。
func (s *Store) UpdatedSince(since time.Time) ([]NoteRow, error) {
	rows, err := s.db.Query(
		`SELECT id, title, content_markdown, notebook_id, version, is_deleted, archived, encrypted, source_device, updated_at
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
		var del, arch, enc int
		var ts string
		if err := rows.Scan(&r.ID, &r.Title, &r.ContentMarkdown, &r.NotebookID, &r.Version, &del, &arch, &enc, &r.SourceDevice, &ts); err != nil {
			return nil, err
		}
		r.IsDeleted = del != 0
		r.Archived = arch != 0
		r.Encrypted = enc != 0
		r.UpdatedAt = parseTime(ts)
		out = append(out, r)
	}
	return out, rows.Err()
}

// GetNote 返回指定笔记的服务端状态。
func (s *Store) GetNote(id string) (*NoteRow, error) {
	var r NoteRow
	var del, arch, enc int
	var srcURL sql.NullString
	var ts string
	err := s.db.QueryRow(
		`SELECT id, title, content_markdown, notebook_id, version, is_deleted, archived, encrypted, source_device, source_url, updated_at
		 FROM notes WHERE id = ?`, id,
	).Scan(&r.ID, &r.Title, &r.ContentMarkdown, &r.NotebookID, &r.Version, &del, &arch, &enc, &r.SourceDevice, &srcURL, &ts)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	r.IsDeleted = del != 0
	r.Archived = arch != 0
	r.Encrypted = enc != 0
	r.SourceURL = srcURL.String
	r.UpdatedAt = parseTime(ts)
	return &r, nil
}

// GetNoteBySourceURL 按剪藏幂等键查既有笔记 id（M4/BR-34.3）；无命中返回 ""。
func (s *Store) GetNoteBySourceURL(sourceURL string) (string, error) {
	if sourceURL == "" {
		return "", nil
	}
	var id string
	err := s.db.QueryRow(
		`SELECT id FROM notes WHERE source_url = ? LIMIT 1`, sourceURL,
	).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return id, nil
}

// SetNoteSourceURL 为剪藏笔记登记幂等键；不覆盖已有的其它归属（M4/BR-34.3）。
func (s *Store) SetNoteSourceURL(noteID, sourceURL string) error {
	if sourceURL == "" {
		return nil
	}
	_, err := s.db.Exec(
		`UPDATE notes SET source_url = ? WHERE id = ? AND (source_url IS NULL OR source_url = '')`,
		sourceURL, noteID,
	)
	return err
}

// UpsertNote 落库笔记（增量），同时记录一条修订。返回新版本号。
func (s *Store) UpsertNote(noteID, title, content, notebookID string, isDeleted, archived, encrypted bool, sourceDevice string, version int) (int, error) {
	ts := time.Now().UTC().Format(time.RFC3339)
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	if err := upsert(tx,
		`INSERT INTO notes (id, title, content_markdown, notebook_id, version, is_deleted, archived, encrypted, source_device, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET
		   title=excluded.title, content_markdown=excluded.content_markdown,
		   notebook_id=excluded.notebook_id,
		   version=excluded.version, is_deleted=excluded.is_deleted,
		   archived=excluded.archived,
		   encrypted=excluded.encrypted,
		   source_device=excluded.source_device,
		   updated_at=excluded.updated_at`,
		noteID, title, content, notebookID, version, b2i(isDeleted), b2i(archived), b2i(encrypted), sourceDevice, ts,
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
	ID        string
	ParentID  string
	Name      string
	SortOrder int
	IsDeleted bool
	Version   int
	// M10-T29（FR-51）：是否加密笔记本 + **非敏感**加密元数据（JSON，服务端不解析）。
	Encrypted    bool
	CryptoMeta   string
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
		`SELECT id, parent_id, name, sort_order, is_deleted, version, encrypted, crypto_meta, source_device, created_at, updated_at
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
		var del, enc int
		var created, updated string
		if err := rows.Scan(&r.ID, &r.ParentID, &r.Name, &r.SortOrder, &del, &r.Version, &enc, &r.CryptoMeta, &r.SourceDevice, &created, &updated); err != nil {
			return nil, err
		}
		r.IsDeleted = del != 0
		r.Encrypted = enc != 0
		r.CreatedAt = parseTime(created)
		r.UpdatedAt = parseTime(updated)
		out = append(out, r)
	}
	return out, rows.Err()
}

// GetNotebook 返回指定笔记本分组的服务端状态（不存在返回 nil, nil）。
func (s *Store) GetNotebook(id string) (*NotebookRow, error) {
	var r NotebookRow
	var del, enc int
	var created, updated string
	err := s.db.QueryRow(
		`SELECT id, parent_id, name, sort_order, is_deleted, version, encrypted, crypto_meta, source_device, created_at, updated_at
		 FROM notebooks WHERE id = ?`, id,
	).Scan(&r.ID, &r.ParentID, &r.Name, &r.SortOrder, &del, &r.Version, &enc, &r.CryptoMeta, &r.SourceDevice, &created, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	r.IsDeleted = del != 0
	r.Encrypted = enc != 0
	r.CreatedAt = parseTime(created)
	r.UpdatedAt = parseTime(updated)
	return &r, nil
}

// UpsertNotebook 落库笔记本分组（增量）。created_at 只在首次插入时写入，
// 冲突更新时不覆盖，保持分组创建时间稳定。
func (s *Store) UpsertNotebook(id, parentID, name string, sortOrder int, isDeleted bool, encrypted bool, cryptoMeta string, sourceDevice string, version int) error {
	ts := time.Now().UTC().Format(time.RFC3339)
	return upsert(s.db,
		`INSERT INTO notebooks (id, parent_id, name, sort_order, is_deleted, version, encrypted, crypto_meta, source_device, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET
		   parent_id=excluded.parent_id, name=excluded.name, sort_order=excluded.sort_order,
		   is_deleted=excluded.is_deleted, version=excluded.version,
		   encrypted=excluded.encrypted, crypto_meta=excluded.crypto_meta,
		   source_device=excluded.source_device, updated_at=excluded.updated_at`,
		id, parentID, name, sortOrder, b2i(isDeleted), version, b2i(encrypted), cryptoMeta, sourceDevice, ts, ts,
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
