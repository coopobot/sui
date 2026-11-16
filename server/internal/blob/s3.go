package blob

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/smithy-go"
)

// S3Config 是 S3 兼容后端配置（M22 / ADR-045）。
type S3Config struct {
	Endpoint  string
	Region    string
	Bucket    string
	Prefix    string
	AccessKey string
	SecretKey string
	PathStyle bool
	TempDir   string
}

// S3ConfigFromEnv 从环境变量构造配置；密钥不落库。
func S3ConfigFromEnv() S3Config {
	return S3Config{
		Endpoint:  os.Getenv("SUI_S3_ENDPOINT"),
		Region:    envOr("SUI_S3_REGION", "us-east-1"),
		Bucket:    os.Getenv("SUI_S3_BUCKET"),
		Prefix:    envOr("SUI_S3_PREFIX", "sui/"),
		AccessKey: envOr("SUI_S3_ACCESS_KEY", os.Getenv("AWS_ACCESS_KEY_ID")),
		SecretKey: envOr("SUI_S3_SECRET_KEY", os.Getenv("AWS_SECRET_ACCESS_KEY")),
		PathStyle: envBool("SUI_S3_PATH_STYLE", true),
		TempDir:   os.Getenv("SUI_S3_TEMP"),
	}
}

func envOr(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func envBool(key string, def bool) bool {
	v := strings.TrimSpace(strings.ToLower(os.Getenv(key)))
	switch v {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	}
	return def
}

// S3 是基于 S3 兼容对象存储的 BlobStore。
//
// 分片会话仍复用本地 [Local] 临时装配（不引入 S3 Multipart），complete 后
// 通过 PutObject 上传单对象（≤5 GB，ADR-045）。
type S3 struct {
	client  *s3.Client
	bucket  string
	prefix  string
	tempDir string
	chunks  *Local
}

// NewS3 创建 S3 兼容后端并初始化本地分片临时目录。
func NewS3(ctx context.Context, cfg S3Config) (*S3, error) {
	if strings.TrimSpace(cfg.Bucket) == "" {
		return nil, errors.New("S3 bucket 不能为空")
	}
	if cfg.Region == "" {
		cfg.Region = "us-east-1"
	}
	opts := []func(*awsconfig.LoadOptions) error{
		awsconfig.WithRegion(cfg.Region),
	}
	if cfg.AccessKey != "" || cfg.SecretKey != "" {
		opts = append(opts, awsconfig.WithCredentialsProvider(
			credentials.NewStaticCredentialsProvider(cfg.AccessKey, cfg.SecretKey, ""),
		))
	}
	awsCfg, err := awsconfig.LoadDefaultConfig(ctx, opts...)
	if err != nil {
		return nil, fmt.Errorf("load aws config: %w", err)
	}
	client := s3.NewFromConfig(awsCfg, func(o *s3.Options) {
		if cfg.Endpoint != "" {
			o.BaseEndpoint = aws.String(cfg.Endpoint)
		}
		o.UsePathStyle = cfg.PathStyle
	})

	tempDir := cfg.TempDir
	if tempDir == "" {
		tempDir = filepath.Join(os.TempDir(), "sui-s3-chunks")
	}
	chunks, err := NewLocal(tempDir)
	if err != nil {
		return nil, fmt.Errorf("init chunk temp: %w", err)
	}
	return &S3{
		client:  client,
		bucket:  cfg.Bucket,
		prefix:  normalizePrefix(cfg.Prefix),
		tempDir: tempDir,
		chunks:  chunks,
	}, nil
}

func normalizePrefix(prefix string) string {
	p := strings.TrimSpace(prefix)
	if p == "" {
		return ""
	}
	return strings.TrimSuffix(p, "/") + "/"
}

func (s *S3) key(hash string) string { return s.prefix + hash }

func isS3NotFound(err error) bool {
	var apiErr smithy.APIError
	if errors.As(err, &apiErr) {
		switch apiErr.ErrorCode() {
		case "NoSuchKey", "NotFound", "404", "NoSuchBucket":
			return apiErr.ErrorCode() != "NoSuchBucket"
		}
	}
	return false
}

// Put 先落本地临时文件并校验 sha256，再单对象上传；服务端内存与文件大小解耦。
func (s *S3) Put(hash string, r io.Reader) (int64, error) {
	if _, exists, err := s.Stat(hash); err != nil {
		return 0, err
	} else if exists {
		return 0, nil
	}
	if err := os.MkdirAll(s.tempDir, dirPerm); err != nil {
		return 0, err
	}
	f, err := os.CreateTemp(s.tempDir, "put-*")
	if err != nil {
		return 0, err
	}
	tmp := f.Name()
	defer os.Remove(tmp)

	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, h), r)
	if err != nil {
		f.Close()
		return 0, err
	}
	if hex.EncodeToString(h.Sum(nil)) != hash {
		f.Close()
		return 0, ErrDigestMismatch
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		f.Close()
		return 0, err
	}
	if err := f.Close(); err != nil {
		return 0, err
	}
	f, err = os.Open(tmp)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	_, err = s.client.PutObject(context.Background(), &s3.PutObjectInput{
		Bucket:        aws.String(s.bucket),
		Key:           aws.String(s.key(hash)),
		Body:          f,
		ContentLength: aws.Int64(n),
		ContentType:   aws.String("application/octet-stream"),
	})
	if err != nil {
		return 0, err
	}
	return n, nil
}

