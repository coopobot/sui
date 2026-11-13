package blob

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// 分片断点续传（M20 / FR-119 / ADR-044）。
//
// 布局（仍在内容寻址根内）：
//
//	blobs/<hash[:2]>/<hash>.upload/
//	  meta.json
//	  part-00000
//	  ...
//
// 分片只在 complete 时按序流式拼接；服务端不把整文件读入内存。

const (
	// ChunkMinSize / ChunkMaxSize 是客户端可声明的分片大小范围（含）。
	ChunkMinSize int64 = 1 << 20
	ChunkMaxSize int64 = 32 << 20
	// ChunkUploadTTL 是未完成会话的保留时长。
	ChunkUploadTTL = 24 * time.Hour

	chunkMetaFile   = "meta.json"
	chunkDirSuffix  = ".upload"
	chunkPartPrefix = "part-"
)

// ErrUploadNotFound 表示 hash 没有进行中的分片会话。
var ErrUploadNotFound = errors.New("upload session not found")

// ErrUploadMismatch 表示同一 hash 的会话参数与已存在会话不一致。
var ErrUploadMismatch = errors.New("upload session mismatch")

// ErrChunkOutOfRange 表示 index 超出会话范围。
var ErrChunkOutOfRange = errors.New("chunk index out of range")

// ErrChunkSizeMismatch 表示分片实际字节数不符合会话声明。
var ErrChunkSizeMismatch = errors.New("chunk size mismatch")

// MissingChunksError 由 CompleteUpload 返回，携带缺失分片序号。
type MissingChunksError struct{ Missing []int }

func (e *MissingChunksError) Error() string {
	return fmt.Sprintf("missing chunks: %v", e.Missing)
}

// ChunkMeta 是分片会话的元数据。
type ChunkMeta struct {
	Size      int64  `json:"size"`
	ChunkSize int64  `json:"chunkSize"`
	CreatedAt string `json:"createdAt"`
}

// ChunkStatus 是 init / status 的返回。
type ChunkStatus struct {
	Size      int64 `json:"size"`
	ChunkSize int64 `json:"chunkSize"`
	Uploaded  []int `json:"uploaded"`
	Complete  bool  `json:"complete"`
}

// ChunkedStore 是本地分片上传能力（S3 等后端可另行实现）。
type ChunkedStore interface {
	InitUpload(hash string, size, chunkSize int64) (ChunkStatus, error)
	UploadStatus(hash string) (ChunkStatus, error)
	PutChunk(hash string, index int64, r io.Reader) (int64, error)
	CompleteUpload(hash string) (int64, error)
	AbortUpload(hash string) error
	CleanupUploads(now time.Time) error
}

// chunkCount 返回分片数（size>0 时至少 1）。
func chunkCount(size, chunkSize int64) int {
	if size <= 0 || chunkSize <= 0 {
		return 0
	}
	return int((size + chunkSize - 1) / chunkSize)
}

func (l *Local) uploadDir(hash string) (string, error) {
	full, err := l.pathOf(hash)
	if err != nil {
		return "", err
	}
	return full + chunkDirSuffix, nil
}

func (l *Local) finalPath(hash string) (string, error) { return l.pathOf(hash) }

func (l *Local) loadMeta(hash string) (ChunkMeta, string, error) {
	dir, err := l.uploadDir(hash)
	if err != nil {
		return ChunkMeta{}, "", err
	}
	raw, err := os.ReadFile(filepath.Join(dir, chunkMetaFile))
	if os.IsNotExist(err) {
		return ChunkMeta{}, dir, ErrUploadNotFound
	}
	if err != nil {
		return ChunkMeta{}, dir, err
	}
	var meta ChunkMeta
	if err := json.Unmarshal(raw, &meta); err != nil {
		return ChunkMeta{}, dir, err
	}
	return meta, dir, nil
}

