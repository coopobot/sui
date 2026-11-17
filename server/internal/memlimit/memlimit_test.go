package memlimit

import (
	"errors"
	"testing"
)

// fakeFiles 以内存表模拟 /proc 与 /sys。
type fakeFiles map[string]string

func (f fakeFiles) ReadFile(name string) ([]byte, error) {
	if v, ok := f[name]; ok {
		return []byte(v), nil
	}
	return nil, errors.New("not found")
}

func TestParseLimit(t *testing.T) {
	cases := []struct {
		raw  string
		want int64
		ok   bool
	}{
		{"", 0, false},
		{"  ", 0, false},
		{"abc", 0, false},
		{"512MiB", 512 << 20, true},
		{"512MB", 512 << 20, true},
		{"512m", 512 << 20, true},
		{"1GiB", 1 << 30, true},
		{"1.5GiB", 1536 << 20, true},
		{"104857600", 100 << 20, true},
		{"0", 0, true},
		{"off", 0, true},
		{"16MiB", minLimit, true}, // 低于下限抬到 64MiB
		{"512X", 0, false},
	}
	for _, c := range cases {
		got, ok := parseLimit(c.raw)
		if ok != c.ok || got != c.want {
			t.Errorf("parseLimit(%q) = (%d,%v), want (%d,%v)", c.raw, got, ok, c.want, c.ok)
		}
	}
}

func TestResolveEnvWins(t *testing.T) {
	fs := fakeFiles{
		"/proc/self/cgroup":         "0::/system.slice/sui.service\n",
		"/sys/fs/cgroup/memory.max": "268435456\n",
	}
	got, src := Resolve("1GiB", fs)
	if got != 1<<30 || src != SourceEnv {
		t.Fatalf("Resolve env = (%d,%s), want (1GiB,%s)", got, src, SourceEnv)
	}
}

func TestResolveEnvDisables(t *testing.T) {
	fs := fakeFiles{"/proc/self/cgroup": "0::/\n", "/sys/fs/cgroup/memory.max": "268435456\n"}
	got, src := Resolve("off", fs)
	if got != 0 || src != SourceNone {
		t.Fatalf("Resolve(off) = (%d,%s), want (0,%s)", got, src, SourceNone)
	}
}

func TestResolveCgroupV2(t *testing.T) {
	fs := fakeFiles{
		"/proc/self/cgroup":                                  "0::/system.slice/sui.service\n",
		"/sys/fs/cgroup/memory.max":                          "max\n",        // 根不限
		"/sys/fs/cgroup/system.slice/memory.max":             "1073741824\n", // 父级 1GiB
		"/sys/fs/cgroup/system.slice/sui.service/memory.max": "max\n",        // 自身不限
	}
	got, src := Resolve("", fs)
	if src != SourceCgroup {
		t.Fatalf("source = %s, want %s", src, SourceCgroup)
	}
	if want := int64(1073741824) * 9 / 10; got != want {
		t.Fatalf("limit = %d, want %d", got, want)
	}
}

func TestResolveCgroupV1(t *testing.T) {
	fs := fakeFiles{
		"/proc/self/cgroup":                                         "5:memory:/docker/abc123\n",
		"/sys/fs/cgroup/memory/memory.limit_in_bytes":               "9223372036854771712\n", // 不限哨兵
		"/sys/fs/cgroup/memory/docker/memory.limit_in_bytes":        "max\n",
		"/sys/fs/cgroup/memory/docker/abc123/memory.limit_in_bytes": "536870912\n",
	}
	got, src := Resolve("", fs)
	if src != SourceCgroup {
		t.Fatalf("source = %s, want %s", src, SourceCgroup)
	}
	if want := int64(536870912) * 9 / 10; got != want {
		t.Fatalf("limit = %d, want %d", got, want)
	}
}

func TestResolveMemTotalFallback(t *testing.T) {
	fs := fakeFiles{
		"/proc/self/cgroup":         "0::/\n",
		"/sys/fs/cgroup/memory.max": "max\n",
		"/proc/meminfo":             "MemTotal:        2048000 kB\nMemFree: 100 kB\n",
	}
	got, src := Resolve("", fs)
	if src != SourceMemTotal {
		t.Fatalf("source = %s, want %s", src, SourceMemTotal)
	}
	if want := int64(2048000) * 1024 / 2; got != want {
		t.Fatalf("limit = %d, want %d", got, want)
	}
}

func TestResolveNoFiles(t *testing.T) {
	got, src := Resolve("", fakeFiles{})
	if got != 0 || src != SourceNone {
		t.Fatalf("Resolve empty = (%d,%s), want (0,%s)", got, src, SourceNone)
	}
}

func TestHumanBytes(t *testing.T) {
	cases := map[int64]string{
		0:         "unlimited",
		512 << 20: "512MiB",
		1 << 30:   "1GiB",
		1024:      "1KiB",
	}
	for n, want := range cases {
		if got := HumanBytes(n); got != want {
			t.Errorf("HumanBytes(%d) = %q, want %q", n, got, want)
		}
	}
}
