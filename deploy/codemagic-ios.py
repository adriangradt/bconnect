#!/usr/bin/env python3
"""Build the iOS IPA on Codemagic and publish it for AltStore Classic.

Runs on the homelab. Codemagic clones https://github.com/adriangradt/bconnect,
runs the `ios-altstore`
workflow from codemagic.yaml, and this script downloads the IPA, checks it
with deploy/publish.py and puts it online together with altstore.json.

One-time setup (see BUILD.md): Codemagic API token in
~/.bedrockbridge-codemagic/api-token, GitHub repository added as app in Codemagic.

  deploy/codemagic-ios.py               # push, build, download, publish
  deploy/codemagic-ios.py --no-publish  # stop after download and checks
"""

import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONF = Path.home() / ".bedrockbridge-codemagic"
API = "https://api.codemagic.io"
WORKFLOW = "ios-altstore"
REPO_MATCH = "adriangradt/bconnect"
OUT = ROOT / "build" / "codemagic"
DONE = {"finished", "failed", "canceled", "timeout", "skipped"}


def fail(msg: str) -> None:
    sys.exit(f"codemagic: {msg}")


def token() -> str:
    f = CONF / "api-token"
    if not f.exists():
        fail(f"{f} missing. Codemagic → Team settings → Codemagic API → Show, then save the token there.")
    return f.read_text().strip()


def api(method: str, path: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"x-auth-token": token(), "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        fail(f"{method} {path}: HTTP {e.code} {e.read().decode(errors='replace')[:400]}")


def app_id() -> str:
    f = CONF / "app-id"
    if f.exists():
        return f.read_text().strip()
    apps = api("GET", "/apps").get("applications", [])
    for a in apps:
        if REPO_MATCH in json.dumps(a):
            (CONF / "app-id").write_text(a["_id"] + "\n")
            return a["_id"]
    fail("no Codemagic app for " + REPO_MATCH + " found. Add it once in the Codemagic UI (see BUILD.md).")


def push() -> str:
    def git(*a: str) -> str:
        return subprocess.run(["git", "-C", str(ROOT), *a], check=True, capture_output=True, text=True).stdout

    if git("status", "--porcelain").strip():
        fail("working tree has uncommitted changes; commit them first so the build matches a commit")
    git("push", "-q", "github", "main")
    return git("rev-parse", "--short", "HEAD").strip()


def download(url: str, dest: Path) -> None:
    req = urllib.request.Request(url, headers={"x-auth-token": token()})
    try:
        with urllib.request.urlopen(req, timeout=300) as r, dest.open("wb") as f:
            while chunk := r.read(1 << 20):
                f.write(chunk)
        return
    except urllib.error.HTTPError as e:
        if e.code not in (401, 403):
            raise
    # Fallback: a short-lived public link, as documented in the Artifacts API.
    path = url.removeprefix(API)
    pub = api("POST", path + "/public-url", {"expiresAt": int(time.time()) + 600})
    with urllib.request.urlopen(pub["url"], timeout=300) as r, dest.open("wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-publish", action="store_true")
    ap.add_argument("--build-id", help="reuse a finished build instead of starting one")
    args = ap.parse_args()

    if args.build_id:
        build_id = args.build_id
    else:
        commit = push()
        build_id = api("POST", "/builds", {"appId": app_id(), "workflowId": WORKFLOW, "branch": "main"})["buildId"]
        print(f"started build {build_id} for commit {commit}")

    last = None
    while True:
        build = api("GET", f"/builds/{build_id}")["build"]
        status = build.get("status")
        if status != last:
            print(f"{time.strftime('%H:%M:%S')} {status}", flush=True)
            last = status
        if status in DONE:
            break
        time.sleep(30)
    if status != "finished":
        fail(f"build ended with status {status}: https://codemagic.io/app/{build.get('appId', '')}/build/{build_id}")

    arts = build.get("artefacts") or build.get("artifacts") or []
    ipa = next((a for a in arts if a.get("name", "").endswith(".ipa")), None)
    if not ipa:
        fail(f"build has no .ipa artifact: {[a.get('name') for a in arts]}")
    OUT.mkdir(parents=True, exist_ok=True)
    dest = OUT / "BedrockBridge.ipa"
    download(ipa["url"], dest)
    print(f"downloaded {dest} ({dest.stat().st_size / 1024 / 1024:.1f} MB)")

    cmd = [sys.executable, str(ROOT / "deploy/publish.py"), "--ipa-only", "--ipa", str(dest)]
    if args.no_publish:
        # Same checks as publishing, without copying anything.
        sys.path.insert(0, str(ROOT / "deploy"))
        import publish  # noqa: E402

        print("IPA ok:", publish.verify_ipa(dest))
        return
    subprocess.run(cmd, check=True)


if __name__ == "__main__":
    main()
