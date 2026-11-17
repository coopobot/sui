package api

import (
	"context"
	"testing"
	"time"
)

func TestPullGateSerializes(t *testing.T) {
	g := newPullGate(1)
	rel, ok := g.acquire(context.Background(), time.Second)
	if !ok {
		t.Fatal("第一个 pull 应拿到槽位")
	}
	start := time.Now()
	if _, ok := g.acquire(context.Background(), 50*time.Millisecond); ok {
		t.Fatal("槽位已满时不应再拿得到")
	}
	if d := time.Since(start); d < 40*time.Millisecond {
		t.Fatalf("等待时间过短：%v", d)
	}
	rel()
	if rel2, ok := g.acquire(context.Background(), 50*time.Millisecond); !ok {
		t.Fatal("释放后应能再拿到")
	} else {
		rel2()
	}
}

func TestPullGateDisabled(t *testing.T) {
	for _, n := range []int{0, -1} {
		g := newPullGate(n)
		r1, ok1 := g.acquire(context.Background(), 10*time.Millisecond)
		r2, ok2 := g.acquire(context.Background(), 10*time.Millisecond)
		if !ok1 || !ok2 {
			t.Fatalf("n=%d 时不应限流", n)
		}
		r1()
		r2()
	}
	var nilGate *pullGate
	if _, ok := nilGate.acquire(context.Background(), time.Millisecond); !ok {
		t.Fatal("nil gate 不应限流")
	}
}

func TestPullGateContextCanceled(t *testing.T) {
	g := newPullGate(1)
	rel, _ := g.acquire(context.Background(), time.Second)
	defer rel()
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(20 * time.Millisecond)
		cancel()
	}()
	if _, ok := g.acquire(ctx, 5*time.Second); ok {
		t.Fatal("ctx 取消后不应拿到槽位")
	}
}

func TestPullMaxConcurrentEnv(t *testing.T) {
	cases := map[string]int{
		"":    defaultPullMaxConcurrent,
		"2":   2,
		"0":   0,
		"-3":  0,
		"abc": defaultPullMaxConcurrent,
		" 1 ": 1,
	}
	for raw, want := range cases {
		t.Setenv("SUI_PULL_MAX_CONCURRENT", raw)
		if got := pullMaxConcurrent(); got != want {
			t.Errorf("pullMaxConcurrent(%q) = %d, want %d", raw, got, want)
		}
	}
}
