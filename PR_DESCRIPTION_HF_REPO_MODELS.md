# Hugging Face Repo-Native Model Management

## Why

mesh-llm currently treats models mostly as loose GGUF files, often under `~/.models`.
That works for simple downloads, but it leaves us without a canonical model identity, weakens provenance, duplicates storage, and makes future model formats harder to support.

This PR moves mesh-llm toward treating Hugging Face repositories and snapshots as the canonical model source.

We need this for multiple reasons:

- Provenance for model data so automatically managed MoE splits are tied to the correct upstream model instead of guessing through filenames.
- First-class metadata like `config.json`, which gives us a foundation for future model attestation and stronger compatibility checks.
- A repo-native model abstraction that can support non-GGUF formats later, including MLX and other runtimes.
- Repo and revision awareness so mesh-llm can detect newer upstream revisions and support managed model updates.
- Reduced disk usage by reusing the standard Hugging Face cache instead of keeping a second mesh-managed model store.
- Better alignment with the Hugging Face ecosystem so mesh-llm fits naturally into the broader LLM community and toolchain.

## Metadata Examples

Treating Hugging Face repos as repos gives mesh-llm access to useful structured metadata instead of forcing it to infer everything from filenames.

That matters for a few concrete cases:

- Provenance and identity via fields like `_name_or_path`, `architectures`, `model_type`, repo id, and revision.
- Vision and multimodal detection via fields like `vision_config`, `vision_start_token_id`, `vision_end_token_id`, `vision_token_id`, `image_token_id`, and `video_token_id`.
- Reasoning heuristics via template/token metadata such as `<think>` markers, reasoning-oriented special tokens, and model/repo metadata that explicitly identifies reasoning variants.
- Runtime and compatibility hints via `torch_dtype`, `text_config`, `vision_config`, and the exact architecture class such as `Qwen2_5_VLForConditionalGeneration` or `MllamaForConditionalGeneration`.
- Context and serving hints via `max_position_embeddings`, `sliding_window`, and `rope_scaling`.
- Companion asset discovery via files such as `preprocessor_config.json`, `tokenizer_config.json`, `chat_template.json`, and `generation_config.json`.

Examples from real Hugging Face repos:

- `Qwen/Qwen2.5-VL-7B-Instruct` exposes `model_type: "qwen2_5_vl"`, `vision_config`, `vision_start_token_id`, `vision_end_token_id`, `vision_token_id`, `image_token_id`, `video_token_id`, `max_position_embeddings: 128000`, and `rope_scaling.type: "mrope"`. The repo also includes `preprocessor_config.json`, which is another strong signal that this is a vision-capable model.
- `meta-llama/Llama-3.2-11B-Vision-Instruct` exposes `architectures: ["MllamaForConditionalGeneration"]`, `model_type: "mllama"`, `image_token_index`, a nested `text_config`, and a nested `vision_config` with fields like `image_size`.
- Even for non-vision models, repo metadata is still useful: text and code models expose architecture, dtype, context window, tokenizer/chat-template metadata, and sometimes explicit reasoning markers that can later drive model routing, compatibility checks, and richer UX.

This is the difference between "we downloaded a file called `foo-q4.gguf`" and "we know exactly which model family this is, which revision it came from, what capabilities it has, and what other assets belong with it."

## What Changed

- The Hugging Face cache is now the canonical managed model store.
- `~/.models` is now legacy storage. It is deprecated, warned about at runtime, and intended for removal in a future release.
- Goose model roots are no longer treated as managed model roots.
- Raw local GGUF usage is still supported explicitly via `--gguf`.
- MoE split artifacts now live under `~/.cache/mesh-llm/splits` instead of being mixed into model storage.
- Model management now lives under a dedicated Rust `models` module tree instead of keeping everything in a narrowly named `download.rs`.
- The curated model list is now repo-first in behavior for Hugging Face-backed models.
- The new `models` command surface adds `recommended`, `installed`, `search`, `show`, `download`, `migrate`, `migrate --prune`, and `updates` workflows.
- Capability inference is now shared across CLI, API, `/v1/models`, and the UI:
  - `vision`
  - `reasoning`

## User-Facing Behavior

### Canonical storage

mesh-llm now prefers the Hugging Face cache:

```text
~/.cache/huggingface/hub
```

and respects standard Hugging Face configuration such as:

- `HF_TOKEN`
- `HF_HOME`
- `HF_HUB_CACHE`
- `HF_ENDPOINT`

### Legacy storage warning

If a model is loaded from `~/.models`, mesh-llm now warns that this storage is deprecated and will be removed in a future release, and points the user to migration commands.

### Update detection on startup

