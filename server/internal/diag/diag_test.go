package diag

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestMemLogInterval(t *testing.T) {
	cases := map[string]time.Duration{
		"":    DefaultMemLogInterval,
		"0":   0,
		"off": 0,
		"abc": DefaultMemLogInterval,
		"30s": 30 * time.Second,
		"-5m": DefaultMemLogInterval,
		"10m": 10 * time.Minute,
	}
	for raw, want := range cases {
		t.Setenv(MemLogIntervalEnv, raw)
		if got := MemLogInterval(); got != want {
			t.Errorf("MemLogInterval(%q) = %v, want %v", raw, got, want)
		}
	}
}

func TestLogMemoryDoesNotPanic(t *testing.T) {
	LogMemory()
}

func TestRunMemLogStopsOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		RunMemLog(ctx, 10*time.Millisecond)
		close(done)
	}()
	time.Sleep(30 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("RunMemLog 未在 ctx 取消后返回")
	}
}

func TestStartPProfServesIndex(t *testing.T) {
	srv, addr, err := StartPProf("127.0.0.1:0")
	if err != nil {
		t.Fatalf("StartPProf: %v", err)
	}
	defer srv.Close()

	resp, err := http.Get("http://" + addr + "/debug/pprof/")
	if err != nil {
		t.Fatalf("GET pprof: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if !strings.Contains(string(body), "goroutine") {
		t.Fatalf("pprof index 未包含 goroutine 段（%d bytes）", len(body))
	}
}

func TestStartPProfBadAddr(t *testing.T) {
	if _, _, err := StartPProf("127.0.0.1:99999"); err == nil {
		t.Fatal("非法端口应返回错误")
	}
}
