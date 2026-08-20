#!/usr/bin/env python3
"""Aggregate a batch of lab-09 AgentRuns (kubectl get ... -o json on stdin)
into a per-run table + per-model summary. All figures come from each run's
.status.tokenUsage / .status.phase; tok/s is derived (outputTokens/duration)."""
import json
import sys


def main():
    data = json.load(sys.stdin)
    items = data.get("items", [])
    rows = []
    for it in items:
        spec = it.get("spec", {})
        st = it.get("status", {})
        u = st.get("tokenUsage", {}) or {}
        model = (spec.get("model") or {}).get("model", "?")
        task = it.get("metadata", {}).get("labels", {}).get("lab-task", "?")
        phase = st.get("phase", "Unknown")
        dur_ms = u.get("durationMs", 0) or 0
        out = u.get("outputTokens", 0) or 0
        toks = out / (dur_ms / 1000) if dur_ms else 0.0
        rows.append({
            "model": model, "task": task, "phase": phase,
            "in": u.get("inputTokens", 0) or 0,
            "out": out, "total": u.get("totalTokens", 0) or 0,
            "tools": u.get("toolCalls", 0) or 0,
            "dur": dur_ms / 1000, "toks": toks,
        })

    rows.sort(key=lambda r: (r["model"], r["task"]))

    print("═══ Per-run metrics ═══")
    hdr = f"{'MODEL':<12} {'TASK':<7} {'PHASE':<10} {'IN':>6} {'OUT':>5} {'TOTAL':>6} {'TOOLS':>5} {'DUR(s)':>7} {'TOK/S':>6}"
    print(hdr)
    print("─" * len(hdr))
    for r in rows:
        print(f"{r['model']:<12} {r['task']:<7} {r['phase']:<10} {r['in']:>6} {r['out']:>5} "
              f"{r['total']:>6} {r['tools']:>5} {r['dur']:>7.1f} {r['toks']:>6.1f}")

    # per-model summary
    models = {}
    for r in rows:
        m = models.setdefault(r["model"], [])
        m.append(r)

    print("\n═══ Per-model summary ═══")
    hdr2 = f"{'MODEL':<12} {'RUNS':>5} {'OK':>6} {'AVG_TOTAL':>10} {'AVG_TOOLS':>10} {'AVG_DUR(s)':>11} {'AVG_TOK/S':>10}"
    print(hdr2)
    print("─" * len(hdr2))
    for m, rs in sorted(models.items()):
        n = len(rs)
        ok = sum(1 for r in rs if r["phase"] == "Succeeded")
        avg_total = sum(r["total"] for r in rs) / n
        avg_tools = sum(r["tools"] for r in rs) / n
        avg_dur = sum(r["dur"] for r in rs) / n
        ok_rs = [r for r in rs if r["dur"] > 0]
        avg_toks = (sum(r["toks"] for r in ok_rs) / len(ok_rs)) if ok_rs else 0.0
        print(f"{m:<12} {n:>5} {f'{ok}/{n}':>6} {avg_total:>10.0f} {avg_tools:>10.1f} "
              f"{avg_dur:>11.1f} {avg_toks:>10.1f}")

    total_tok = sum(r["total"] for r in rows)
    total_ok = sum(1 for r in rows if r["phase"] == "Succeeded")
    print(f"\nBatch totals: {len(rows)} runs, {total_ok} succeeded, "
          f"{total_tok} tokens consumed.")
    print("Notes: IN tokens dominate (system prompt + skill instructions + tool "
          "output are all re-fed each turn); TOOLS = kubectl calls the model made; "
          "a 0-tool 'Succeeded' run usually means the model answered from the "
          "prompt without actually checking the cluster.")


if __name__ == "__main__":
    main()
