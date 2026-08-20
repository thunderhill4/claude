#!/usr/bin/env python3
"""Lab MCP server: exposes this platform's fixed MetalLB IP table as a tool.

Deliberately platform-specific (not something an LLM could hallucinate
correctly) so that a correct answer from the agent proves the tool was
actually called, not guessed.
"""
from fastmcp import FastMCP

mcp = FastMCP("metallb-info")

ASSIGNMENTS = {
    "172.18.255.200": "httpbin-lb (mc-demo, cluster1)",
    "172.18.255.211": "kubeui-frontend",
    "172.18.255.212": "sympozium-apiserver (UI)",
    "172.18.255.213": "cluster2-agent (Sympozium)",
    "172.18.255.214": "target-cluster-agent (Sympozium)",
    "172.18.255.215": "target-cluster API server",
    "172.18.255.216": "target-cluster-nginx proxy",
    "172.18.255.217": "security-agent",
    "172.18.255.218": "cost-analyzer (Sympozium)",
    "172.18.255.219": "incident-responder (Sympozium)",
    "172.18.255.220": "host-ollama-lb (optional)",
}


@mcp.tool()
def metallb_owner(ip: str) -> str:
    """Return which service owns a MetalLB IP on this platform (172.18.255.x)."""
    return ASSIGNMENTS.get(ip.strip(), f"{ip}: unassigned / not in the fixed pool")


@mcp.tool()
def metallb_table() -> str:
    """Return the full fixed MetalLB IP assignment table for this platform."""
    return "\n".join(f"{ip}  {svc}" for ip, svc in ASSIGNMENTS.items())


if __name__ == "__main__":
    # These three flags are the fix for Sympozium's mcp-bridge (a plain Go HTTP
    # client) on FastMCP 3.4.3 — WITHOUT them the bridge's `initialize` times
    # out "awaiting headers" and discovers 0 tools:
    #   json_response=True         → reply with a single application/json body
    #                                instead of FastMCP's default SSE
    #                                (text/event-stream) framing, which the Go
    #                                client can't consume.
    #   stateless_http=True        → no per-session state / GET stream to set up.
    #   host_origin_protection=False → FastMCP 3.4.3 rejects requests whose Host
    #                                header isn't localhost with 421 Misdirected
    #                                Request; in-cluster the Host is the Service
    #                                DNS name, so the guard must be off.
    mcp.run(transport="http", host="0.0.0.0", port=8000,
            json_response=True, stateless_http=True, host_origin_protection=False)