If a repo-backed model is started and a newer upstream revision exists, mesh-llm:

- continues with the pinned local snapshot
- prints a non-blocking update warning
- shows the exact `models updates` command to run

mesh-llm does not silently update a model during startup.

## New CLI Examples

The snippets below are copied from actual runs of the new command surface on this branch.
For readability, the repeated self-update banner at command start is omitted.

### Recommended models

```bash
mesh-llm models recommended
```

Example output:

```text
📚 Recommended models

• Qwen3-4B-Q4_K_M  2.5GB
  Qwen3 starter, thinking/non-thinking modes
  🧠 Draft: Qwen3-0.6B-Q4_K_M
  🧠 Reasoning: yes

• Llama-3.2-3B-Instruct-Q4_K_M  2.0GB
  Meta Llama 3.2, goose default, good tool calling
  🧠 Draft: Llama-3.2-1B-Instruct-Q4_K_M

• Qwen3.5-27B-Q4_K_M  17GB
  Qwen3.5 27B, vision + text, strong reasoning and coding
  🧠 Draft: Qwen3-0.6B-Q4_K_M
  👁️ Vision: yes
  🧠 Reasoning: yes

• Qwen3.5-0.8B-Vision-Q4_K_M  508MB
  Tiny vision model, OCR, screenshots, runs anywhere
  👁️ Vision: yes
```

### Installed models

```bash
mesh-llm models installed
```

Example output:

```text
💾 Installed models
📁 HF cache: /Users/jdumay/.cache/huggingface/hub
⚠️ Legacy storage detected: /Users/jdumay/.models

• GLM-4.7-Flash-Q4_K_M  18.3GB
  🤗 HF cache
  /Users/jdumay/.cache/huggingface/hub/models--unsloth--GLM-4.7-Flash-GGUF/snapshots/0d32489ecb9db6d2a4fc93bd27ef01519f95474d/GLM-4.7-Flash-Q4_K_M.gguf
  MoE 30B/3B active, 64 experts top-4, fast inference, tool calling
  🧩 MoE: yes

• Qwen2.5-0.5B-Instruct-f16  994MB
  ⚠️ legacy
  /Users/jdumay/.models/Qwen2.5-0.5B-Instruct-f16.gguf

• Qwen3-4B-Q4_K_M  2.5GB
  🤗 HF cache
  /Users/jdumay/.cache/huggingface/hub/models--unsloth--Qwen3-4B-GGUF/snapshots/22c9fc8a8c7700b76a1789366280a6a5a1ad1120/Qwen3-4B-Q4_K_M.gguf
  Qwen3 starter, thinking/non-thinking modes
  🧠 Draft: Qwen3-0.6B-Q4_K_M
  🧠 Reasoning: yes
```

### Search

```bash
mesh-llm models search 'qwen 0.6b' --limit 2
```

Example:

```text
🔎 Hugging Face GGUF matches for 'qwen 0.6b'
🖥️ This machine: ~19.3GB available

1. 📦 Qwen3-0.6B-Q4_K_M.gguf
   repo: unsloth/Qwen3-0.6B-GGUF
   📏 397MB  ⬇️ 59,239  ❤️ 117
   capabilities: 💬 text
   ref: unsloth/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q4_K_M.gguf
   show: mesh-llm models show unsloth/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q4_K_M.gguf
   download: mesh-llm models download unsloth/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q4_K_M.gguf
   ✅ likely comfortable here
   ⭐ Recommended: Qwen3-0.6B-Q4_K_M (397MB)
   Draft for Qwen3 models

2. 📦 Qwen3-Embedding-0.6B-Q8_0.gguf
   repo: Qwen/Qwen3-Embedding-0.6B-GGUF
   📏 639MB  ⬇️ 31,293  ❤️ 508
   capabilities: 💬 text
   ref: Qwen/Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-Q8_0.gguf
   show: mesh-llm models show Qwen/Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-Q8_0.gguf
   download: mesh-llm models download Qwen/Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-Q8_0.gguf
   ✅ likely comfortable here
```

### Show model details

```bash
mesh-llm models show unsloth/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q4_K_M.gguf
```

Example output:

```text
🔎 Qwen3-0.6B-Q4_K_M.gguf
🖥️ This machine: ~19.3GB available

Ref: unsloth/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q4_K_M.gguf
Source: Hugging Face
Size: 397MB
Fit: ✅ likely comfortable here
About: Draft for Qwen3 models
Capabilities:
  💬 text
📥 Download:
   https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf
```

### Download

```bash
mesh-llm models download unsloth/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q4_K_M.gguf
```

Example output:

