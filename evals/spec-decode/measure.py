#!/usr/bin/env python3
"""Measure decode throughput for one server arm over a prompt set.

Sends greedy /completion requests and records timings.predicted_per_second
(decode-only t/s). Prints per-prompt medians and an overall summary line.
"""
import json
import statistics
import sys
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
LABEL = sys.argv[2] if len(sys.argv) > 2 else "arm"
PROMPTS_PATH = sys.argv[3] if len(sys.argv) > 3 else "/root/spec/prompts.txt"
NPRED = int(sys.argv[4]) if len(sys.argv) > 4 else 256
REPEATS = int(sys.argv[5]) if len(sys.argv) > 5 else 3

URL = f"http://127.0.0.1:{PORT}/completion"


def complete(prompt):
    body = json.dumps({
        "prompt": prompt,
        "n_predict": NPRED,
        "temperature": 0,
        "top_k": 1,
        "seed": 0,
        "cache_prompt": False,
    }).encode()
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        d = json.load(r)
    t = d["timings"]
    return t["predicted_per_second"], t["predicted_n"]


def main():
    prompts = []
    with open(PROMPTS_PATH) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            prompts.append(line)

    # warmup (not recorded)
    try:
        complete(prompts[0])
    except Exception as e:
        print(f"warmup failed: {e}", file=sys.stderr)

    all_tps = []
    for i, p in enumerate(prompts):
        per = []
        for _ in range(REPEATS):
            tps, n = complete(p)
            per.append(tps)
            all_tps.append(tps)
        med = statistics.median(per)
        print(f"  prompt[{i}] median={med:.2f} t/s  ({p[:48]!r})")

    overall_med = statistics.median(all_tps)
    overall_mean = statistics.mean(all_tps)
    print(f"RESULT {LABEL} median_tps={overall_med:.3f} mean_tps={overall_mean:.3f} samples={len(all_tps)}")


if __name__ == "__main__":
    main()
