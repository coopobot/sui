package api

import (
	"testing"
	"time"
)

// M10：大传输路由的超时期限（input-validation.md §8）。
//
// 全局 Read/WriteTimeout 保持 10s 兜底；大传输路由在路由内延长，故这两个期限
// 必须可调且**非法值回落默认**（不给「配置写错就放行」的余地）。
func TestM10TransportWindows(t *testing.T) {
	if got := uploadReadWindow(); got != defaultUploadReadWindow {
		t.Errorf("默认读期限应为 %v，实际 %v", defaultUploadReadWindow, got)
	}
	if got := downloadWriteWindow(); got != defaultDownloadWriteWindow {
		t.Errorf("默认写期限应为 %v，实际 %v", defaultDownloadWriteWindow, got)
	}

	t.Setenv("SUI_UPLOAD_READ_TIMEOUT", "45s")
	if got := uploadReadWindow(); got != 45*time.Second {
		t.Errorf("读期限应取环境变量，实际 %v", got)
	}
	t.Setenv("SUI_DOWNLOAD_WRITE_TIMEOUT", "3m")
	if got := downloadWriteWindow(); got != 3*time.Minute {
		t.Errorf("写期限应取环境变量，实际 %v", got)
	}

	for _, bad := range []string{"", "0", "-5s", "abc"} {
		t.Setenv("SUI_UPLOAD_READ_TIMEOUT", bad)
		if got := uploadReadWindow(); got != defaultUploadReadWindow {
			t.Errorf("非法值 %q 应回落默认，实际 %v", bad, got)
		}
	}
}
