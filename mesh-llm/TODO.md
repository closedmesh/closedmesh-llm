# mesh-llm TODO

## Vision / Multimodal

llama.cpp supports vision models via `--mmproj` (multimodal projector). The server handles OpenAI-compatible `image_url` content parts in `/v1/chat/completions`. Our proxy forwards request bodies as-is, so the vision message format works end-to-end. Tested locally with Qwen3.5-0.8B — reads screenshots, does OCR, describes images.

Multimodal models are a superset of text models — they do normal text chat AND accept images. No tradeoff.

**What's needed:**
- **Catalog**: Add `vision: bool` to `CatalogModel`, add `mmproj` field (filename + URL). Tag Qwen3.5 family as vision.
- **Launch**: Pass `--mmproj <file>` to llama-server when model has one
- **Download**: Download mmproj alongside model GGUF
- **`/v1/models`**: Surface `"capabilities": ["vision"]` so clients know
- **`/api/status` → `mesh_models`**: Add `vision: bool` so UI can show badge
- **UI model list**: Show 👁 or camera icon next to vision-capable models
- **UI chat input**: Show image attach button when selected model supports vision. Encode as base64 `data:image/jpeg;base64,...` in OpenAI `image_url` content part format

**Models (all Qwen3.5 are vision-native):**
- Qwen3.5-0.8B (~0.5GB + 0.2GB mmproj) — tiny, runs anywhere, good for OCR/screenshots
- Qwen3.5-4B (~2.5GB + mmproj) — good balance
- Qwen3.5-9B (~5.5GB + mmproj) — drop-in replacement for Qwen3-8B, gains vision
- Qwen3.5-27B (~16GB + mmproj) — already on Studio as text-only, just needs mmproj
- Gemma-3-12b, Pixtral-12B — alternative architectures with vision

No image generation — llama.cpp is transformers only. Vision = understanding (describe, OCR, visual QA).

## Mixture of Models (MoM)

Route different requests to specialized models based on task type. Instead of one "best" model, the mesh becomes smarter about which model handles what.

**Paper:** [Mixture of Models: An Intra-Model Ensemble Approach](https://arxiv.org/pdf/2601.16863)

The paper shows ensemble routing across heterogeneous models outperforms any single model. Our mesh already has the ingredients — multiple models, a router that classifies requests. The gap is making the router model-aware (which models are good at what) and potentially splitting complex requests across models.

**Relates to:** Smart Router (below), Vision routing (vision requests → vision model), Multi-Model Per Host.

## Multi-Model Per Host

Currently each host runs one llama-server serving one model. Hosts with spare VRAM could serve multiple simultaneously.

**Options:**
1. **Multiple llama-server processes** — each on a different port, proxy routes by model. Simple but duplicates KV cache overhead.
2. **llama-server native multi-model** — newer versions support `--model` multiple times. Single process, shared infrastructure.

**Why it matters:**
- Studio (206GB) could serve MiniMax (130GB) + a vision model (20GB)
- Mini (16GB) could serve Qwen3.5-9B (5.5GB) + draft model
- Enables MoM routing across models on the same host

## Peer-to-Peer Model Transfer

Fetch model files directly from mesh peers instead of HuggingFace. Peers already have QUIC connections — add a new stream type where the requester sends a filename and offset, the responder streams the file back.

**Why:** LAN transfers are massively faster than HuggingFace downloads. Two machines on the same network could transfer a 47GB model in minutes instead of an hour. Also works when HF is slow, rate-limited, or down.

**Design:**
- New bi-stream type (`STREAM_FILE_TRANSFER`): requester sends filename + resume offset, responder reads from `~/.models/` and streams back
- Only serve files from `~/.models/` — no path traversal
- Resume support via byte offset
- Prefer low-RTT peers (LAN) over high-RTT (relay)
- Download logic tries peers first, falls back to HuggingFace
- Extend gossip to include filenames on disk so peers know what's fetchable

## SSD Expert Streaming

Run giant MoE models on a single node by streaming active experts from NVMe instead of fitting everything in RAM.

[flash-moe](https://github.com/danveloper/flash-moe) already does this — runs Qwen3.5-397B-A17B at 5.5 tok/s on a 48GB M3 Max with 6GB resident memory. See [ROADMAP.md](../ROADMAP.md).

**Plan:** Use flash-moe as an alternative backend. Mesh-llm spawns it like llama-server. Needs HTTP/SSE endpoint (currently CLI only) and OpenAI-compatible `/v1/chat/completions`.

## MoE Expert Sharding

Design: [MoE_PLAN.md](../MoE_PLAN.md) · Auto-deploy: [MoE_DEPLOY_DESIGN.md](../MoE_DEPLOY_DESIGN.md) · Validation: [MoE_SPLIT_REPORT.md](../MoE_SPLIT_REPORT.md)

- [ ] **Lazy `moe-analyze`** — auto-run ranking for unknown MoE models.
- [ ] **Scale testing** — Mixtral 8×22B, Qwen3-235B-A22B across multi-node.

## Smart Router
- [ ] **Static speed estimates**: `tok_s: f64` on ModelProfile. Quick tasks prefer fast models.
- [ ] **Response quality checks**: Detect empty/repetitive/truncated responses, retry with different model.
- [ ] **MoM-aware routing**: Route by task type to best-suited model (see Mixture of Models above).

## Resilience
- [ ] **Multi-node tensor split recovery**: If one split peer dies, re-split across remaining.
