#!/usr/bin/env bash
# Speculative-decoding go/no-go A/B harness (Phase 4.D gate).
#
# Measures the *in-process* speculative-decoding ceiling for a given
# (verifier, draft) pair using stock llama-server's built-in `-md` draft.
# This is the BEST case for cross-peer spec decode: zero network, no
# serial remote-draft penalty. If a big/slow verifier can't clear the
# done-when gate here, the cross-peer build (which only adds cost) won't
# either -- so this is the number that decides whether 4.D's wire
# protocol + llama.cpp /spec_verify endpoint are worth building.
#
# Method (honours the 2026-06-05 "thermally-paired A/B" caveat in
# internal/STRATEGY.md + RESILIENCE.md): the verifier is run twice per
# round -- baseline (`--spec-type none`) and treatment (`--spec-type
# draft-simple -md DRAFT`) -- alternating across REPEATS rounds with a
# cooldown between, so thermal drift hits both arms equally. We report
# the median decode tok/s of each arm, their ratio, and the median draft
# acceptance rate, then print PASS/FAIL against gate #4
# (decode ratio >= 1.5x AND acceptance >= 40%).
#
# Two arms can't run concurrently (the verifier is the memory hog and a
# second copy won't fit), so arms run sequentially with the server
# restarted each time. temp=0 (greedy) makes acceptance deterministic
# per prompt and removes sampling noise from the throughput comparison.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Config (override via env) ---------------------------------------
LLAMA_BIN="${LLAMA_BIN:-$PROJECT_DIR/llama.cpp/build/bin/llama-server}"
HF_CACHE_DIR="${HF_HUB_CACHE:-${HF_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/huggingface}/hub}"
# Big/slow verifier -- the class where spec decode classically wins.
VERIFIER="${VERIFIER:-$HF_CACHE_DIR/Llama-3.3-70B-Instruct-Q4_K_M.gguf}"
# Small draft -- MUST share the verifier's tokenizer/vocab family.
DRAFT="${DRAFT:-$HF_CACHE_DIR/Llama-3.2-1B-Instruct-Q4_K_M.gguf}"
PORT="${PORT:-8090}"
NGL="${NGL:-99}"
NGL_DRAFT="${NGL_DRAFT:-99}"
CTX="${CTX:-8192}"
MAX_TOKENS="${MAX_TOKENS:-256}"
# --spec-draft-n-max sweep is a single value here; re-run with different
# N_DRAFT to sweep. Default 6 sits in the catalog's 4-8 band.
N_DRAFT="${N_DRAFT:-6}"
REPEATS="${REPEATS:-4}"          # rounds per arm (alternated)
COOLDOWN_SECS="${COOLDOWN_SECS:-8}"
LOAD_TIMEOUT_SECS="${LOAD_TIMEOUT_SECS:-300}"
REQ_TIMEOUT_SECS="${REQ_TIMEOUT_SECS:-180}"
PROMPTS_FILE="${PROMPTS_FILE:-$SCRIPT_DIR/prompts.txt}"

# Gate #4 thresholds (internal/STRATEGY.md "Done when" 4.D).
GATE_RATIO="${GATE_RATIO:-1.5}"
GATE_ACCEPT="${GATE_ACCEPT:-0.40}"

LOG="/tmp/spec-ab-llama.log"
CSV="/tmp/spec-ab-samples.csv"

nuke() { pkill -9 -f "llama-server" 2>/dev/null || true; sleep 1; }
trap nuke EXIT

require() {
    [[ -x "$LLAMA_BIN" ]]   || { echo "FATAL: llama-server not found/executable at $LLAMA_BIN" >&2; exit 1; }
    [[ -f "$VERIFIER" ]]    || { echo "FATAL: verifier gguf not found: $VERIFIER" >&2; exit 1; }
    [[ -f "$DRAFT" ]]       || { echo "FATAL: draft gguf not found: $DRAFT" >&2; exit 1; }
    command -v curl >/dev/null || { echo "FATAL: curl required" >&2; exit 1; }
    command -v python3 >/dev/null || { echo "FATAL: python3 required" >&2; exit 1; }
}

# Start the verifier server. arm=baseline|treatment.
start_server() {
    local arm="$1"
    nuke
    : >"$LOG"
    local extra=()
    if [[ "$arm" == "treatment" ]]; then
        extra=(--spec-type draft-simple -md "$DRAFT"
               --spec-draft-n-max "$N_DRAFT" -ngld "$NGL_DRAFT")
    else
        extra=(--spec-type none)
    fi
    nohup "$LLAMA_BIN" -m "$VERIFIER" -ngl "$NGL" -c "$CTX" \
        --host 127.0.0.1 --port "$PORT" --temp 0 \
        "${extra[@]}" >"$LOG" 2>&1 &

    for _ in $(seq 1 "$LOAD_TIMEOUT_SECS"); do
        curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    echo "FATAL: $arm server load timeout" >&2; tail -20 "$LOG" >&2; exit 1
}

