// Package sync 实现 Sui 服务端的增量同步逻辑与冲突处理。
//
// 基于设计文档 §6：版本号模型（base / 本地草稿 / 服务端权威版本线）与冲突
// 处理规则（直接应用 → 字段级合并 → 双版本保留 → LWW 兜底，绝不丢字）。
package sync

import (
	"time"

	"sui/note-server/internal/store"
)

// Protocol 封装服务端同步 API 的具体行为。
type Protocol struct {
	store *store.Store
}

// New 创建同步协议处理器。
func New(st *store.Store) *Protocol {
	return &Protocol{store: st}
}

// PushItem 是客户端推送的一条笔记变更。
type PushItem struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Content     string `json:"content"`
	BaseVersion int    `json:"baseVersion"`
	Version     int    `json:"version"`
	IsDeleted   bool   `json:"isDeleted"`
	Archived    bool   `json:"archived"`
	// M10-T29（FR-51）：所属笔记本是否为加密笔记本（镜像）。加密时 Title / Content 为**密文**，
	// 服务端只搬运、不解析。
	Encrypted    bool             `json:"encrypted"`
	SourceDevice string           `json:"sourceDevice"`
	Attachments  []AttachmentItem `json:"attachments,omitempty"`

	// NotebookID 为该笔记所属笔记本；nil 表示不涉及归属变更，
	// 空值(&"")表示移出至收件箱，非空值表示设为该笔记本（BR-19.7）。
	NotebookID *string `json:"notebookId,omitempty"`

	// TagIDs 为该笔记当前的标签 id 全集；nil 表示「本次不涉及标签」，
	// 空切片表示「清空标签」。用指针区分缺席与显式空集，避免误清关联。
	TagIDs *[]string `json:"tagIds,omitempty"`
}

// AttachmentItem 是随笔记一起交换的附件映射（不含字节）。
//
// 字节按 sha256 内容寻址单独走 `/blobs/{hash}`，因此这里的数据极小，
// 可以随每次笔记推送全量携带，天然幂等。
type AttachmentItem struct {
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

func (a AttachmentItem) toRow(noteID string) store.AttachmentRow {
	return store.AttachmentRow{
		ID:           a.ID,
		NoteID:       noteID,
		Filename:     a.Filename,
		MimeKind:     a.MimeKind,
		ByteSize:     a.ByteSize,
		SHA256:       a.SHA256,
		StorageRef:   a.StorageRef,
		ThumbnailRef: a.ThumbnailRef,
		EmbeddedPos:  a.EmbeddedPos,
		IsDeleted:    a.IsDeleted,
		CreatedAt:    parseOptionalTime(a.CreatedAt),
	}
}

// PushResponse 反映服务端接受或冲突的裁决结果。
type PushResponse struct {
	Accepted bool `json:"accepted"`
	// Conflict 时给出服务端当前权威版本，供客户端字段级合并/双版本保留。
	//
	// M12（ADR-019 决策 3）：**去掉 omitempty** —— 「服务端没有该实体」时须**显式给出 0**，
	// 客户端据此区分「服务端没有它」（可自愈：基线归零重发）与真冲突。
	ServerVersion  int `json:"serverVersion"`
	AppliedVersion int `json:"appliedVersion,omitempty"`
	// NotFound 表示服务端**没有**该实体（而非版本冲突）；此时 ServerVersion 为 0。
	NotFound bool `json:"notFound,omitempty"`
}

// Push 处理客户端推送。冲突判定的唯一依据是：
//
//		客户端声明的 BaseVersion 与 服务端当前权威版本 是否一致（设计 §6.4/6.6）。
//
//	  - 一致 → 直接应用（version 取服务端当前+1，落修订），Accepted=true。
//	    同时落该笔记的附件映射（以 id 为键 upsert，幂等）；
//	    并在显式携带 TagIDs（非 nil）时整体替换该笔记的标签关联。
//	  - 不一致 → 不覆盖，返回冲突（ServerVersion=服务端当前），Accepted=false。
//	    客户端据此走字段级合并/diff3/双版本保留。
//
// 附件映射只在笔记被接受时落库：被拒绝的是「本地草稿」，其引用的附件
// 尚未成为权威内容的一部分；客户端合并后重发时会一并带来。
func (p *Protocol) Push(it PushItem) (*PushResponse, error) {
	current, err := p.store.GetNote(it.ID)
	if err != nil {
		return nil, err
	}

	serverVer := 0
	if current != nil {
		serverVer = current.Version
	}

	// 无冲突：BaseVersion 与服务端当前一致（含当前不存在但客户端以 0 为 base 的新笔记）。
	if it.BaseVersion == serverVer {
		nextVer := serverVer + 1
		notebookID := ""
		if current != nil {
			notebookID = current.NotebookID
		}
		if it.NotebookID != nil {
			notebookID = *it.NotebookID
		}
		if _, err := p.store.UpsertNote(
			it.ID, it.Title, it.Content, notebookID, it.IsDeleted, it.Archived, it.Encrypted,
			it.SourceDevice, nextVer,
		); err != nil {
			return nil, err
		}
		if len(it.Attachments) > 0 {
			rows := make([]store.AttachmentRow, 0, len(it.Attachments))
			for _, a := range it.Attachments {
				if a.ID == "" {
					continue
				}
				rows = append(rows, a.toRow(it.ID))
			}
			if err := p.store.SyncAttachments(it.ID, rows); err != nil {
				return nil, err
			}
		}
		if it.TagIDs != nil {
			if err := p.store.SyncNoteTags(it.ID, *it.TagIDs); err != nil {
				return nil, err
			}
		}
		return &PushResponse{Accepted: true, AppliedVersion: nextVer}, nil
	}

	// M12：服务端**没有**该实体（而客户端基线非 0）→ 明确告知 notFound。
	// 客户端把基线归零后重发即被接受；旧实现在这里会永久冲突（B24-①）。
	if current == nil {
		return &PushResponse{Accepted: false, NotFound: true}, nil
	}

	// 冲突：返回服务端权威版本，供客户端合并。服务端不落库。
	return &PushResponse{
		Accepted:      false,
		ServerVersion: serverVer,
	}, nil
}

// PullNote 是一条增量笔记及其当前附件映射。
type PullNote struct {
	Note        store.NoteRow
	Attachments []store.AttachmentRow
	TagIDs      []string
}

// Pull 返回自 since 之后的服务端权威变更（增量拉取），并带上各笔记的附件映射。
//
// 附件映射随笔记交换：映射本身极小，且脱离笔记没有意义；这样客户端只需一个
// `since` 游标即可同时收敛正文、附件引用与标签关联。
func (p *Protocol) Pull(since time.Time) ([]PullNote, error) {
	notes, err := p.store.UpdatedSince(since)
	if err != nil {
		return nil, err
	}
	if len(notes) == 0 {
		return nil, nil
	}
	ids := make([]string, 0, len(notes))
	for _, n := range notes {
		ids = append(ids, n.ID)
	}
	byNote, err := p.store.ListAttachmentsForNotes(ids)
	if err != nil {
		return nil, err
	}
	byTag, err := p.store.ListNoteTagsForNotes(ids)
	if err != nil {
		return nil, err
	}
	out := make([]PullNote, 0, len(notes))
	for _, n := range notes {
		out = append(out, PullNote{Note: n, Attachments: byNote[n.ID], TagIDs: byTag[n.ID]})
	}
	return out, nil
}

func parseOptionalTime(s string) time.Time {
	if s == "" {
		return time.Time{}
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}
	}
	return t
}

