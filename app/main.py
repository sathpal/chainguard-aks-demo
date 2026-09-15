"""Supply-chain status app: reports what it is running on.

Same code ships in two images (upstream vs Chainguard) so the demo can
compare the *runtime* not the app: OS, shell present?, user, package count.
"""
import os
import platform
import socket
import subprocess
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import HTMLResponse, JSONResponse

app = FastAPI(title="chainguard-aks-demo")

FLAVOR = os.getenv("IMAGE_FLAVOR", "unknown")


def os_release() -> str:
    try:
        for line in Path("/etc/os-release").read_text().splitlines():
            if line.startswith("PRETTY_NAME="):
                return line.split("=", 1)[1].strip('"')
    except OSError:
        pass
    return "unknown"


def package_count() -> int | str:
    if Path("/var/lib/dpkg/status").exists():
        return Path("/var/lib/dpkg/status").read_text().count("Package: ")
    if Path("/lib/apk/db/installed").exists():
        return Path("/lib/apk/db/installed").read_text().count("P:")
    return "n/a"


def facts() -> dict:
    return {
        "image_flavor": FLAVOR,
        "hostname": socket.gethostname(),
        "os": os_release(),
        "python": platform.python_version(),
        "uid": os.getuid(),
        "running_as_root": os.getuid() == 0,
        "shell_present": any(Path(p).exists() for p in ("/bin/sh", "/bin/bash")),
        "package_manager_present": any(
            Path(p).exists() for p in ("/usr/bin/apt", "/usr/bin/apt-get", "/sbin/apk", "/usr/bin/pip")
        ),
        "os_packages": package_count(),
    }


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.get("/api")
def api():
    return JSONResponse(facts())


@app.get("/", response_class=HTMLResponse)
def index():
    f = facts()
    good = f["image_flavor"] == "chainguard"
    color = "#16a34a" if good else "#dc2626"
    rows = "".join(f"<tr><td>{k}</td><td><code>{v}</code></td></tr>" for k, v in f.items())
    return f"""<!doctype html><html><head><meta charset="utf-8">
<title>{FLAVOR} runtime</title>
<style>body{{font-family:system-ui;margin:2rem;background:#0b1020;color:#e5e7eb}}
h1{{color:{color}}} table{{border-collapse:collapse}} td{{padding:.4rem 1rem;border-bottom:1px solid #1f2937}}
code{{color:#93c5fd}}</style></head>
<body><h1>image: {FLAVOR}</h1><p>Same app, different base image. What is underneath?</p>
<table>{rows}</table></body></html>"""


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
