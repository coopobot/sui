package api

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"sui/note-server/internal/blob"
	"sui/note-server/internal/sync"
)

// handleRegister 首启建号并签发会话 token（单用户实例的注册网关）。
func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad request"})
		return
	}
	if req.Username == "" || req.Password == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "username/password required"})
		return
	}
	// 单用户服务（ADR-009 / BR-33.2）：实例已初始化即永久关闭自助注册。
	initialized, err := s.store.HasAnyUser()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": "internal error"})
		return
	}
	if initialized {
		writeJSON(w, http.StatusForbidden, map[string]any{"ok": false, "error": "already-initialized"})
		return
	}
	pair, err := s.store.CreateUser(req.Username, req.Password)
	if err != nil {
		writeJSON(w, http.StatusConflict, map[string]any{"ok": false, "error": "user exists"})
		return
	}
	writeJSON(w, http.StatusOK, tokenResponse(pair, req.Username))
}

// handleLogin 用户登录，返回双令牌（M12 修订 / FR-59：含登录失败防护）。
func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad request"})
		return
	}
	if req.Username == "" || req.Password == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "username/password required"})
		return
	}
	// M12 修订 / FR-59（BR-59.1~59.4）：登录失败防护 —— **先**判定锁定与同键串行化，
	// **再**校验口令；锁定期内即使口令正确也拒绝（AC-226）。
	release, locked, retryAfter := s.guard.begin(req.Username, r)
	defer release()
	if locked {
		writeLoginLocked(w, retryAfter)
		return
	}
	// 校验 PBKDF2 密码哈希（M4/BR-36.1），成功则签发新会话 token。
	pair, err := s.store.LoginUser(req.Username, req.Password)
	if err != nil {
		// 失败记账：达到阈值则退避（failure 内部已延迟）或锁定（BR-59.2）。
		if _, nowLocked, lockRetry := s.guard.failure(req.Username, r); nowLocked {
			writeLoginLocked(w, lockRetry)
			return
		}
		writeJSON(w, http.StatusUnauthorized, map[string]any{"ok": false, "error": "invalid credentials"})
		return
	}
	s.guard.success(req.Username, r)
	writeJSON(w, http.StatusOK, tokenResponse(pair, req.Username))
}

// handlePush 处理客户端批量推送（逐条调用 sync.Push，汇总结果）。
func (s *Server) handlePush(w http.ResponseWriter, r *http.Request) {
	// M10：大请求体路由单独延长**读**期限（§8）；须在读 body 之前调用。
	extendReadDeadline(w)
	var req struct {
		ClientID  string              `json:"clientId"`
		Items     []sync.PushItem     `json:"items"`
		Notebooks []sync.NotebookItem `json:"notebooks"`
		Tags      []sync.TagItem      `json:"tags"`
	}
	// M10-T25：整包读入前先限长（超限 413），并限制单次条目数。
	body := http.MaxBytesReader(w, r.Body, maxBodyBytes())
	if err := json.NewDecoder(body).Decode(&req); err != nil {
		if isTooLarge(err) {
			writeJSON(w, http.StatusRequestEntityTooLarge, map[string]any{"ok": false, "error": "payload too large"})
			return
		}
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad request"})
		return
	}
	if len(req.Items) > maxPushItems() || len(req.Notebooks) > maxPushItems() || len(req.Tags) > maxPushItems() {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "too many items"})
		return
	}
	type itemResult struct {
		ID       string `json:"id"`
		Accepted bool   `json:"accepted"`
		// M12（ADR-019 决策 3）：`serverVersion` **不再 omitempty**，使「服务端没有该实体」时
		// 也能显式给出 0；`notFound` 明确区分「没有该实体」与「版本冲突」。
		ServerVersion  int  `json:"serverVersion"`
		AppliedVersion int  `json:"appliedVersion,omitempty"`
		NotFound       bool `json:"notFound,omitempty"`
	}
	results := make([]itemResult, 0, len(req.Items))
	for _, it := range req.Items {
		resp, err := s.sync.Push(it)
		if err != nil {
			writeInternalError(w, r, err)
			return
		}
		results = append(results, itemResult{
			ID: it.ID, Accepted: resp.Accepted,
			ServerVersion: resp.ServerVersion, AppliedVersion: resp.AppliedVersion,
			NotFound: resp.NotFound,
		})
	}
	notebookResults := make([]itemResult, 0, len(req.Notebooks))
	for _, it := range req.Notebooks {
		resp, err := s.sync.PushNotebook(it)
		if err != nil {
			writeInternalError(w, r, err)
			return
		}
		notebookResults = append(notebookResults, itemResult{
			ID: it.ID, Accepted: resp.Accepted,
			ServerVersion: resp.ServerVersion, AppliedVersion: resp.AppliedVersion,
			NotFound: resp.NotFound,
		})
	}
	tagResults := make([]itemResult, 0, len(req.Tags))
	for _, it := range req.Tags {
		resp, err := s.sync.PushTag(it)
		if err != nil {
			writeInternalError(w, r, err)
			return
		}
		tagResults = append(tagResults, itemResult{
			ID: it.ID, Accepted: resp.Accepted,
			ServerVersion: resp.ServerVersion, AppliedVersion: resp.AppliedVersion,
			NotFound: resp.NotFound,
		})
	}
	// 发送变更通知（WebSocket）
	s.hub.NotifyChange()

	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "results": results,
		"notebookResults": notebookResults, "tagResults": tagResults,
	})
}

