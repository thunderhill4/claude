# Lab 10 — real agent work: SRE triage of a broken workload (scored)

**Capability:** this is the "does the agent actually *do useful work*, and how
reliably?" lab. It gives `cluster2-agent` (with the `k8s-ops` kubectl skill) a
genuine multi-step SRE task — *find the broken workload, diagnose the root
cause from live cluster state, propose a fix* — and **scores the result
objectively** against the known ground truth, across several runs.

**Integration angle:** this is the shape of a real deployment: an agent wired
into your cluster that a human (or an alert) hands a symptom, and it does the
`kubectl get → describe → events` investigation a junior SRE would. The lab
makes two things concrete that a single chat never does: (1) whether the agent
reaches the *correct* conclusion, and (2) what that costs in tool calls,
tokens, and latency.

## The scenario

`broken.yaml` deploys `lab-sre-broken`, a Deployment whose image tag doesn't
exist (`nginx:this-tag-does-not-exist-9z9z9`) → every pod sticks in
**ImagePullBackOff** with the reason plainly in its events. Nothing runs (safe,
read-only to diagnose). The agent is told only that "a workload in
sympozium-system is unhealthy" — it has to *find* it and read the events to
get the cause. A correct answer can't be guessed; it requires actually
inspecting the cluster.

## Scoring

Each run is **PASS** only if the agent's answer names both the workload
(`lab-sre-broken`) and the image-pull root cause (matches `imagepull` /
`image … pull|not found|invalid` / `errimagepull`). Otherwise **FAIL**. This
is deliberately strict: an agent that says "a pod is unhealthy, try restarting
it" without identifying the image is a fail — that's the difference between
useful triage and noise.

## Run it

```bash
bash 06-sympozium/labs/10-sre-triage/run-triage.sh        # 3 runs (default)
bash 06-sympozium/labs/10-sre-triage/run-triage.sh 5      # 5 runs
LAB_MODEL=llama3.2 bash 06-sympozium/labs/10-sre-triage/run-triage.sh   # other model
```

It deploys the broken workload, waits for ImagePullBackOff, runs N scored
triages, prints per-run verdict + metrics + a success rate, and cleans up.

## Expected output

<!-- CAPTURED-OUTPUT -->
Real run on this cluster (qwen2.5:7b, 3 runs):

```
== Lab 10 SRE triage — 3 run(s), model=qwen2.5:7b ==
-- deploying broken workload --
   broken workload state: ErrImagePull

-- triage runs --
run 1: PASS phase=Succeeded tools=1  in=6228  out=416  dur=14s
  ↳ The pod `lab-sre-broken-7999b8bd4-vvqrv` in the `sympozium-system` namespace
    is unhealthy and has the status `ErrImagePull`. This suggests that there's
    an issue with pulling the container image. ...
run 2: PASS phase=Succeeded tools=2  in=7136  out=837  dur=29s
  ↳ ... issues with two pods related to the `lab-sre-broken` deployment ...
run 3: PASS phase=Succeeded tools=4  in=10390 out=520  dur=25s
  ↳ ... on one of the pods (`lab-sre-broken-...`), an error occurred while
    attempting to pull the image `nginx:this-tag-does-not-exist-...` ...

═══ Result: 3/3 runs correctly diagnosed the root cause ═══
```

**What this run shows** (yours will vary — local models are non-deterministic):
- **3/3 correct** — every run found `lab-sre-broken` and named the image-pull
  failure, reading it from the live pod/events, not guessing.
- **Investigation depth varied**: 1 → 2 → 4 tool calls for the same task. Run 3
  did the most digging (4 kubectl calls, most input tokens) and even noticed
  the triage Jobs themselves running — more thorough, more expensive.
- **A real triage here costs ~6–10k input tokens and 14–29s** — the number to
  multiply by your alert volume when sizing this.
<!-- /CAPTURED-OUTPUT -->

## Reading the result

- **The success rate is the headline.** With a 7B local model the same task
  passes some runs and not others — that variance *is* the finding, and it's
  why lab 09's metrics and model comparison matter for picking what to deploy.
- **`tools` ≥ 2 on a PASS** means the agent really did `get` + `describe`/
  `events` — the multi-step investigation, not a one-shot guess. A PASS with
  `tools=0` would be suspicious (it can't have read the events).
- **Cost of a triage**: the `in`/`out`/`dur` columns are what one investigation
  consumes — multiply by your alert volume to size the workload.

## Cleanup

Automatic at the end of the script. To force it:

```bash
kubectl delete -f 06-sympozium/labs/10-sre-triage/broken.yaml --ignore-not-found
kubectl delete agentrun -n sympozium-system -l lab=sre-triage --ignore-not-found
```
