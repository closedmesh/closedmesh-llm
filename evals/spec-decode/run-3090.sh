#!/usr/bin/env bash
# Spec-decode A/B for a single-GPU "big target" gate on the 3090.
# Verifier: Qwen2.5-32B-Instruct-Q4_K_M ; Draft: Qwen2.5-0.5B-Instruct-Q4_K_M
# Measures decode t/s (baseline vs draft-simple at several n-max) and draft
# acceptance, all models fully on GPU.
set -u
source /root/spec/paths.sh
PORT=8099
PROMPTS=/root/spec/prompts.txt
SRVLOG=/root/spec/srv.log
NPRED=256
REPEATS=3

launch() {  # $1 = extra verifier/draft args
  pkill -x llama-server 2>/dev/null
  sleep 2
  : > "$SRVLOG"
  setsid bash -c "$BIN -m $VERIFIER $1 -ngl 99 -c 4096 --host 127.0.0.1 --port $PORT >> $SRVLOG 2>&1" </dev/null >/dev/null 2>&1 &
  for i in $(seq 1 120); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "!! server failed to come up"; tail -5 "$SRVLOG"; return 1
}

arm() {  # $1 = label ; $2 = extra args
  echo "=================================================="
  echo "ARM: $1   args: [$2]"
  echo "=================================================="
  launch "$2" || return 1
  python3 /root/spec/measure.py "$PORT" "$1" "$PROMPTS" "$NPRED" "$REPEATS"
  # acceptance (spec arms only): average over the per-request log lines
  awk -F'= ' '/draft acceptance/ {split($2,a," "); sum+=a[1]; n++} END{if(n>0) printf "ACCEPT %s mean=%.4f (n=%d)\n", L, sum/n, n; else print "ACCEPT '"$1"' n/a (baseline / no draft)"}' L="$1" "$SRVLOG"
}

DRAFT_COMMON="-md $DRAFT --spec-type draft-simple -ngld 99"

arm "baseline"  ""
arm "spec_n3"   "$DRAFT_COMMON --spec-draft-n-max 3"
arm "spec_n5"   "$DRAFT_COMMON --spec-draft-n-max 5"
arm "spec_n8"   "$DRAFT_COMMON --spec-draft-n-max 8"

echo "=================================================="
echo "DONE. Summary (grep RESULT/ACCEPT above)."
pkill -x llama-server 2>/dev/null
