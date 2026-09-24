#!/usr/bin/env python3
"""Exercise every preset the router advertises with a real request.

Checks the ANSWER, not just that the model loads -- a model can load fine and
emit garbage. Exits non-zero if any preset fails, so install-shockwave.sh can
gate on it.
"""
import json, sys, time, urllib.request

BASE = "http://127.0.0.1:8080"
QUESTION = "What is the capital of Japan? Answer in one short sentence."
EXPECT = "tokyo"

def get(path, timeout=30):
    with urllib.request.urlopen(BASE + path, timeout=timeout) as r:
        return json.loads(r.read())

def ask(model, timeout=1200):
    body = {"model": model, "max_tokens": 160, "temperature": 0,
            "messages": [{"role": "user", "content": QUESTION}]}
    req = urllib.request.Request(BASE + "/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.loads(r.read())
    if "error" in d:
        raise RuntimeError(d["error"].get("message", "")[:120])
    m = d["choices"][0]["message"]
    txt = (m.get("content") or "") + " " + (m.get("reasoning_content") or "")
    return txt.strip(), d.get("timings", {}), time.time() - t0

def main():
    try:
        models = [m["id"] for m in get("/v1/models").get("data", [])]
    except Exception as e:
        print(f"  cannot reach router: {e}"); return 2
    if not models:
        print("  router advertises no models"); return 2

    print(f"  verifying {len(models)} presets")
    bad = []
    for name in models:
        try:
            txt, t, wall = ask(name)
        except Exception as e:
            print(f"  {name:22s} FAILED  {type(e).__name__}: {str(e)[:90]}")
            bad.append(name); continue
        ok = EXPECT in txt.lower()
        acc, n = t.get("draft_n_accepted"), t.get("draft_n")
        draft = f" draft {100*acc/n:3.0f}%" if acc and n else " " * 11
        flat = " ".join(txt.split())[:58]
        print(f"  {name:22s} {'OK    ' if ok else 'BAD OUT'} "
              f"{t.get('predicted_per_second', 0):6.2f} t/s{draft} {wall:5.1f}s | {flat}")
        if not ok:
            bad.append(name)

    if bad:
        print(f"\n  {len(bad)} preset(s) failed: {', '.join(bad)}")
        return 1
    print(f"\n  all {len(models)} presets OK")
    return 0

if __name__ == "__main__":
    sys.exit(main())