// Open 返回对象读取流。
func (s *S3) Open(hash string) (io.ReadCloser, error) {
	out, err := s.client.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(s.key(hash)),
	})
	if err != nil {
		if isS3NotFound(err) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return out.Body, nil
}

// Stat 返回对象大小与是否存在。
func (s *S3) Stat(hash string) (int64, bool, error) {
	out, err := s.client.HeadObject(context.Background(), &s3.HeadObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(s.key(hash)),
	})
	if err != nil {
		if isS3NotFound(err) {
			return 0, false, nil
		}
		return 0, false, err
	}
	if out.ContentLength == nil {
		return 0, true, nil
	}
	return *out.ContentLength, true, nil
}

// Delete 删除对象（幂等）。
func (s *S3) Delete(hash string) error {
	_, err := s.client.DeleteObject(context.Background(), &s3.DeleteObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(s.key(hash)),
	})
	return err
}

// ---- ChunkedStore：本地临时装配，complete 后上传 ----

func (s *S3) InitUpload(hash string, size, chunkSize int64) (ChunkStatus, error) {
	if n, ok, err := s.Stat(hash); err != nil {
		return ChunkStatus{}, err
	} else if ok {
		return ChunkStatus{Size: n, ChunkSize: chunkSize, Uploaded: []int{}, Complete: true}, nil
	}
	return s.chunks.InitUpload(hash, size, chunkSize)
}

func (s *S3) UploadStatus(hash string) (ChunkStatus, error) {
	if n, ok, err := s.Stat(hash); err != nil {
		return ChunkStatus{}, err
	} else if ok {
		return ChunkStatus{Size: n, Uploaded: []int{}, Complete: true}, nil
	}
	return s.chunks.UploadStatus(hash)
}

func (s *S3) PutChunk(hash string, index int64, r io.Reader) (int64, error) {
	return s.chunks.PutChunk(hash, index, r)
}

func (s *S3) CompleteUpload(hash string) (int64, error) {
	size, err := s.chunks.CompleteUpload(hash)
	if err != nil {
		return 0, err
	}
	reader, err := s.chunks.Open(hash)
	if err != nil {
		return 0, err
	}
	if _, err := s.Put(hash, reader); err != nil {
		reader.Close()
		return 0, err
	}
	reader.Close()
	_ = s.chunks.Delete(hash)
	return size, nil
}

func (s *S3) AbortUpload(hash string) error { return s.chunks.AbortUpload(hash) }

func (s *S3) CleanupUploads(now time.Time) error {
	return s.chunks.CleanupUploads(now)
}
