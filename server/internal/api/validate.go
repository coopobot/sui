// 服务端外部输入校验层（FR-52 / BR-52.1）。
//
// 设计来源：technology/design/low-level-design/input-validation.md §3。
// 口径：**先白名单、后使用**；非法取值一律 400，且**不进入存储层、不产生任何
// 文件系统副作用**。
//
// 明确**不做**「清洗后继续用」（如 strings.ReplaceAll(hash, "..", "") 或
// filepath.Base(hash)）——这类改写会让攻击者与正常用户共用一条含歧义的路径，
// 语义不可审计；本层只做拒绝。
package api

import (
	"regexp"
	"strconv"
)

var (
	// sha256：定长 64 位小写十六进制。
	//
	// 合法性依据是既有实现的真实输出（store.HashBytes → hex.EncodeToString），
	// 因此该口径对既有客户端完全透明（ADR-004 / ADR-016）。
	reSHA256 = regexp.MustCompile(`^[0-9a-f]{64}$`)

	// id / noteId / tagId / attachmentId：1~128 位的受限字符集。
	reID = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
)

// validSHA256 报告 s 是否为合法的内容寻址摘要。
func validSHA256(s string) bool { return reSHA256.MatchString(s) }

// validID 报告 s 是否为合法的标识符（笔记 / 修订 / 标签 / 附件 id）。
func validID(s string) bool { return reID.MatchString(s) }

// validVersion 解析修订版本号：必须为十进制正整数。
func validVersion(s string) (int, bool) {
	v, err := strconv.Atoi(s)
	if err != nil || v <= 0 {
		return 0, false
	}
	return v, true
}