// NotebookItem 是客户端推送的一条笔记本分组变更。
//
// 与笔记一样携带 baseVersion/version/isDeleted/sourceDevice，复用同一套
// 「base 与服务端权威版本一致才应用」的冲突判定与墓碑语义。
type NotebookItem struct {
	ID        string `json:"id"`
	ParentID  string `json:"parentId"`
	Name      string `json:"name"`
	SortOrder int    `json:"sortOrder"`
	// M10-T29（FR-51）：是否加密笔记本 + **非敏感**加密元数据（算法 / KDF 参数 / salt / verifier）。
	// 名称保持明文（便于辨认该解锁哪个笔记本）；服务端不解析 cryptoMeta。
	Encrypted    bool   `json:"encrypted"`
	CryptoMeta   string `json:"cryptoMeta,omitempty"`
	BaseVersion  int    `json:"baseVersion"`
	Version      int    `json:"version"`
	IsDeleted    bool   `json:"isDeleted"`
	SourceDevice string `json:"sourceDevice"`
}

// TagItem 是客户端推送的一条标签变更。
type TagItem struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	BaseVersion  int    `json:"baseVersion"`
	Version      int    `json:"version"`
	IsDeleted    bool   `json:"isDeleted"`
	SourceDevice string `json:"sourceDevice"`
}

// PushNotebook 处理笔记本分组推送，冲突判定与 Push 完全一致。
func (p *Protocol) PushNotebook(it NotebookItem) (*PushResponse, error) {
	current, err := p.store.GetNotebook(it.ID)
	if err != nil {
		return nil, err
	}
	serverVer := 0
	if current != nil {
		serverVer = current.Version
	}
	if it.BaseVersion == serverVer {
		nextVer := serverVer + 1
		if err := p.store.UpsertNotebook(
			it.ID, it.ParentID, it.Name, it.SortOrder, it.IsDeleted, it.Encrypted, it.CryptoMeta,
			it.SourceDevice, nextVer,
		); err != nil {
			return nil, err
		}
		return &PushResponse{Accepted: true, AppliedVersion: nextVer}, nil
	}
	if current == nil {
		// M12：服务端没有该笔记本（客户端基线非 0）→ 基线归零后重发即被接受。
		return &PushResponse{Accepted: false, NotFound: true}, nil
	}
	return &PushResponse{Accepted: false, ServerVersion: serverVer}, nil
}

// PushTag 处理标签推送，冲突判定与 Push 完全一致。
func (p *Protocol) PushTag(it TagItem) (*PushResponse, error) {
	current, err := p.store.GetTag(it.ID)
	if err != nil {
		return nil, err
	}
	serverVer := 0
	if current != nil {
		serverVer = current.Version
	}
	if it.BaseVersion == serverVer {
		nextVer := serverVer + 1
		if err := p.store.UpsertTag(
			it.ID, it.Name, it.IsDeleted, it.SourceDevice, nextVer,
		); err != nil {
			return nil, err
		}
		return &PushResponse{Accepted: true, AppliedVersion: nextVer}, nil
	}
	if current == nil {
		// M12：服务端没有该标签（客户端基线非 0）→ 基线归零后重发即被接受。
		return &PushResponse{Accepted: false, NotFound: true}, nil
	}
	return &PushResponse{Accepted: false, ServerVersion: serverVer}, nil
}

// PullNotebooks 返回自 since 之后的笔记本分组变更（含墓碑）。
func (p *Protocol) PullNotebooks(since time.Time) ([]store.NotebookRow, error) {
	return p.store.UpdatedNotebooksSince(since)
}

// PullTags 返回自 since 之后的标签变更（含墓碑）。
func (p *Protocol) PullTags(since time.Time) ([]store.TagRow, error) {
	return p.store.UpdatedTagsSince(since)
}

// GCOrphans 触发一次孤儿 Blob 清理。
func (p *Protocol) GCOrphans() ([]string, error) {
	return p.store.GCOrphanBlobs()
}
