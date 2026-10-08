package api

import (
	"errors"
	"net/http"
	"os"
	"strconv"
	"strings"
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

// isTooLarge 报告 err 是否由 http.MaxBytesReader 的限长触发（用于映射 413）。
func isTooLarge(err error) bool {
	var maxErr *http.MaxBytesError
	return errors.As(err, &maxErr)
}