func writeMeta(dir string, meta ChunkMeta) error {
	raw, err := json.Marshal(meta)
	if err != nil {
		return err
	}
	tmp := filepath.Join(dir, chunkMetaFile+".tmp")
	if err := os.WriteFile(tmp, raw, filePerm); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(dir, chunkMetaFile))
}

// InitUpload 创建或复用分片会话；最终文件已存在时直接返回 complete。
func (l *Local) InitUpload(hash string, size, chunkSize int64) (ChunkStatus, error) {
	if size <= 0 || chunkSize < ChunkMinSize || chunkSize > ChunkMaxSize {
		return ChunkStatus{}, ErrChunkSizeMismatch
	}
	if int64(chunkCount(size, chunkSize)) > 100000 {
		return ChunkStatus{}, ErrChunkSizeMismatch
	}
	final, err := l.pathOf(hash)
	if err != nil {
		return ChunkStatus{}, err
	}
	if fi, err := os.Stat(final); err == nil && fi.Mode().IsRegular() {
		return ChunkStatus{Size: fi.Size(), ChunkSize: chunkSize, Uploaded: []int{}, Complete: true}, nil
	}

	dir, err := l.uploadDir(hash)
	if err != nil {
		return ChunkStatus{}, err
	}
	if err := os.MkdirAll(dir, dirPerm); err != nil {
		return ChunkStatus{}, err
	}
	meta, _, err := l.loadMeta(hash)
	switch {
	case errors.Is(err, ErrUploadNotFound):
		meta = ChunkMeta{Size: size, ChunkSize: chunkSize, CreatedAt: time.Now().UTC().Format(time.RFC3339)}
		if err := writeMeta(dir, meta); err != nil {
			return ChunkStatus{}, err
		}
	case err != nil:
		return ChunkStatus{}, err
	case meta.Size != size || meta.ChunkSize != chunkSize:
		return ChunkStatus{}, ErrUploadMismatch
	}
	return l.statusFrom(dir, meta)
}

// UploadStatus 返回当前会话已上传的分片。
func (l *Local) UploadStatus(hash string) (ChunkStatus, error) {
	final, err := l.pathOf(hash)
	if err != nil {
		return ChunkStatus{}, err
	}
	if fi, err := os.Stat(final); err == nil && fi.Mode().IsRegular() {
		return ChunkStatus{Size: fi.Size(), Uploaded: []int{}, Complete: true}, nil
	}
	meta, dir, err := l.loadMeta(hash)
	if err != nil {
		return ChunkStatus{}, err
	}
	return l.statusFrom(dir, meta)
}

func (l *Local) statusFrom(dir string, meta ChunkMeta) (ChunkStatus, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ChunkStatus{}, err
	}
	total := chunkCount(meta.Size, meta.ChunkSize)
	have := make(map[int]bool, total)
	for _, e := range entries {
		name := e.Name()
		if !strings.HasPrefix(name, chunkPartPrefix) || strings.HasSuffix(name, ".tmp") {
			continue
		}
		idx, err := strconv.Atoi(strings.TrimPrefix(name, chunkPartPrefix))
		if err != nil || idx < 0 || idx >= total {
			continue
		}
		have[idx] = true
	}
	uploaded := make([]int, 0, len(have))
	for i := 0; i < total; i++ {
		if have[i] {
			uploaded = append(uploaded, i)
		}
	}
	sort.Ints(uploaded)
	return ChunkStatus{Size: meta.Size, ChunkSize: meta.ChunkSize, Uploaded: uploaded}, nil
}