// apiPullAttachment 是 pull 响应里的附件映射（字段与 v0.22.3 逐字一致）。
type apiPullAttachment struct {
	ID           string `json:"id"`
	Filename     string `json:"filename"`
	MimeKind     string `json:"mimeKind"`
	ByteSize     int    `json:"byteSize"`
	SHA256       string `json:"sha256"`
	StorageRef   string `json:"storageRef"`
	ThumbnailRef string `json:"thumbnailRef"`
	EmbeddedPos  int    `json:"embeddedPos"`
	IsDeleted    bool   `json:"isDeleted"`
	CreatedAt    string `json:"createdAt"`
}

// apiPullNote 是 pull 响应里的笔记（字段与 v0.22.3 逐字一致）。
type apiPullNote struct {
	ID           string              `json:"id"`
	Title        string              `json:"title"`
	Content      string              `json:"content"`
	Version      int                 `json:"version"`
	IsDeleted    bool                `json:"isDeleted"`
	Archived     bool                `json:"archived"`
	Encrypted    bool                `json:"encrypted"`
	SourceDevice string              `json:"sourceDevice"`
	SourceURL    string              `json:"sourceUrl,omitempty"`
	UpdatedAt    string              `json:"updatedAt"`
	Attachments  []apiPullAttachment `json:"attachments,omitempty"`
	NotebookID   string              `json:"notebookId,omitempty"`
	TagIDs       []string            `json:"tagIds,omitempty"`
}

// apiPullNotebook 是 pull 响应里的笔记本（根级 parentId 为空时省略字段）。
type apiPullNotebook struct {
	ID           string `json:"id"`
	ParentID     string `json:"parentId,omitempty"`
	Name         string `json:"name"`
	SortOrder    int    `json:"sortOrder"`
	Version      int    `json:"version"`
	IsDeleted    bool   `json:"isDeleted"`
	Encrypted    bool   `json:"encrypted"`
	CryptoMeta   string `json:"cryptoMeta,omitempty"`
	SourceDevice string `json:"sourceDevice"`
	UpdatedAt    string `json:"updatedAt"`
}

// apiPullTag 是 pull 响应里的标签。
type apiPullTag struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Version      int    `json:"version"`
	IsDeleted    bool   `json:"isDeleted"`
	SourceDevice string `json:"sourceDevice"`
	UpdatedAt    string `json:"updatedAt"`
}

