package handlers

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"os/exec"
	"time"

	"github.com/creack/pty"
	"github.com/gorilla/websocket"
)

// HandleTerminal upgrades to a WebSocket and bridges it to a local PTY
// running the user's shell — one shell per connection (the frontend opens one
// connection per terminal tab). Client → server messages are JSON:
//
//	{"type":"input","data":"<keystrokes>"}
//	{"type":"resize","cols":120,"rows":32}
//
// Server → client messages are raw PTY output as binary frames.
//
// Like the rest of this backend, the endpoint is unauthenticated (demo
// platform) — it grants a shell wherever the backend runs: the developer's
// host under run-ui.sh, or the backend pod when deployed in-cluster.
// GET /api/v1/terminal (WebSocket)

var terminalUpgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	CheckOrigin: func(r *http.Request) bool {
		switch r.Header.Get("Origin") {
		case "", "http://localhost:5173", "http://127.0.0.1:5173", "http://172.18.255.211":
			return true
		}
		// Same-origin (e.g. LAN access to the Vite dev server via --host).
		return r.Header.Get("Origin") == "http://"+r.Host || r.Header.Get("Origin") == "https://"+r.Host
	},
}

type terminalClientMsg struct {
	Type string `json:"type"`
	Data string `json:"data,omitempty"`
	Cols uint16 `json:"cols,omitempty"`
	Rows uint16 `json:"rows,omitempty"`
}

func HandleTerminal(w http.ResponseWriter, r *http.Request) {
	conn, err := terminalUpgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("terminal: upgrade failed: %v", err)
		return
	}
	defer conn.Close()

	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/bash"
	}
	cmd := exec.Command(shell)
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")
	if dir := os.Getenv("CLAUDE_DIR"); dir != "" {
		cmd.Dir = dir
	}

	ptmx, err := pty.Start(cmd)
	if err != nil {
		log.Printf("terminal: pty start failed: %v", err)
		conn.WriteMessage(websocket.TextMessage, []byte("failed to start shell: "+err.Error()+"\r\n"))
		return
	}
	defer func() {
		ptmx.Close()
		cmd.Process.Kill()
		cmd.Wait()
	}()

	// PTY → WebSocket. Sole writer to conn, so no write lock needed.
	ptyDone := make(chan struct{})
	go func() {
		defer close(ptyDone)
		buf := make([]byte, 8192)
		for {
			n, err := ptmx.Read(buf)
			if n > 0 {
				if werr := conn.WriteMessage(websocket.BinaryMessage, buf[:n]); werr != nil {
					return
				}
			}
			if err != nil {
				conn.WriteControl(websocket.CloseMessage,
					websocket.FormatCloseMessage(websocket.CloseNormalClosure, "shell exited"),
					time.Now().Add(time.Second))
				return
			}
		}
	}()

	// WebSocket → PTY.
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			break
		}
		var msg terminalClientMsg
		if err := json.Unmarshal(data, &msg); err != nil {
			continue
		}
		switch msg.Type {
		case "input":
			if _, err := ptmx.Write([]byte(msg.Data)); err != nil {
				break
			}
		case "resize":
			if msg.Cols > 0 && msg.Rows > 0 {
				pty.Setsize(ptmx, &pty.Winsize{Cols: msg.Cols, Rows: msg.Rows})
			}
		}
	}
	// Deferred cleanup kills the shell, which unblocks the PTY reader.
}