// PutChunk 写入一个分片（乱序 / 重复幂等），返回实际字节数。
func (l *Local) PutChunk(hash string, index int64, r io.Reader) (int64, error) {
	meta, dir, err := l.loadMeta(hash)
	if err != nil {
		return 0, err
	}
	total := int64(chunkCount(meta.Size, meta.ChunkSize))
	if index < 0 || index >= total {
		return 0, ErrChunkOutOfRange
	}
	expected := meta.ChunkSize
	if index == total-1 {
		expected = meta.Size - index*meta.ChunkSize
	}
	part := filepath.Join(dir, fmt.Sprintf("%s%05d", chunkPartPrefix, index))
	tmp := part + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, filePerm)
	if err != nil {
		return 0, err
	}
	n, copyErr := io.Copy(f, io.LimitReader(r, expected+1))
	closeErr := f.Close()
	if copyErr != nil {
		os.Remove(tmp)
		return 0, copyErr
	}
	if closeErr != nil {
		os.Remove(tmp)
		return 0, closeErr
	}
	if n != expected {
		os.Remove(tmp)
		return 0, ErrChunkSizeMismatch
	}
	if err := os.Rename(tmp, part); err != nil {
		os.Remove(tmp)
		return 0, err
	}
	return n, nil
}

// CompleteUpload 校验全部分片、流式拼接并原子转正。
func (l *Local) CompleteUpload(hash string) (int64, error) {
	final, err := l.finalPath(hash)
	if err != nil {
		return 0, err
	}
	if fi, err := os.Stat(final); err == nil && fi.Mode().IsRegular() {
		return fi.Size(), nil
	}
	meta, dir, err := l.loadMeta(hash)
	if err != nil {
		return 0, err
	}
	total := chunkCount(meta.Size, meta.ChunkSize)
	missing := make([]int, 0)
	for i := 0; i < total; i++ {
		p := filepath.Join(dir, fmt.Sprintf("%s%05d", chunkPartPrefix, i))
		if _, err := os.Stat(p); err != nil {
			missing = append(missing, i)
		}
	}
	if len(missing) > 0 {
		return 0, &MissingChunksError{Missing: missing}
	}
	if err := os.MkdirAll(filepath.Dir(final), dirPerm); err != nil {
		return 0, err
	}
	tmp := final + ".tmp"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, filePerm)
	if err != nil {
		return 0, err
	}
	h := sha256.New()
	for i := 0; i < total; i++ {
		p := filepath.Join(dir, fmt.Sprintf("%s%05d", chunkPartPrefix, i))
		in, err := os.Open(p)
		if err != nil {
			out.Close()
			os.Remove(tmp)
			return 0, err
		}
		_, err = io.Copy(io.MultiWriter(out, h), in)
		in.Close()
		if err != nil {
			out.Close()
			os.Remove(tmp)
			return 0, err
		}
	}
	if err := out.Close(); err != nil {
		os.Remove(tmp)
		return 0, err
	}
	if hex.EncodeToString(h.Sum(nil)) != hash {
		os.Remove(tmp)
		return 0, ErrDigestMismatch
	}
	if err := os.Rename(tmp, final); err != nil {
		os.Remove(tmp)
		return 0, err
	}
	_ = os.RemoveAll(dir)
	return meta.Size, nil
}

// AbortUpload 放弃会话并删除临时目录。
func (l *Local) AbortUpload(hash string) error {
	dir, err := l.uploadDir(hash)
	if err != nil {
		return err
	}
	return os.RemoveAll(dir)
}

// CleanupUploads 清理超过 TTL 的未完成会话；只动 `*.upload` 目录。
func (l *Local) CleanupUploads(now time.Time) error {
	return filepath.WalkDir(l.dir, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if !d.IsDir() || !strings.HasSuffix(path, chunkDirSuffix) {
			return nil
		}
		fi, err := d.Info()
		if err != nil {
			return nil
		}
		metaInfo, merr := os.Stat(filepath.Join(path, chunkMetaFile))
		modified := fi.ModTime()
		if merr == nil {
			modified = metaInfo.ModTime()
		}
		if now.Sub(modified) > ChunkUploadTTL {
			_ = os.RemoveAll(path)
			return filepath.SkipDir
		}
		return nil
	})
}
