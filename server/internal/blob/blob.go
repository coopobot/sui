// Package blob 提供服务端附件字节的对象存储（内容寻址，sha256）。
//
// 默认落在本地磁盘 <data>/blobs，按 sha256 前两位分片；通过 BLOB_STORE 环境变量可
// 切到 S3 兼容后端（见设计文档 §10.5）。
//
// M10（BR-52.2 / BR-52.3）在本层加了两道兜底：
//
//   - 所有路径推导都过 ensureInside，越出存储根一律返回 ErrOutsideRoot（不触盘）；
//   - Put 边写边算 sha256，与声明值不一致时删除临时文件并返回 ErrDigestMismatch，
//     绝不 rename 到最终路径 —— 内容寻址不可被投毒。
package blob

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const (
	// dirPerm / filePerm：目录与数据文件权限收紧（不再依赖 umask 兜底）。
	dirPerm  os.FileMode = 0o700
	filePerm os.FileMode = 0o600
)

// Store 是服务端 Blob 字节的访问接口。
type Store interface {
	// Put 幂等写入字节内容（已有同 hash 则跳过），返回实际写入字节数。
	//
	// 实现**必须**校验读入字节的 sha256 等于 hash，不一致时返回 ErrDigestMismatch，
	// 且不得留下最终路径的文件。
	Put(hash string, r io.Reader) (int64, error)
	// Open 打开指定 hash 内容读取流；不存在返回 error。
	Open(hash string) (io.ReadSeekCloser, error)
	// Path 返回内容在磁盘/后端的可读路径（用于流式返回）。
	Path(hash string) (string, error)
	// Delete 删除指定 hash 内容（仅 BlobStore 层；引用计数由 store 管理）。
	Delete(hash string) error
}

// Local 是基于本地文件系统的 BlobStore。
type Local struct {
	dir string
}

// NewLocal 创建本地 Blob 存储，目录为 [dir]/blobs（自动创建）。
func NewLocal(dir string) (*Local, error) {
	base := filepath.Join(dir, "blobs")
	if err := os.MkdirAll(base, dirPerm); err != nil {
		return nil, err
	}
	return &Local{dir: base}, nil
}

// pathOf 由 hash 推导内容路径，并断言结果仍位于存储根之内（BR-52.2）。
//
// 返回 error 时调用方**不得**触盘：「忘记校验」的后果应降级为「该次调用失败」，
// 而不是「任意文件读写」。
func (l *Local) pathOf(hash string) (string, error) {
	var full string
	if len(hash) < 2 {
		full = filepath.Join(l.dir, hash)
	} else {
		full = filepath.Join(l.dir, hash[:2], hash)
	}
	if err := ensureInside(l.dir, full); err != nil {
		return "", err
	}
	return full, nil
}

// ensureInside 断言 full 仍位于 root 之内（Abs 归一后按路径前缀比较）。
//
// 注意 filepath.Join 自身会做 Clean，`..` 会被解析掉，因此**不能**用 Join 的结果
// 反推安全性——必须显式比较前缀。
func ensureInside(root, full string) error {
	rootAbs, err := filepath.Abs(root)
	if err != nil {
		return err
	}
	fullAbs, err := filepath.Abs(full)
	if err != nil {
		return err
	}
	if fullAbs != rootAbs && !strings.HasPrefix(fullAbs, rootAbs+string(os.PathSeparator)) {
		return ErrOutsideRoot
	}
	return nil
}

// Put 幂等写入：若已存在同 hash 直接返回 0（承 ADR-004 的去重语义）。
//
// 与 v0.10.x 的差异（M10-T22 / BR-52.3）：写入临时文件时**同步累算 sha256**，
// 读完后与入参 hash 比对；不一致 → 删除临时文件 + ErrDigestMismatch，
// 不做 rename、不产生最终路径文件。
func (l *Local) Put(hash string, r io.Reader) (int64, error) {
	full, err := l.pathOf(hash)
	if err != nil {
		return 0, err
	}
	if _, err := os.Stat(full); err == nil {
		return 0, nil
	}
	if err := os.MkdirAll(filepath.Dir(full), dirPerm); err != nil {
		return 0, err
	}
	tmp := full + ".tmp"
	f, err := os.OpenFile(tmp, os.O_RDWR|os.O_CREATE|os.O_TRUNC, filePerm)
	if err != nil {
		return 0, err
	}
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, h), r)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(tmp)
		return n, err
	}
	if hex.EncodeToString(h.Sum(nil)) != hash {
		os.Remove(tmp)
		return n, ErrDigestMismatch
	}
	return n, os.Rename(tmp, full)
}

// Open 打开内容读取流。
func (l *Local) Open(hash string) (io.ReadSeekCloser, error) {
	p, err := l.pathOf(hash)
	if err != nil {
		return nil, err
	}
	return os.Open(p)
}

// Path 返回内容路径。
func (l *Local) Path(hash string) (string, error) {
	p, err := l.pathOf(hash)
	if err != nil {
		return "", err
	}
	if _, err := os.Stat(p); err != nil {
		return "", err
	}
	return p, nil
}

// Delete 删除内容文件并清理空分片目录。
func (l *Local) Delete(hash string) error {
	full, err := l.pathOf(hash)
	if err != nil {
		return err
	}
	if err := os.Remove(full); err != nil && !os.IsNotExist(err) {
		return err
	}
	dir := filepath.Dir(full)
	entries, err := os.ReadDir(dir)
	if err == nil && len(entries) == 0 {
		os.Remove(dir) // 忽略清理失败
	}
	return nil
}

var _ Store = (*Local)(nil)

const errNotFound = "blob not found"

var (
	// ErrNotFound 供上层判断内容缺失。
	ErrNotFound = fmt.Errorf(errNotFound)
	// ErrDigestMismatch 表示上传字节与其声明的 sha256 不一致（BR-52.3）。
	ErrDigestMismatch = fmt.Errorf("blob: 内容与声明摘要不一致")
	// ErrOutsideRoot 表示推导出的路径越出存储根（BR-52.2）。
	ErrOutsideRoot = fmt.Errorf("blob: 路径越出存储根")
)
