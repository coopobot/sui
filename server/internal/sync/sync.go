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
	SourceDevice string `json:"sourceDevice"`
}

// PushResponse 反映服务端接受或冲突的裁决结果。
type PushResponse struct {
	Accepted bool `json:"accepted"`
	// Conflict 时给出服务端当前权威版本，供客户端字段级合并/双版本保留。
	ServerVersion int  `json:"serverVersion,omitempty"`
	AppliedVersion int `json:"appliedVersion,omitempty"`
}

// Push 处理客户端推送。冲突判定的唯一依据是：
//
//	客户端声明的 BaseVersion 与 服务端当前权威版本 是否一致（设计 §6.4/6.6）。
//
// - 一致 → 直接应用（version 取服务端当前+1，落修订），Accepted=true。
// - 不一致 → 不覆盖，返回冲突（ServerVersion=服务端当前），Accepted=false。
//   客户端据此走字段级合并/diff3/双版本保留。
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
		if _, err := p.store.UpsertNote(
			it.ID, it.Title, it.Content, it.IsDeleted, it.SourceDevice, nextVer,
		); err != nil {
			return nil, err
		}
		return &PushResponse{Accepted: true, AppliedVersion: nextVer}, nil
	}

	// 冲突：返回服务端权威版本，供客户端合并。服务端不落库。
	return &PushResponse{
		Accepted:      false,
		ServerVersion: serverVer,
	}, nil
}

// Pull 返回自 since 之后的服务端权威变更（增量拉取）。
func (p *Protocol) Pull(since time.Time) ([]store.NoteRow, error) {
	return p.store.UpdatedSince(since)
}

// GCOrphans 触发一次孤儿 Blob 清理。
func (p *Protocol) GCOrphans() ([]string, error) {
	return p.store.GCOrphanBlobs()
}