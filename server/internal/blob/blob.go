// Package blob 提供服务端附件字节的对象存储（内容寻址，sha256）。
//
// 默认落在本地磁盘 /data/blobs，sha256 分片目录；通过 BLOB_STORE 环境变量可
// 切到 S3 兼容后端（见设计文档 §10.5）。
package blob

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// Store 是服务端 Blob 字节的访问接口。
type Store interface {
	// Put 幂等写入字节内容（已有同 hash 则跳过），返回实际写入字节数。
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
	if err := os.MkdirAll(base, 0o755); err != nil {
		return nil, err
	}
	return &Local{dir: base}, nil
}

func (l *Local) pathOf(hash string) string {
	if len(hash) < 2 {
		return filepath.Join(l.dir, hash)
	}
	return filepath.Join(l.dir, hash[:2], hash)
}

// Put 幂等写入：若已存在直接返回 0。
func (l *Local) Put(hash string, r io.Reader) (int64, error) {
	if _, err := os.Stat(l.pathOf(hash)); err == nil {
		return 0, nil
	}
	full := l.pathOf(hash)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		return 0, err
	}
	tmp := full + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return 0, err
	}
	n, err := io.Copy(f, r)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(tmp)
		return n, err
	}
	return n, os.Rename(tmp, full)
}

// Open 打开内容读取流。
func (l *Local) Open(hash string) (io.ReadSeekCloser, error) {
	return os.Open(l.pathOf(hash))
}

// Path 返回内容路径。
func (l *Local) Path(hash string) (string, error) {
	p := l.pathOf(hash)
	if _, err := os.Stat(p); err != nil {
		return "", err
	}
	return p, nil
}

// Delete 删除内容文件并清理空分片目录。
func (l *Local) Delete(hash string) error {
	full := l.pathOf(hash)
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

// ErrNotFound 供上层判断内容缺失。
var ErrNotFound = fmt.Errorf(errNotFound)
