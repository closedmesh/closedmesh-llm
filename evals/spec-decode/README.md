# Speculative-decoding go/no-go harness (Phase 4.D gate)

This is the **first, cheapest** step of Phase 4.D (cross-peer speculative
decoding). It answers one question before we build anything expensive:

> For a given `(verifier, draft)` pair, does speculative decoding clear
> done-when gate #4 — **decode ≥ 1.5× the no-draft baseline AND draft
> acceptance ≥ 40%** — on the big/slow verifier class?

## Why this comes first

`llama-server`'s speculative decoding is **single-process**: the draft
model is loaded *inside* the same server via `-md`/`--model-draft`, and
the accept/reject loop runs in C++ over two contexts in one process.
There is **no endpoint that accepts externally-supplied draft tokens**,
so a *remote* draft peer can't drive a verifier today. Cross-peer spec
decode therefore needs a new llama.cpp server endpoint (`/spec_verify`:
prompt + K draft tokens → one batched forward pass → n_accepted +
correction token) plus a per-round mesh wire protocol and pair election.

That's weeks of work — and it only ever *adds* cost (network + serial
remote draft) on top of the in-process case. So the in-process `-md`
number measured here is the **ceiling**:

- **If in-process fails gate #4**, cross-peer cannot pass it. Stop. (This
  is what the 2026-06-05 caveat already found for the fast 8B target:
  −12% / −5.4% even at ~68% acceptance — spec decode is OFF by default.)
- **If in-process passes by a comfortable margin**, the network-amortised
  cross-peer case (whitepaper §2.4: per-round, never per-token) is worth
  building, and we proceed to the `/spec_verify` endpoint + protocol.

## Method

Honours the "thermally-paired A/B" methodology in `internal/STRATEGY.md`
and `internal/RESILIENCE.md`:

- Runs the verifier twice per round — **baseline** (`--spec-type none`)
  and **treatment** (`--spec-type draft-simple -md DRAFT`) — alternating
  across `REPEATS` rounds with a cooldown, so thermal drift hits both
  arms equally. (Two arms can't run concurrently: a second copy of the
  verifier won't fit in memory.)
- `temp=0` (greedy): acceptance is deterministic per prompt and sampling
  noise is removed from the throughput comparison.
- Reports median decode tok/s per arm, their ratio, median acceptance,
  and a PASS/FAIL verdict against gate #4.

Decode tok/s and draft accounting are read from llama-server's native
`/completion` `timings` block (`predicted_per_second`, `draft_n`,
`draft_n_accepted`), which is more version-robust than the OpenAI route.

## Running it

Needs a built `llama-server` and two GGUFs that **share a tokenizer
family** (e.g. Llama-3.3-70B verifier + Llama-3.2-1B draft, or
Qwen3-32B + Qwen3-0.6B). Point it at whatever the host can hold:

```bash
VERIFIER=/path/to/Llama-3.3-70B-Instruct-Q4_K_M.gguf \
DRAFT=/path/to/Llama-3.2-1B-Instruct-Q4_K_M.gguf \
N_DRAFT=6 REPEATS=4 MAX_TOKENS=256 \
./spec-ab.sh
```

Sweep the draft length with repeated runs at different `N_DRAFT`
(catalog band is 4–8). Other knobs: `PORT`, `NGL`, `NGL_DRAFT`, `CTX`,
`LLAMA_BIN`, `COOLDOWN_SECS`, `GATE_RATIO`, `GATE_ACCEPT`, `PROMPTS_FILE`.

Output: a summary table + verdict; raw per-prompt samples in
`/tmp/spec-ab-samples.csv`; server log in `/tmp/spec-ab-llama.log`.

## Interpreting the result

| Verdict | Meaning | Next action |
|---|---|---|
| **PASS** (ratio ≥ 1.5×, acc ≥ 40%) | In-process ceiling clears the gate on this verifier class | Proceed to `/spec_verify` endpoint + cross-peer protocol; this pair is a routing candidate |
| **FAIL: ratio < 1.5×** | Even zero-network, the draft doesn't pay for itself on this verifier | Wrong verifier class (too fast) or wrong draft; do not build cross-peer for this pair |
| **FAIL: acc < 40%** | Draft and verifier disagree too often | Try a better-matched draft (same family, larger draft, or MTP head) |

A PASS here is necessary but **not sufficient** — cross-peer adds a
per-round network hop, so the real gate is re-run end-to-end on a live
two-peer pair once the protocol exists. This harness exists so we never
build that protocol for a pair that can't win even in the best case.
