#!/usr/bin/env python3
"""Fails if any locked Dart/Flutter dependency has a known vulnerability (OSV.dev)."""
import json, re, sys, urllib.request

def packages(lock_path):
    text = open(lock_path).read()
    return re.findall(r'\n  ([a-z0-9_]+):\n(?:    .*\n)*?    version: "([^"]+)"', text)

pkgs = sorted({p for path in sys.argv[1:] for p in packages(path)})
query = {"queries": [{"package": {"name": n, "ecosystem": "Pub"}, "version": v} for n, v in pkgs]}
req = urllib.request.Request("https://api.osv.dev/v1/querybatch", data=json.dumps(query).encode(),
                             headers={"Content-Type": "application/json"})
results = json.load(urllib.request.urlopen(req, timeout=60))["results"]
bad = [(pkgs[i], [v["id"] for v in r["vulns"]]) for i, r in enumerate(results) if r.get("vulns")]
print(f"{len(pkgs)} packages checked against OSV.dev")
for (name, ver), ids in bad:
    print(f"VULNERABLE: {name} {ver}: {', '.join(ids)}")
sys.exit(1 if bad else 0)