// handlePull 返回自 since 之后的增量。
//
// v0.22.4 / 内存治理（ADR-048）：响应**逐条流式编码**——不再把整库正文读成切片、
// 也不再构造整份 JSON 字符串；同时用 pullGate 限制并发大响应。
//
// 峰值构成（加密请求）：单篇正文 + 受保护通道的整包缓冲（明文）+ 密文封装；base64 直接
// 流式写到连接，不再另存一份 4/3 倍字符串。
func (s *Server) handlePull(w http.ResponseWriter, r *http.Request) {
	// 全量 / 大增量响应可能有上百 MB：按「流式下载」口径延长**写**期限
	// （全局 WriteTimeout 10s 是为慢速攻击兜底，不是给 100 MB 响应用的）。
	extendWriteDeadline(w)

	since := time.Time{}
	if v := r.URL.Query().Get("since"); v != "" {
		if t, err := time.Parse(time.RFC3339, v); err == nil {
			since = t
		}
	}

	release, ok := s.pull.acquire(r.Context(), pullWaitWindow())
	if !ok {
		// 闸门排队超时：让客户端按既有重试逻辑晚点再来，而不是把两倍峰值同时压进内存。
		w.Header().Set("Retry-After", "5")
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"ok": false, "error": "server busy"})
		return
	}
	defer release()

	// 先取「小且必须成功」的部分（笔记本 / 标签 / 实例身份）：它们出错时还能回 500。
	nbRows, err := s.sync.PullNotebooks(since)
	if err != nil {
		writeInternalError(w, r, err)
		return
	}
	tagRows, err := s.sync.PullTags(since)
	if err != nil {
		writeInternalError(w, r, err)
		return
	}
	instanceID, err := s.store.InstanceID()
	if err != nil {
		writeInternalError(w, r, err)
		return
	}

	notebooks := make([]apiPullNotebook, 0, len(nbRows))
	for _, nb := range nbRows {
		notebooks = append(notebooks, apiPullNotebook{
			ID: nb.ID, ParentID: nb.ParentID, Name: nb.Name, SortOrder: nb.SortOrder,
			Version: nb.Version, IsDeleted: nb.IsDeleted, SourceDevice: nb.SourceDevice,
			Encrypted: nb.Encrypted, CryptoMeta: nb.CryptoMeta,
			UpdatedAt: nb.UpdatedAt.UTC().Format(time.RFC3339),
		})
	}
	tags := make([]apiPullTag, 0, len(tagRows))
	for _, tg := range tagRows {
		tags = append(tags, apiPullTag{
			ID: tg.ID, Name: tg.Name, Version: tg.Version,
			IsDeleted: tg.IsDeleted, SourceDevice: tg.SourceDevice,
			UpdatedAt: tg.UpdatedAt.UTC().Format(time.RFC3339),
		})
	}

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusOK)

	bw := bufio.NewWriterSize(w, 64<<10)
	enc := json.NewEncoder(bw)
	if _, err := bw.WriteString(`{"ok":true,"notes":[`); err != nil {
		log.Printf("pull: write header: %v", err)
		return
	}
	first := true
	err = s.sync.PullIter(since, func(pn sync.PullNote) error {
		if !first {
			if err := bw.WriteByte(','); err != nil {
				return err
			}
		}
		first = false
		// 单条编码：encoder 的缓冲只保留「最大单篇笔记」量级，不再随整库增长。
		return enc.Encode(noteFromPull(pn))
	})
	if err != nil {
		// 响应头已发出，无法再回 500：记日志并中止，客户端会因 JSON 截断而重试。
		log.Printf("pull: stream notes: %v", err)
		return
	}
	if _, err := bw.WriteString(`],"notebooks":`); err != nil {
		return
	}
	if err := enc.Encode(notebooks); err != nil {
		log.Printf("pull: encode notebooks: %v", err)
		return
	}
	if _, err := bw.WriteString(`,"tags":`); err != nil {
		return
	}
	if err := enc.Encode(tags); err != nil {
		log.Printf("pull: encode tags: %v", err)
		return
	}
	inst, _ := json.Marshal(instanceID)
	if _, err := bw.WriteString(`,"instanceId":` + string(inst) + `}`); err != nil {
		return
	}
	_ = bw.Flush()
}

