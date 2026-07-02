#!/usr/bin/env python3
"""Minimal OpenAI-compatible streaming client for a served Sympozium agent.

Stdlib-only on purpose: this is the smallest thing another application needs
to integrate with an agent. Anything that speaks the OpenAI Chat Completions
protocol (openai SDK, LangChain, curl) works the same way.

Usage:
    TOKEN=$(kubectl get secret cluster2-agent-web-proxy-key -n sympozium-system \
        -o jsonpath='{.data.api-key}' | base64 -d)
    TOKEN=$TOKEN python3 client.py "your question"

    AGENT_URL overrides the endpoint (default: cluster2-agent's MetalLB IP).
"""
import json
import os
import sys
import urllib.request

url = os.environ.get("AGENT_URL", "http://172.18.255.213:8080") + "/v1/chat/completions"
body = {
    "model": "default",
    "stream": True,
    "messages": [{"role": "user", "content": sys.argv[1] if len(sys.argv) > 1 else "Hello"}],
}
req = urllib.request.Request(
    url,
    data=json.dumps(body).encode(),
    headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {os.environ['TOKEN']}",
    },
)
with urllib.request.urlopen(req, timeout=150) as resp:
    for raw in resp:
        line = raw.decode().strip()
        if not line.startswith("data: ") or line == "data: [DONE]":
            continue
        delta = json.loads(line[6:])["choices"][0].get("delta", {})
        print(delta.get("content", ""), end="", flush=True)
print()
