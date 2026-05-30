# Peer verification

ClosedMesh is an open network: anyone can run the runtime and advertise that
they serve a model. Verification answers one question — **is a peer that claims
to serve model X actually running model X, honestly?** — without trusting the
peer's self-report and without ever touching real user traffic.

It shipped in `v0.66.57` and runs in **observe-mode by default**: the verifier
logs verdicts and does not act on them unless enforcement is explicitly enabled.

## Why it exists

The native-baseline measurement ([benchmark honesty](#see-also)) already keeps
peers honest about *speed*. It does not catch a peer that serves at the claimed
speed while running a smaller/cheaper model than it advertises, or returning
canned text. Model-identity verification closes that gap, which is the
prerequisite for any reward/staking layer where misrepresenting a model is
profitable.

## The model-identity fingerprint

When a peer's `llama-server` becomes Ready for a model, the runtime issues a
single deterministic probe (`temperature=0`, fixed seed) directly to its own
`llama-server` and records a compact fingerprint:

- `output_sha256` — SHA-256 of the full greedy-decoded output text.
- `token_count` — number of decoded tokens.
- `prefix_tokens` — the first N decoded token strings (`FINGERPRINT_PREFIX_LEN`).

A different or smaller model, or canned text, produces a different greedy decode
for the same fixed prompt and diverges within the first few tokens. The
fingerprint is cached on disk alongside the timing baseline and gossiped to the
mesh.

> **No logprobs.** Earlier versions also stored per-token logprobs. At
> `temperature=0` the chosen token's logprob is definitionally 0 and `llama.cpp`
> returns no alternatives, so they carried no signal and were removed. The token
> sequence and output hash are the discriminators.

## The comparison oracle

A verifier compares a *reference* fingerprint against a *candidate* fingerprint
produced by the suspect peer. The oracle compares a **bounded token prefix and
allows a small disagreement budget** rather than requiring an exact hash match:
even greedy decoding can diverge in the tail across Metal / CUDA / Vulkan because
of floating-point differences in near-tie argmaxes. The prefix is stable; the
tail is not. The verdict is one of `Match`, `Mismatch`, or `Inconclusive`.

## Two probe modes

The verifier loop runs on entry nodes, samples `(peer, model)` pairs, re-probes,
and logs the verdict.

- **Self-oracle (preferred).** When the verifying node also serves the model,
  each audit generates a fresh **nonce-randomized** probe, runs it on its own
  `llama-server` to get ground truth, and sends the identical probe to the
  suspect. Because the probe is unpredictable, a peer cannot recognise "the
  probe" and serve the real model only for it — this closes the known-prompt
  spoof.
- **Fixed reference (fallback).** When the verifier does not serve the model,
  the suspect is compared against a precomputed reference for a fixed probe.
  Spoofable by a peer that recognises the known prompt, but still catches the
  common cases — wrong/smaller model, canned replies, misconfiguration.

## Privacy boundary

**Verification only ever re-executes synthetic probes the verifier generates. It
never samples, replays, or duplicates real user traffic.**

Replaying a real user request against a second node would be more robust against
a peer that fingerprints synthetic probes — but it would fan a user's private
prompt out to a node that played no part in serving that request, expanding
plaintext exposure beyond the minimal serving path (the entry plus the one
host). That conflicts with ClosedMesh's privacy promise, so it is deliberately
not done. This boundary is intentional; do not "improve" verification by
sampling organic traffic.

## Observe vs enforce

Demotion is the one consequential lever — a false positive punishes an honest
contributor — so it is gated three ways:

1. **Off unless `CLOSEDMESH_VERIFY_ENFORCE` is set** to a truthy value
   (`1`/`true`/`yes`/`on`). Default is observe-only: verdicts are logged, nothing
   is demoted.
2. **Requires several *consecutive* `Mismatch` verdicts** for the same
   `(peer, model)` before acting — never a single flaky probe. `Inconclusive`
   never counts toward conviction.
3. **The action is reversible and time-boxed.** A convicted peer is removed from
   the routable set for that model only, stays in the mesh, keeps being
   re-probed, and is reinstated on the next `Match` or when the cooldown lapses.
   This is route demotion, not slashing.

| `CLOSEDMESH_VERIFY_ENFORCE` | Behaviour |
|---|---|
| unset / falsey (default) | Observe-only. Verdicts logged; routing unaffected. |
| `1` / `true` / `yes` / `on` | A peer with sustained mismatch is demoted from the routable set for that model, reversibly. |

## Establishing reference fingerprints

An auditor can capture a ground-truth reference for a `(model, quant)` from a
known-good local server:

```bash
closedmesh benchmark capture-reference --model <model-id>
```

The embedded defaults live in `closedmesh/src/inference/reference_fingerprints.json`.

## Limits and deferred work

- **Coverage is limited to models a verifier serves locally** for the strong
  (self-oracle) path. Multi-peer consensus (proof-of-sampling) for models no
  verifier serves is deferred.
- A determined adversary who can statistically distinguish synthetic probes from
  organic traffic is out of scope here — that is left to a future
  staking/attestation layer, not to prompt snooping.
- Verdicts are not yet surfaced on the public status catalog.

## See also

- `closedmesh/src/inference/verify.rs` — the oracle, the verifier loop, and the
  authoritative module docstring (including the privacy boundary).
- `closedmesh/src/inference/native_baseline.rs` — fingerprint capture and the
  native timing baseline it rides alongside.
- [closedmesh/docs/DESIGN.md](../closedmesh/docs/DESIGN.md) — architecture and module map.
