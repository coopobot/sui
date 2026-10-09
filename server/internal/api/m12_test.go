package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"sui/note-server/internal/store"
)

// M12（FR-55 / ADR-019）服务端门禁：**云端实例身份**与「服务端没有该实体」的显式裁决。

func TestM12InstanceIDStableWithinDataDir(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "sui.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	first, err := st.InstanceID()
	if err != nil {
		t.Fatalf("instance id: %v", err)
	}
	if !strings.HasPrefix(first, "inst-") || len(first) != len("inst-")+32 {
		t.Fatalf("实例身份格式不符：%q", first)
	}
	again, err := st.InstanceID()
	if err != nil {
		t.Fatalf("instance id: %v", err)
	}
	if again != first {
		t.Fatalf("同一数据目录内实例身份必须稳定：%q != %q", again, first)
	}
	st.Close()

	// 进程重启（重开同一数据目录）后仍然恒定。
	st2, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("reopen store: %v", err)
	}
	defer st2.Close()
	reopened, err := st2.InstanceID()
	if err != nil {
		t.Fatalf("instance id after reopen: %v", err)
	}
	if reopened != first {
		t.Fatalf("重启后身份不得变化：%q != %q", reopened, first)
	}
}

func TestM12InstanceIDChangesAfterRebuild(t *testing.T) {
	open := func(t *testing.T) (*store.Store, string) {
		t.Helper()
		st, err := store.Open(filepath.Join(t.TempDir(), "sui.db"))
		if err != nil {
			t.Fatalf("open store: %v", err)
		}
		t.Cleanup(func() { st.Close() })
		id, err := st.InstanceID()
		if err != nil {
			t.Fatalf("instance id: %v", err)
		}
		return st, id
	}
	_, a := open(t)
	_, b := open(t)
	if a == b {
		t.Fatalf("更换数据目录 / 重建库后实例身份**必须**变化（否则无法识别换库）")
	}
}

func TestM12PingExposesInstanceIDOnlyWhenAuthed(t *testing.T) {
	srv, st, _ := newM10Server(t)

	// 匿名探测：**不得**返回 instanceId（避免对公网暴露稳定指纹）。
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/ping", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("ping status=%d", rec.Code)
	}
	if strings.Contains(rec.Body.String(), "instanceId") {
		t.Fatalf("匿名 ping 不得返回实例身份：%s", rec.Body.String())
	}

	pair, err := st.CreateUser("u", "p")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	want, err := st.InstanceID()
	if err != nil {
		t.Fatalf("instance id: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/v1/ping", nil)
	req.Header.Set("Authorization", "Bearer "+pair.AccessToken)
	rec2 := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec2, req)
	if rec2.Code != http.StatusOK {
		t.Fatalf("authed ping status=%d body=%s", rec2.Code, rec2.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(rec2.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode ping: %v", err)
	}
	if got, _ := body["instanceId"].(string); got != want {
		t.Fatalf("鉴权后应返回实例身份：got %q want %q（body=%s）", got, want, rec2.Body.String())
	}
}

func TestM12PushNotFoundSignalAndSelfHeal(t *testing.T) {
	srv, st, _ := newM10Server(t)
	pair, err := st.CreateUser("u", "p")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	push := func(t *testing.T, baseVersion int) map[string]any {
		t.Helper()
		body := `{"clientId":"c","items":[{"id":"n-1","title":"t","content":"c",` +
			`"baseVersion":` + itoa(baseVersion) + `,"version":` + itoa(baseVersion) + `,` +
			`"isDeleted":false,"archived":false,"sourceDevice":"dev"}]}`
		req := httptest.NewRequest(http.MethodPost, "/api/v1/sync/push", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+pair.AccessToken)
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		srv.Router().ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("push status=%d body=%s", rec.Code, rec.Body.String())
		}
		var resp struct {
			Results []map[string]any `json:"results"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
			t.Fatalf("decode push: %v", err)
		}
		if len(resp.Results) != 1 {
			t.Fatalf("结果条数不符：%s", rec.Body.String())
		}
		return resp.Results[0]
	}

	// 服务端没有该实体 + 客户端基线非 0 → 明确告知 notFound，且 serverVersion **显式为 0**。
	// （这正是 B24-① 的死锁点：旧实现只回 accepted=false，客户端无从判断。）
	first := push(t, 126)
	if accepted, _ := first["accepted"].(bool); accepted {
		t.Fatalf("服务端没有该实体时不得接受：%+v", first)
	}
	if nf, _ := first["notFound"].(bool); !nf {
		t.Fatalf("必须显式给出 notFound：%+v", first)
	}
	if sv, ok := first["serverVersion"]; !ok || sv.(float64) != 0 {
		t.Fatalf("serverVersion 必须显式为 0（不得因 omitempty 缺字段）：%+v", first)
	}

	// 客户端据此把基线归零后重发 → 直接接受（自愈闭环）。
	second := push(t, 0)
	if accepted, _ := second["accepted"].(bool); !accepted {
		t.Fatalf("基线归零后必须被接受：%+v", second)
	}
	if av, _ := second["appliedVersion"].(float64); av != 1 {
		t.Fatalf("appliedVersion 应为 1：%+v", second)
	}

	// 服务端确实持有了该笔记（后续基线 1 的推送不再 notFound）。
	third := push(t, 1)
	if nf, _ := third["notFound"].(bool); nf {
		t.Fatalf("服务端已持有该笔记，不应再报 notFound：%+v", third)
	}
}

func itoa(v int) string {
	if v == 0 {
		return "0"
	}
	var b []byte
	for v > 0 {
		b = append([]byte{byte('0' + v%10)}, b...)
		v /= 10
	}
	return string(b)
}
