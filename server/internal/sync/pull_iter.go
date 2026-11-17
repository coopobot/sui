package sync

import "time"

// PullIter 逐条遍历自 since 之后的服务端变更（含附件映射与标签关联）。
//
// 与 [Pull] 的差别只在**内存**：Pull 把整库正文读成 `[]PullNote` 再交给调用方，
// 大库（几十 MB 正文）会先占住一份「全量正文」；PullIter 只先取**笔记 id 列表**
// （每条约 36 字节）与附件 / 标签的批量映射（元数据，很小），正文按条 GET、
// 交给 yield 编码完即可被回收。参见 v0.22.4 内存治理（ADR-048）。
func (p *Protocol) PullIter(since time.Time, yield func(PullNote) error) error {
	ids, err := p.store.NoteIDsSince(since)
	if err != nil {
		return err
	}
	if len(ids) == 0 {
		return nil
	}
	byNote, err := p.store.ListAttachmentsForNotes(ids)
	if err != nil {
		return err
	}
	byTag, err := p.store.ListNoteTagsForNotes(ids)
	if err != nil {
		return err
	}
	for _, id := range ids {
		n, err := p.store.GetNote(id)
		if err != nil {
			return err
		}
		if n == nil {
			continue // 并发删除：按增量语义跳过
		}
		if err := yield(PullNote{Note: *n, Attachments: byNote[id], TagIDs: byTag[id]}); err != nil {
			return err
		}
	}
	return nil
}
