// Package memlimit 决定 Go 运行时的**软内存上限**（等价 GOMEMLIMIT / debug.SetMemoryLimit）。
//
// 优先级（v0.22.4 / 内存治理，见 technology/adr/048）：
//  1. 显式 `SUI_MEMORY_LIMIT`（如 `512MiB`；`0` / `off` 关闭）；
//  2. 容器 cgroup 限额（v2 `memory.max` / v1 `memory.limit_in_bytes`）的 90%；
//  3. 物理内存（`/proc/meminfo` MemTotal）的 50%。
//
// 作用：让 GC 在接近上限时提前加力，把「堆按 GOGC 翻倍增长」的峰值压住，降低被内核
// OOM Killer 选中的概率。它是**软**限制：不会杀死进程，也拦不住单次大分配（只改变 GC 节奏）。
package memlimit

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Env 是显式上限的环境变量名。
const Env = "SUI_MEMORY_LIMIT"

// Source 说明上限来源（写进启动日志，便于现场核对）。
type Source string

const (
	// SourceEnv 表示来自显式环境变量。
	SourceEnv Source = "SUI_MEMORY_LIMIT"
	// SourceCgroup 表示按容器 cgroup 限额推导。
	SourceCgroup Source = "cgroup*90%"
	// SourceMemTotal 表示按物理内存推导。
	SourceMemTotal Source = "MemTotal*50%"
	// SourceNone 表示不设限。
	SourceNone Source = "none"
)

// minLimit 是接受的最小上限：再低只会让 GC 空转，不如不设。
const minLimit = 64 << 20

// Files 抽象外部文件读取（测试注入；生产用 [OSFiles]）。
type Files interface {
	ReadFile(name string) ([]byte, error)
}

// OSFiles 读取真实文件系统。
type OSFiles struct{}

// ReadFile 读取 name（`/proc`、`/sys` 下的伪文件）。
func (OSFiles) ReadFile(name string) ([]byte, error) { return os.ReadFile(name) }

// Resolve 返回软上限（字节；0 = 不设限）与来源。
//
// raw 为空 / 非法时继续向 cgroup 与物理内存回落——与既有 envInt64 的「配置写错即回落默认」
// 口径一致，不给「写错就放行 / 就禁用」的余地。
func Resolve(raw string, files Files) (int64, Source) {
	if files == nil {
		files = OSFiles{}
	}
	if v, ok := parseLimit(raw); ok {
		if v <= 0 {
			return 0, SourceNone
		}
		return v, SourceEnv
	}
	if v := cgroupLimit(files); v > 0 {
		return v, SourceCgroup
	}
	if v := memTotalLimit(files); v > 0 {
		return v, SourceMemTotal
	}
	return 0, SourceNone
}

// parseLimit 解析形如 `512MiB` / `512MB` / `536870912` / `0` / `off` 的取值。
//
// 返回 ok=false 表示「没写或写错」（交由调用方继续回落）；ok=true 且 v=0 表示**显式关闭**。
func parseLimit(raw string) (int64, bool) {
	s := strings.ToLower(strings.TrimSpace(raw))
	if s == "" {
		return 0, false
	}
	switch s {
	case "0", "off", "none", "unlimited", "false", "disabled":
		return 0, true
	}
	i := 0
	for i < len(s) && (s[i] >= '0' && s[i] <= '9' || s[i] == '.') {
		i++
	}
	if i == 0 {
		return 0, false
	}
	mult, ok := unitMultiplier(strings.TrimSpace(s[i:]))
	if !ok {
		return 0, false
	}
	f, err := strconv.ParseFloat(s[:i], 64)
	if err != nil || f <= 0 {
		return 0, false
	}
	v := int64(f * float64(mult))
	if v < minLimit {
		v = minLimit
	}
	return v, true
}

func unitMultiplier(unit string) (int64, bool) {
	switch unit {
	case "", "b", "byte", "bytes":
		return 1, true
	case "k", "kb", "kib":
		return 1 << 10, true
	case "m", "mb", "mib":
		return 1 << 20, true
	case "g", "gb", "gib":
		return 1 << 30, true
	case "t", "tb", "tib":
		return 1 << 40, true
	}
	return 0, false
}