# Run one prompt through the native /completion endpoint (always returns
# a `timings` block incl. draft accounting) at temp=0. Emits a CSV row:
#   arm,repeat,prompt_idx,predicted_per_second,draft_n,draft_n_accepted
run_prompt() {
    local arm="$1" rep="$2" idx="$3" prompt="$4"
    local body resp
    body=$(python3 -c '
import json,sys
print(json.dumps({
  "prompt": sys.argv[1],
  "n_predict": int(sys.argv[2]),
  "temperature": 0,
  "cache_prompt": False,
}))' "$prompt" "$MAX_TOKENS")
    resp=$(curl -s --max-time "$REQ_TIMEOUT_SECS" \
        "http://127.0.0.1:$PORT/completion" \
        -H "Content-Type: application/json" -d "$body" 2>/dev/null) || resp=""
    [[ -z "$resp" ]] && { echo "  ! $arm rep$rep p$idx: TIMEOUT/empty" >&2; return; }
    python3 -c '
import json,sys
arm,rep,idx=sys.argv[1],sys.argv[2],sys.argv[3]
try:
    t=json.loads(sys.argv[4]).get("timings",{}) or {}
except Exception:
    print(f"  ! {arm} rep{rep} p{idx}: unparseable response",file=sys.stderr); sys.exit(0)
pps=t.get("predicted_per_second")
dn=t.get("draft_n", t.get("n_draft"))
da=t.get("draft_n_accepted", t.get("n_draft_accepted"))
if pps is None:
    print(f"  ! {arm} rep{rep} p{idx}: no timings.predicted_per_second (llama.cpp too old?)",file=sys.stderr); sys.exit(0)
dn_s = "" if dn is None else dn
da_s = "" if da is None else da
print(f"{arm},{rep},{idx},{pps},{dn_s},{da_s}")
' "$arm" "$rep" "$idx" "$resp" | tee -a "$CSV"
}

run_arm() {
    local arm="$1" rep="$2"
    echo "── arm=$arm round=$rep ────────────────────────────────"
    start_server "$arm"
    local idx=0
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        run_prompt "$arm" "$rep" "$idx" "$line" >/dev/null
        idx=$((idx + 1))
    done <"$PROMPTS_FILE"
    nuke
    sleep "$COOLDOWN_SECS"
}

# --- main ------------------------------------------------------------
require
[[ -f "$PROMPTS_FILE" ]] || { echo "FATAL: prompts file not found: $PROMPTS_FILE" >&2; exit 1; }
: >"$CSV"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Speculative-decoding go/no-go (in-process -md ceiling)     ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo "  verifier : $(basename "$VERIFIER")"
echo "  draft    : $(basename "$DRAFT")"
echo "  n_draft  : $N_DRAFT   max_tokens: $MAX_TOKENS   repeats: $REPEATS"
echo ""

for rep in $(seq 1 "$REPEATS"); do
    run_arm baseline  "$rep"
    run_arm treatment "$rep"
done

echo ""
echo "── Summary (medians across rounds) ─────────────────────────"
python3 - "$CSV" "$GATE_RATIO" "$GATE_ACCEPT" <<'PY'
import sys,csv,statistics as st
csv_path,gate_ratio,gate_accept=sys.argv[1],float(sys.argv[2]),float(sys.argv[3])
base,treat,acc=[],[],[]
with open(csv_path) as f:
    for row in csv.reader(f):
        if len(row)<4: continue
        arm,rep,idx,pps=row[0],row[1],row[2],row[3]
        try: pps=float(pps)
        except ValueError: continue
        if arm=="baseline": base.append(pps)
        elif arm=="treatment":
            treat.append(pps)
            if len(row)>=6 and row[4] and row[5]:
                try:
                    dn,da=float(row[4]),float(row[5])
                    if dn>0: acc.append(da/dn)
                except ValueError: pass
def med(x): return st.median(x) if x else float("nan")
b,t=med(base),med(treat)
ratio=(t/b) if (base and treat and b>0) else float("nan")
a=med(acc) if acc else float("nan")
print(f"  baseline decode  : {b:8.2f} tok/s  (n={len(base)})")
print(f"  treatment decode : {t:8.2f} tok/s  (n={len(treat)})")
print(f"  decode ratio     : {ratio:8.2f}x   (gate >= {gate_ratio}x)")
if acc:
    print(f"  draft acceptance : {a*100:7.1f}%   (gate >= {gate_accept*100:.0f}%)")
else:
    print(f"  draft acceptance : n/a (llama.cpp didn't report draft_n; check {csv_path})")
ratio_ok = ratio==ratio and ratio>=gate_ratio
acc_ok   = (a==a and a>=gate_accept) if acc else None
verdict="PASS" if (ratio_ok and (acc_ok is None or acc_ok)) else "FAIL"
print("")
print(f"  GATE #4 verdict  : {verdict}")
if verdict=="FAIL":
    if not ratio_ok: print("    - decode ratio below 1.5x: in-process ceiling insufficient; cross-peer adds only cost.")
    if acc_ok is False: print("    - acceptance below 40%: draft/verifier pairing is a poor match.")
PY
echo ""
echo "  raw samples: $CSV    server log: $LOG"