// noteFromPull 把同步层的一行转换成 pull 响应结构（不复制正文字符串）。
func noteFromPull(pn sync.PullNote) apiPullNote {
	rw := pn.Note
	item := apiPullNote{
		ID: rw.ID, Title: rw.Title, Content: rw.ContentMarkdown,
		Version: rw.Version, IsDeleted: rw.IsDeleted, Archived: rw.Archived,
		Encrypted:    rw.Encrypted,
		SourceDevice: rw.SourceDevice,
		SourceURL:    rw.SourceURL,
		NotebookID:   rw.NotebookID,
		UpdatedAt:    rw.UpdatedAt.UTC().Format(time.RFC3339),
		TagIDs:       pn.TagIDs,
	}
	for _, a := range pn.Attachments {
		item.Attachments = append(item.Attachments, apiPullAttachment{
			ID: a.ID, Filename: a.Filename, MimeKind: a.MimeKind,
			ByteSize: a.ByteSize, SHA256: a.SHA256, StorageRef: a.StorageRef,
			ThumbnailRef: a.ThumbnailRef, EmbeddedPos: a.EmbeddedPos,
			IsDeleted: a.IsDeleted,
			CreatedAt: a.CreatedAt.UTC().Format(time.RFC3339),
		})
	}
	return item
}

// handleBlobHead 检查 hash 是否存在（内容寻址去重）。
//
// M10-T21：hash 先过白名单（非法 → 400，且不查库、不触盘）。
func (s *Server) handleBlobHead(w http.ResponseWriter, r *http.Request) {
	hash := r.PathValue("hash")
	if !validSHA256(hash) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid parameter"})
		return
	}
	exists, _, err := s.blobOnDisk(hash)
	if err != nil {
		writeInternalError(w, r, err)
		return
	}
	if exists {
		w.WriteHeader(http.StatusOK)
		return
	}
	w.WriteHeader(http.StatusNotFound)
}

// blobOnDisk 报告内容是否真实存在于内容寻址存储，并返回其字节数。
//
// `blobs` 行只承担引用计数 / 大小记账，可能**先于字节**出现（附件映射先到、
// 上传尚未成功），因此 HEAD / PUT 不能只看 DB 行（v0.19.3 / BR-118.1）。
func (s *Server) blobOnDisk(hash string) (bool, int64, error) {
	size, exists, err := s.blobs.Stat(hash)
	if err != nil {
		return false, 0, err
	}
	return exists, size, nil
}