// cgroupLimit 读取本进程所属 cgroup（含各级父 cgroup）的内存限额并取 90%。
//
// 同时支持 v2（`/sys/fs/cgroup/<path>/memory.max`）与 v1
// （`/sys/fs/cgroup/memory/<path>/memory.limit_in_bytes`）；「max」/超大值视为不限。
func cgroupLimit(files Files) int64 {
	data, err := files.ReadFile("/proc/self/cgroup")
	if err != nil {
		return cgroupLimitAt(files, "/sys/fs/cgroup", true) // 退化：只看根 cgroup
	}
	best := int64(-1)
	for _, line := range strings.Split(string(data), "\n") {
		parts := strings.SplitN(strings.TrimSpace(line), ":", 3)
		if len(parts) != 3 {
			continue
		}
		ctrl, path := parts[1], parts[2]
		switch {
		case ctrl == "":
			// v2：`0::/system.slice/sui.service`
			best = minPositive(best, walkLimits(files, "/sys/fs/cgroup", path, "memory.max", true))
		case strings.Contains(","+ctrl+",", ",memory,"):
			// v1：`5:memory:/docker/<id>`
			best = minPositive(best, walkLimits(files, "/sys/fs/cgroup/memory", path, "memory.limit_in_bytes", false))
		}
	}
	if best > 0 {
		return int64(float64(best) * 0.9)
	}
	return 0
}

func cgroupLimitAt(files Files, root string, v2 bool) int64 {
	file := "memory.limit_in_bytes"
	if v2 {
		file = "memory.max"
	}
	v := walkLimits(files, root, "/", file, v2)
	if v <= 0 {
		return 0
	}
	return int64(float64(v) * 0.9)
}

// walkLimits 从 cgroup 路径逐级向上读到根，返回其中**最小**的有效限额（0 = 无限制）。
func walkLimits(files Files, root, path, file string, v2 bool) int64 {
	if path == "" {
		path = "/"
	}
	best := int64(-1)
	cur := strings.TrimSuffix(path, "/")
	for {
		name := root + cur + "/" + file
		if data, err := files.ReadFile(name); err == nil {
			best = minPositive(best, parseCgroupValue(string(data), v2))
		}
		if cur == "" || cur == "/" {
			break
		}
		if i := strings.LastIndex(cur, "/"); i >= 0 {
			cur = cur[:i]
		} else {
			cur = ""
		}
	}
	if best <= 0 {
		return 0
	}
	return best
}

// parseCgroupValue 解析 cgroup 限额值：`max` / `-1` / 超大值（v1 用 0x7FFFFFFFFFFFF000 表示不限）→ 0。
func parseCgroupValue(raw string, v2 bool) int64 {
	s := strings.TrimSpace(raw)
	if s == "" || s == "max" {
		return 0
	}
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil || v <= 0 {
		return 0
	}
	// v1 的「不限」哨兵；v2 不会有这个值，但一并挡掉更安全。
	if v >= 1<<60 {
		return 0
	}
	if v2 && v > 1<<50 {
		return 0
	}
	return v
}

// memTotalLimit 读取物理内存总量并取 50%。
func memTotalLimit(files Files) int64 {
	data, err := files.ReadFile("/proc/meminfo")
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(line, "MemTotal:") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			return 0
		}
		kb, err := strconv.ParseInt(fields[1], 10, 64)
		if err != nil || kb <= 0 {
			return 0
		}
		v := kb * 1024 / 2
		if v < minLimit {
			return 0
		}
		return v
	}
	return 0
}

func minPositive(a, b int64) int64 {
	if b <= 0 {
		return a
	}
	if a <= 0 {
		return b
	}
	if b < a {
		return b
	}
	return a
}

// HumanBytes 把字节数格式化成便于日志阅读的 MiB / GiB。
func HumanBytes(n int64) string {
	switch {
	case n <= 0:
		return "unlimited"
	case n >= 1<<30 && n%(1<<30) == 0:
		return fmt.Sprintf("%dGiB", n>>30)
	case n >= 1<<20:
		return fmt.Sprintf("%dMiB", n>>20)
	case n >= 1<<10:
		return fmt.Sprintf("%dKiB", n>>10)
	default:
		return fmt.Sprintf("%dB", n)
	}
}