```text
📥 Syncing unsloth/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q4_K_M.gguf@main into /Users/jdumay/.cache/huggingface/hub
  ✅ [1/2] meta /Users/jdumay/.cache/huggingface/hub/models--unsloth--Qwen3-0.6B-GGUF/snapshots/50968a4468ef4233ed78cd7c3de230dd1d61a56b/config.json
  ✅ [2/2] model /Users/jdumay/.cache/huggingface/hub/models--unsloth--Qwen3-0.6B-GGUF/snapshots/50968a4468ef4233ed78cd7c3de230dd1d61a56b/Qwen3-0.6B-Q4_K_M.gguf
✅ Downloaded model
   /Users/jdumay/.cache/huggingface/hub/models--unsloth--Qwen3-0.6B-GGUF/snapshots/50968a4468ef4233ed78cd7c3de230dd1d61a56b/Qwen3-0.6B-Q4_K_M.gguf
```

This shows the key behavior change: managed HF downloads now materialize into the Hugging Face snapshot cache and also cache `config.json` alongside the model asset when the repo publishes it.

### Legacy migration

```bash
mesh-llm models migrate
```

Example output:

```text
🧳 Legacy model scan
📁 Source: /Users/jdumay/.models

⚠️ Legacy-only: Qwen2.5-0.5B-Instruct-f16.gguf
   path: /Users/jdumay/.models/Qwen2.5-0.5B-Instruct-f16.gguf
   info: no canonical Hugging Face source is known for this GGUF

📊 Summary
   ✅ rehydratable: 0
   ⚠️ legacy-only: 1

➡️ Next steps
   mesh-llm --gguf /path/to/model.gguf
   Keep using custom local GGUF files explicitly
```

When there are rehydratable legacy models, `mesh-llm models migrate --apply` materializes them into the HF cache and then suggests:

```bash
mesh-llm models migrate --prune
```

`--prune` is intentionally explicit and separate. It removes only rehydratable legacy GGUFs that already have a matching canonical copy in the Hugging Face cache.

### Update checks and refresh

```bash
mesh-llm models updates --check
mesh-llm models updates Qwen/Qwen3-8B-GGUF
mesh-llm models updates --all
```

Example check behavior:

```text
🔄 Checking updates   4.2%  [1/24] Qwen/Qwen2.5-0.5B-Instruct
...
🔄 Checking updates 100.0%  [24/24] unsloth/Qwen3-8B-GGUF
```

If everything is current, the command stays quiet apart from the in-place progress bar. It only prints persistent output for repos that actually have an update available.

Example refresh output:

```text
🔄 Updating cached Hugging Face repos
📁 Cache: /Users/jdumay/.cache/huggingface/hub
📦 Selected: 1

🧭 [1/1] unsloth/Qwen3-0.6B-GGUF
   ref: main
   current: 50968a4468ef
   ↻ [1/2] Qwen3-0.6B-Q4_K_M.gguf
   ✅ /Users/jdumay/.cache/huggingface/hub/models--unsloth--Qwen3-0.6B-GGUF/snapshots/50968a4468ef4233ed78cd7c3de230dd1d61a56b/Qwen3-0.6B-Q4_K_M.gguf
   ↻ [2/2] config.json
   ✅ /Users/jdumay/.cache/huggingface/hub/models--unsloth--Qwen3-0.6B-GGUF/snapshots/50968a4468ef4233ed78cd7c3de230dd1d61a56b/config.json

✅ Update complete
   refreshed files: 2
```

This lets users inspect upstream repo revisions and update explicitly, without silent model churn.

### Explicit raw GGUF mode

```bash
mesh-llm --gguf /path/to/model.gguf
```

This remains the escape hatch for:

- custom local GGUF files
- files not tied to a known HF repo
- advanced local experimentation

## Migration Policy

This PR intentionally draws a clear line between managed models and one-off local files:

- Managed model storage is the Hugging Face cache.
- `~/.models` is legacy, deprecated, and scheduled for future removal.
- Arbitrary local GGUFs are still supported explicitly via `--gguf`.
- Cleanup of migrated legacy files is explicit via `models migrate --prune`, not automatic.

That keeps the default model story simple while still preserving advanced local workflows.

## Validation

- `cargo test --bin mesh-llm -- --test-threads=1`
- live command checks using `target/debug/mesh-llm` for:
  - `models recommended`
  - `models installed`
  - `models search`
  - `models show`
  - `models migrate`
  - `models updates --check`

## Notes

- This PR is about making Hugging Face repositories and snapshots the canonical model identity and management layer.
- The long-term direction is repo-native model management, not permanent dependence on anonymous file URLs.
- This is also groundwork for future non-GGUF model support and richer validation of model identity and compatibility.