// handleBlobPut 上传 hash 对应的字节；已存在则幂等返回。
//
// M10-T21/T22（FR-52 / BR-52.2/52.3）：
//   - hash 先过白名单（非法 → 400，不触盘）；
//   - 请求体经 http.MaxBytesReader 限长（超限 → 413）；
//   - 字节摘要由存储层（blob.Local.Put）边写边校验，不一致 → 400 且最终路径不留文件；
//   - blobs 行以**磁盘实际字节数**记账，不再采信 Content-Length（可伪造成 -1）。
//
// 只负责字节与登记，不调整引用计数——refcount 由附件映射（sync/push 携带的
// attachments）驱动，见 store.SyncAttachments。
func (s *Server) handleBlobPut(w http.ResponseWriter, r *http.Request) {
	// M10：大请求体路由单独延长**读**期限（§8）；须在读 body 之前调用。
	extendReadDeadline(w)
	hash := r.PathValue("hash")
	if !validSHA256(hash) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid parameter"})
		return
	}
	// 文件存在才算已上传；不能只看 `blobs` 行——映射先到时行存在但没有字节，
	// 旧逻辑会跳过读体并永远不落盘（v0.19.3 / BR-118.3）。
	exists, size, err := s.blobOnDisk(hash)
	if err != nil {
		writeInternalError(w, r, err)
		return
	}
	if !exists {
		body := http.MaxBytesReader(w, r.Body, maxBlobBytes())
		n, err := s.blobs.Put(hash, body)
		switch {
		case err == nil:
			// 正常写入；size 在下面按磁盘实际大小回填。
		case errors.Is(err, blob.ErrDigestMismatch):
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid payload"})
			return
		case isTooLarge(err):
			writeJSON(w, http.StatusRequestEntityTooLarge, map[string]any{"ok": false, "error": "payload too large"})
			return
		case errors.Is(err, blob.ErrOutsideRoot):
			// 入口白名单已挡在前面；这里命中说明调用方绕过了校验（不泄露路径）。
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid parameter"})
			return
		default:
			writeInternalError(w, r, err)
			return
		}
		size = n
	} else {
		// 幂等重传：文件已存在时也要把请求体读完再响应，否则客户端可能
		// 在写体阶段收到早响应 / broken pipe，永远置不上 uploaded_at（v0.19.3）。
		_, _ = io.Copy(io.Discard, http.MaxBytesReader(w, r.Body, maxBlobBytes()))
	}
	// 记账口径：以存储层实际大小为权威（自愈写入 / 幂等命中都从 Stat 取）。
	if n, ok, serr := s.blobs.Stat(hash); serr == nil && ok {
		size = n
	}
	if _, err := s.store.EnsureBlob(hash, int(size)); err != nil {
		writeInternalError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// handleBlobGet 下载 hash 对应的 blob 字节。
func (s *Server) handleBlobGet(w http.ResponseWriter, r *http.Request) {
	// M10：流式下载路由单独延长**写**期限（§8）。
	extendWriteDeadline(w)
	hash := r.PathValue("hash")
	if !validSHA256(hash) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid parameter"})
		return
	}
	size, exists, err := s.blobs.Stat(hash)
	if err != nil {
		writeInternalError(w, r, err)
		return
	}
	if !exists {
		// 行在、文件缺失是「资源不存在」，不是服务端内部错误（v0.19.3 / BR-118.2）。
		writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "blob not found"})
		return
	}
	reader, err := s.blobs.Open(hash)
	if errors.Is(err, blob.ErrNotFound) || os.IsNotExist(err) {
		writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "blob not found"})
		return
	}
	if err != nil {
		writeInternalError(w, r, err)
		return
	}
	defer reader.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", "attachment; filename="+hash)
	// M10-T24：附件内容不该被中间缓存留存。
	w.Header().Set("Cache-Control", "private")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	_, _ = io.Copy(w, reader)
}

// ---- 修订历史 ----

// handleListRevisions 返回指定笔记的修订列表。
func (s *Server) handleListRevisions(w http.ResponseWriter, r *http.Request) {
	noteID := r.PathValue("id")
	if !validID(noteID) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid parameter"})
		return
	}
	revs, err := s.store.ListRevisions(noteID, 50)
	if err != nil {
		writeInternalError(w, r, err)
		return
	}
	type revOut struct {
		Version      int    `json:"version"`
		Title        string `json:"title"`
		Content      string `json:"content"`
		SourceDevice string `json:"sourceDevice"`
		IsConflict   bool   `json:"isConflict"`
		CreatedAt    string `json:"createdAt"`
	}
	list := make([]revOut, 0, len(revs))
	for _, r := range revs {
		list = append(list, revOut{
			Version:      r.Version,
			Title:        r.Title,
			Content:      r.ContentMarkdown,
			SourceDevice: r.SourceDevice,
			IsConflict:   r.IsConflict,
			CreatedAt:    r.CreatedAt.UTC().Format(time.RFC3339),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "revisions": list})
}

// handleGetRevision 返回指定版本的修订详情。
func (s *Server) handleGetRevision(w http.ResponseWriter, r *http.Request) {
	noteID := r.PathValue("id")
	if !validID(noteID) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid parameter"})
		return
	}
	version, ok := validVersion(r.PathValue("version"))
	if !ok {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid parameter"})
		return
	}
	rev, err := s.store.GetRevision(noteID, version)
	if err != nil {
		writeInternalError(w, r, err)
		return
	}
	if rev == nil {
		writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "revision not found"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true,
		"revision": map[string]any{
			"version":      rev.Version,
			"title":        rev.Title,
			"content":      rev.ContentMarkdown,
			"sourceDevice": rev.SourceDevice,
			"isConflict":   rev.IsConflict,
			"createdAt":    rev.CreatedAt.UTC().Format(time.RFC3339),
		},
	})
}
