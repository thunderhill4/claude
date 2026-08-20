package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"time"
)

// StartDashboardProxy serves the Sympozium dashboard on its own port with the
// vendor top bar hidden and the login token + namespace pre-seeded, so the AI
// tab can embed it as a native-looking console (side panes — Agents, Runs,
// Ensembles, etc. — all keep working). It must be a separate port rather than
// a subpath: the SPA uses absolute /assets and /api/v1 paths that would
// collide with kubeui's own routes.
//
// Like the terminal endpoint, this is unauthenticated (demo platform): anyone
// who can reach the port gets a logged-in console.
func StartDashboardProxy() {
	port := os.Getenv("SYMPOZIUM_CONSOLE_PORT")
	if port == "" {
		port = "8081"
	}
	upstreamRaw := os.Getenv("SYMPOZIUM_DASHBOARD_URL")
	if upstreamRaw == "" {
		upstreamRaw = "http://172.18.255.212:8080"
	}
	upstream, err := url.Parse(upstreamRaw)
	if err != nil {
		log.Printf("console proxy: bad upstream %q: %v", upstreamRaw, err)
		return
	}

	proxy := httputil.NewSingleHostReverseProxy(upstream)
	proxy.FlushInterval = -1 // stream SSE chunks immediately
	origDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		origDirector(req)
		req.Host = upstream.Host
		// Force identity encoding so HTML bodies can be rewritten below.
		req.Header.Del("Accept-Encoding")
	}
	proxy.ModifyResponse = func(resp *http.Response) error {
		if !strings.Contains(resp.Header.Get("Content-Type"), "text/html") {
			return nil
		}
		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			return err
		}
		body = bytes.Replace(body, []byte("</head>"), []byte(consoleInjection()+"</head>"), 1)
		resp.Body = io.NopCloser(bytes.NewReader(body))
		resp.ContentLength = int64(len(body))
		resp.Header.Set("Content-Length", fmt.Sprint(len(body)))
		resp.Header.Del("Content-Encoding")
		return nil
	}

	log.Printf("console proxy listening on :%s → %s", port, upstreamRaw)
	if err := http.ListenAndServe(":"+port, proxy); err != nil {
		log.Printf("console proxy: %v", err)
	}
}

// consoleInjection is prepended to </head> of every proxied HTML page. It
// hides the vendor top bar (header.h-14; the content below is sized
// h-[calc(100vh-3.5rem)] and gets stretched back to full height) and seeds
// localStorage with the login token and namespace before the SPA bundle runs
// (inline scripts execute ahead of module scripts), so the embed needs no
// first-run login or namespace-picker step.
func consoleInjection() string {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tok, _ := json.Marshal(getDashboardToken(ctx))
	ns, _ := json.Marshal(sympoziumNamespace())
	return `<style>
header.h-14{display:none!important}
.h-\[calc\(100vh-3\.5rem\)\]{height:100vh!important}
/* Sidebar logo strip (img[alt=Sympozium] fallback for browsers without :has) */
div.h-14:has(>img[alt="Sympozium"]){display:none!important}
img[alt="Sympozium"]{display:none!important}
</style>
<script>
try{
  localStorage.setItem('sympozium_namespace',` + string(ns) + `);
  var __t=` + string(tok) + `;
  if(__t){localStorage.setItem('sympozium_token',__t);}
}catch(e){}
</script>
`
}
