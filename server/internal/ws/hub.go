// Package ws 提供简单的 WebSocket 实时通知。
//
// 当服务端笔记变更时（push/clip），广播 "changed" 消息给所有连接的客户端，
// 客户端据此决定是否触发一次 pull 同步。
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

// Hub 管理所有 WebSocket 连接并广播消息。
type Hub struct {
	mu      sync.RWMutex
	clients map[*websocket.Conn]bool
}

// NewHub 创建一个新的 Hub。
func NewHub() *Hub {
	return &Hub{
		clients: make(map[*websocket.Conn]bool),
	}
}

// Serve 处理 WebSocket 升级与连接生命周期。
//
// M4/BR-35.x：鉴权由上层（api.handleWS）在升级前完成，故进入 Serve 的连接均视为
// 已鉴权，广播只发往此集合。
func (h *Hub) Serve(w http.ResponseWriter, r *http.Request) {
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		OriginPatterns: []string{"*"}, // 允许跨域（鉴权由上层保证）
	})
	if err != nil {
		log.Printf("ws accept error: %v", err)
		return
	}
	defer c.Close(websocket.StatusNormalClosure, "bye")

	h.mu.Lock()
	h.clients[c] = true
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
