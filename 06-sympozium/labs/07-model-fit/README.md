# Lab 07 — Hardware-aware model selection via `llmfit`

**Capability:** the `sympozium-llmfit-daemon` detects a node's CPU/GPU/RAM
and scores every model in its database for fit, speed, and quality against
that hardware — exposed as a REST API on port 8787. **Integration angle:**
before wiring a new agent to a model, ask `llmfit` what actually fits this
node instead of guessing.

This is the same data source behind the Sympozium dashboard's Gateway/
hardware view — see CLAUDE.md's Common Pitfalls for the NVIDIA-detection fix
(`fix-llmfit-nvidia-smi.sh`) this data depends on.

## Run it

```bash
bash 06-sympozium/labs/07-model-fit/run.sh
```

The script port-forwards the `llmfit-daemon` pod's `:8787` and queries three
endpoints: `/api/v1/system`, `/api/v1/models/top`, `/api/v1/models`.

## Expected output (real, from this node)

```json
{
  "cpu_name": "AMD Ryzen AI 9 HX 370 w/ Radeon 890M",
  "gpu_name": "NVIDIA GeForce RTX 4050 Laptop GPU",
  "gpu_vram_gb": 6.0,
  "total_ram_gb": 29.96,
  "backend": "CUDA"
}
```

Top pick for coding out of 74 candidate models — a 15.7B MoE model, running
with only 6/64 experts active in VRAM at a time (the rest offloaded to
system RAM):

```json
{
  "name": "TechxGenus/DeepSeek-Coder-V2-Lite-Instruct-AWQ",
  "params_b": 15.71,
  "runtime": "vllm",
  "run_mode_label": "MoE",
  "fit_label": "Good",
  "estimated_tps": 34.6,
  "score": 90.0,
  "score_components": {"context": 100.0, "fit": 91.3, "quality": 88.0, "speed": 86.6},
  "notes": [
    "MoE: 6/64 experts active in VRAM (2.3 GB) at Q8_0",
    "Inactive experts offloaded to system RAM (13.2 GB)",
    "Baseline estimated speed: 34.6 tok/s"
  ]
}
```

## Observed behavior

- The GPU correctly reports as the NVIDIA RTX 4050 with 6GB VRAM — this only
  works because of `fix-llmfit-nvidia-smi.sh`'s shim; without it, this same
  query reports the AMD iGPU (0.5GB) as primary instead (see CLAUDE.md).
- `llmfit` recommends models that aren't necessarily what's already pulled in
  Ollama (e.g. a vLLM-runtime AWQ model, whereas every agent in this repo
  runs Ollama-served GGUF models like `qwen2.5:7b`/`llama3.2`) — treat its
  output as a hardware-fit *reference*, not a drop-in replacement command;
  cross-check `runtime`/`provider` against what your serving stack actually
  supports before switching an agent's `model:` field.
- `min_fit=good` and `sort=score` work as documented filters; `total_models`
  in the response (74) tells you the size of the full candidate database
  being scored against, useful context for how exhaustive a search this is.

## Acting on a recommendation

1. Pick a model whose `runtime`/`provider` matches what you actually serve
   (Ollama, in this repo).
2. `ollama pull <model>` on the Docker host.
3. Set `model: <model>` in the relevant `Agent`/`SympoziumInstance`
   `agents.default.model` field (see lab 03's README for which CRD actually
   matters on this version).

## Cleanup

Nothing to clean up — this lab only reads, via a port-forward that's killed
when the script exits.
