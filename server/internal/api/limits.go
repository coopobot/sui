package api

import (
	"errors"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// 请求体与条目上限（M10-T25 / BR-52.5，见 input-validation.md §8）。
//
// 默认值可用环境变量覆盖；取值非法（非数字 / <= 0）一律回落默认值——
// 不给「配置写错就放行」的余地。
const (
	defaultMaxBodyBytes    = 8 << 20  // 8 MiB：POST /api/v1/clips、/api/v1/sync/push
	defaultMaxBlobBytes    = 32 << 20 // 32 MiB：单个 blob（PUT /api/v1/blobs/{hash}）
	defaultMaxRefreshBytes = 4 << 10  // 4 KiB：POST /api/v1/refresh（只需装一个令牌）
	defaultMaxPushItems    = 500      // sync/push 单次条目数上限
)

// maxBodyBytes 返回 clips / sync.push 的请求体上限（SUI_MAX_BODY_BYTES）。
func maxBodyBytes() int64 { return envInt64("SUI_MAX_BODY_BYTES", defaultMaxBodyBytes) }

// maxBlobBytes 返回单 blob 上限（SUI_MAX_BLOB_BYTES）。
func maxBlobBytes() int64 { return envInt64("SUI_MAX_BLOB_BYTES", defaultMaxBlobBytes) }

// maxRefreshBodyBytes 返回 /api/v1/refresh 的请求体上限（SUI_MAX_REFRESH_BYTES）。
func maxRefreshBodyBytes() int64 { return envInt64("SUI_MAX_REFRESH_BYTES", defaultMaxRefreshBytes) }

// maxPushItems 返回 sync/push 单次条目数上限（SUI_MAX_PUSH_ITEMS）。
func maxPushItems() int { return int(envInt64("SUI_MAX_PUSH_ITEMS", defaultMaxPushItems)) }

// 大传输路由的超时期限（input-validation.md §8）。
//
// 全局 `ReadTimeout` / `WriteTimeout` 为 10s——那是**连接级兜底**（防慢速请求 / 慢读），
// 但 32 MiB 附件在慢链路上远超 10s。此处在**路由内**按需延长，而不是放大全局兜底。
const (
	defaultUploadReadWindow    = 120 * time.Second
	defaultDownloadWriteWindow = 120 * time.Second
)

// uploadReadWindow 返回大请求体路由的读期限（SUI_UPLOAD_READ_TIMEOUT）。
func uploadReadWindow() time.Duration {
	return envDuration("SUI_UPLOAD_READ_TIMEOUT", defaultUploadReadWindow)
}

// downloadWriteWindow 返回流式下载路由的写期限（SUI_DOWNLOAD_WRITE_TIMEOUT）。
func downloadWriteWindow() time.Duration {
	return envDuration("SUI_DOWNLOAD_WRITE_TIMEOUT", defaultDownloadWriteWindow)
}

// extendReadDeadline 为大请求体路由延长**读**期限。
//
// 失败静默忽略：实现不支持时保持全局兜底，安全性不变（不因延长失败而放行任何东西）。
func extendReadDeadline(w http.ResponseWriter) {
	_ = http.NewResponseController(w).SetReadDeadline(time.Now().Add(uploadReadWindow()))
}

// extendWriteDeadline 为流式下载 / 大响应路由延长**写**期限。
func extendWriteDeadline(w http.ResponseWriter) {
	_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(downloadWriteWindow()))
}

func envInt64(key string, def int64) int64 {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return def
	}
	v, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || v <= 0 {
		return def
	}
	return v
}

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

// isTooLarge 报告 err 是否由 http.MaxBytesReader 的限长触发（用于映射 413）。
func isTooLarge(err error) bool {
	var maxErr *http.MaxBytesError
	return errors.As(err, &maxErr)
}
