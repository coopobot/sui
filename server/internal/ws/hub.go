// Package ws 提供简单的 WebSocket 实时通知。
//
// 当服务端笔记变更时（push/clip），广播 "changed" 消息给所有连接的客户端，
// 客户端据此决定是否触发一次 pull 同步。
//
// M10（auth.md §4.5）：连接与**会话**绑定，会话被吊销时主动关闭其连接（撤销即时生效）；
// 鉴权令牌走请求头 / 子协议，不再使用查询串。
package ws

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"nhooyr.io/websocket"
)

// SubprotocolPrefix 是浏览器端承载访问令牌的 WebSocket 子协议前缀（auth.md §4.5）。
//
// 浏览器 WebSocket API 无法自定义请求头，故以 `Sec-WebSocket-Protocol: bearer.<令牌>`
// 传递；服务端必须在 AcceptOptions.Subprotocols 中**回选同一值**，浏览器才接受握手。
const SubprotocolPrefix = "bearer."

// Hub 管理所有 WebSocket 连接并广播消息。
type Hub struct {
	mu       sync.RWMutex
	clients  map[*websocket.Conn]string // conn → 会话 id
	patterns []string
}

// NewHub 创建一个新的 Hub。
func NewHub() *Hub {
	return &Hub{
		clients: make(map[*websocket.Conn]string),
	}
}

// SetOriginPatterns 设置可接受的跨域 Origin 模式（M10-T23 / BR-52.5）。
//
// 必须在开始监听前调用（Router 组装期）。空列表 = **只接受同源 Origin**
// （nhooyr/websocket 在 OriginPatterns 为空时按请求 Host 做同源校验），
// 即「未配置白名单时不接受跨域 Origin」。
func (h *Hub) SetOriginPatterns(patterns []string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.patterns = patterns
}

// Serve 处理 WebSocket 升级与连接生命周期。
//
// sessionID 为升级前鉴权命中的会话（§4.5：连接与会话绑定）；
// subprotocol 为需要回选的子协议（浏览器端非空，否则传空串）。
// 鉴权由上层（api.handleWS）在升级前完成，故进入 Serve 的连接均视为已鉴权。
func (h *Hub) Serve(w http.ResponseWriter, r *http.Request, sessionID, subprotocol string) {
	h.mu.RLock()
	patterns := h.patterns
	h.mu.RUnlock()

	opts := &websocket.AcceptOptions{OriginPatterns: patterns}
	if subprotocol != "" {
		opts.Subprotocols = []string{subprotocol}
	}
	c, err := websocket.Accept(w, r, opts)
	if err != nil {
		log.Printf("ws accept error: %v", err)
		return
	}
	defer c.Close(websocket.StatusNormalClosure, "bye")

	h.mu.Lock()
	h.clients[c] = sessionID
	h.mu.Unlock()

	defer func() {
		h.mu.Lock()
		delete(h.clients, c)
		h.mu.Unlock()
	}()

	// 读循环（客户端心跳等），忽略消息只保持连接
	for {
		_, _, err := c.Read(r.Context())
		if err != nil {
			break
		}
	}
}

// CloseSession 关闭给定会话的全部 WebSocket 连接，返回被关闭的连接数。
//
// 撤销即时生效（BR-49.4）：登出 / logout-all / 刷新令牌重放判定之后，旧连接不应再收到
// 变更通知，否则「止损」形同虚设。
func (h *Hub) CloseSession(sessionIDs ...string) int {
	want := make(map[string]bool, len(sessionIDs))
	for _, id := range sessionIDs {
		if id != "" {
			want[id] = true
		}
	}
	if len(want) == 0 {
		return 0
	}

	h.mu.Lock()
	targets := make([]*websocket.Conn, 0, len(want))
	for c, sid := range h.clients {
		if want[sid] {
			targets = append(targets, c)
			delete(h.clients, c)
		}
	}
	h.mu.Unlock()

	for _, c := range targets {
		_ = c.Close(websocket.StatusPolicyViolation, "session revoked")
	}
	return len(targets)
}

// Broadcast 向所有连接的客户端广播一条 JSON 消息。
func (h *Hub) Broadcast(msg any) {
	data, err := json.Marshal(msg)
	if err != nil {
		return
	}

	h.mu.RLock()
	defer h.mu.RUnlock()

	for c := range h.clients {
		go func(conn *websocket.Conn) {
			// 用背景 context 发送，超时则放弃
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = conn.Write(ctx, websocket.MessageText, data)
		}(c)
	}
}

// NotifyChange 发送"笔记有变更"通知。
func (h *Hub) NotifyChange() {
	h.Broadcast(map[string]any{"type": "changed"})
}
