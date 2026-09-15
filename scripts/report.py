#!/usr/bin/env python3
"""Render out/report.html from grype JSON so the comparison can be shown on a slide."""
import json, subprocess, sys
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "out"
APP = "demo-app"
SEV = ["Critical", "High", "Medium", "Low", "Negligible", "Unknown"]

def load(flavor):
    m = json.loads((OUT / f"{flavor}.grype.json").read_text())["matches"]
    counts = {s: sum(1 for x in m if x["vulnerability"]["severity"] == s) for s in SEV}
    size = subprocess.check_output(["docker", "images", f"{APP}:{flavor}", "--format", "{{.Size}}"], text=True).strip()
    top = sorted(m, key=lambda x: SEV.index(x["vulnerability"]["severity"]))[:8]
    return counts, size, len(m), top

rows, cards = "", ""
for flavor, label in (("upstream", "python:3.13-slim"), ("chainguard", "cgr.dev/chainguard/python")):
    c, size, total, top = load(flavor)
    cards += f"""<div class="card {flavor}"><h2>{flavor}</h2><div class="base">{label}</div>
<div class="big">{total}</div><div class="sub">known CVEs</div>
<div class="sev">{' '.join(f'<span class="{s.lower()}">{s[:4]} {c[s]}</span>' for s in SEV[:4])}</div>
<div class="sub">{size}</div></div>"""
    for x in top:
        v = x["vulnerability"]; a = x["artifact"]
        rows += f"<tr><td>{flavor}</td><td>{v['id']}</td><td class='{v['severity'].lower()}'>{v['severity']}</td><td>{a['name']} {a['version']}</td></tr>"

html = f"""<!doctype html><html><head><meta charset="utf-8"><title>Chainguard vs upstream</title>
<style>body{{font-family:system-ui;background:#0b1020;color:#e5e7eb;margin:2rem}}
.cards{{display:flex;gap:2rem}} .card{{flex:1;padding:1.5rem;border-radius:12px;background:#111827;border:2px solid #1f2937}}
.card.chainguard{{border-color:#16a34a}} .card.upstream{{border-color:#dc2626}}
.big{{font-size:5rem;font-weight:700}} .base{{color:#93c5fd;font-family:monospace}} .sub{{color:#9ca3af}}
.sev span{{display:inline-block;margin:.5rem .5rem 0 0;padding:.2rem .6rem;border-radius:6px;background:#1f2937}}
.critical{{color:#f87171}} .high{{color:#fb923c}} .medium{{color:#facc15}} .low{{color:#a3e635}}
table{{margin-top:2rem;border-collapse:collapse;width:100%}} td,th{{padding:.4rem .8rem;border-bottom:1px solid #1f2937;text-align:left}}
</style></head><body><h1>Same app. Two base images.</h1><div class="cards">{cards}</div>
<table><tr><th>image</th><th>CVE</th><th>severity</th><th>package</th></tr>{rows}</table></body></html>"""
(OUT / "report.html").write_text(html)
print(OUT / "report.html")
