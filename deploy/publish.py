#!/usr/bin/env python3
"""Publish BedrockBridge builds to https://stalincraft.de/bedrockbridge/.

Verifies each artifact before it goes online, copies it to
/var/www/bedrockbridge/downloads/ and regenerates the download page from
whatever artifacts are present there. Needs sudo for /var/www.

  deploy/publish.py                      # page + APK from build/
  deploy/publish.py --ipa path/to.ipa    # also publish an unsigned iOS build for AltStore Classic
  deploy/publish.py --page-only          # only regenerate the page
  deploy/publish.py --ipa-only --ipa x   # only add or replace the IPA
"""

import argparse
import datetime
import hashlib
import html
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from string import Template

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "deploy" / "site"
TARGET = Path("/var/www/bedrockbridge")
DOWNLOADS = TARGET / "downloads"
DEFAULT_APK = ROOT / "build/app/outputs/flutter-apk/app-release.apk"
ANDROID_HOME = Path(os.environ.get("ANDROID_HOME", Path.home() / "dev-tools/android-sdk"))
BUILD_TOOLS = ANDROID_HOME / "build-tools/36.0.0"
EXPECTED_SIGNER = "CN=BedrockBridge, O=stalincraft.de, C=DE"


def fail(msg: str) -> None:
    sys.exit(f"publish: {msg}")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run(*cmd: str) -> str:
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        fail(f"{' '.join(cmd)} failed:\n{r.stdout}{r.stderr}")
    return r.stdout


def verify_apk(apk: Path) -> dict:
    out = run(str(BUILD_TOOLS / "apksigner"), "verify", "--print-certs", "--verbose", str(apk))
    if "Verifies" not in out:
        fail("APK signature does not verify")
    dn = re.search(r"Signer #1 certificate DN: (.+)", out)
    if not dn or dn.group(1).strip() != EXPECTED_SIGNER:
        fail(f"APK is not signed with the release key (signer: {dn.group(1) if dn else '?'})")
    cert = re.search(r"Signer #1 certificate SHA-256 digest: ([0-9a-f]+)", out).group(1)
    badging = run(str(BUILD_TOOLS / "aapt2"), "dump", "badging", str(apk))
    pkg = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging)
    if not pkg or pkg.group(1) != "de.stalincraft.bedrockbridge":
        fail("unexpected package name in APK")
    min_sdk = re.search(r"minSdkVersion:'(\d+)'", badging).group(1)
    return {"version": pkg.group(3), "code": pkg.group(2), "min_sdk": int(min_sdk), "cert": cert}


def verify_ipa(ipa: Path) -> dict:
    """Structural checks of an IPA for AltStore Classic.

    AltStore re-signs every app with the user's Apple ID, so an unsigned
    IPA (flutter build ios --no-codesign) is fine. A signed one must not
    carry entitlements a free Apple ID cannot use; that can only be checked
    on macOS, so signed IPAs are rejected here.
    """
    try:
        z = zipfile.ZipFile(ipa)
    except zipfile.BadZipFile:
        fail("IPA is not a zip archive")
    names = set(z.namelist())
    plist_name = next((n for n in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)), None)
    if not plist_name:
        fail("IPA has no Payload/*.app/Info.plist")
    app_dir = plist_name.rsplit("/", 1)[0]
    info = plistlib.loads(z.read(plist_name))
    if info.get("CFBundleIdentifier") != "de.stalincraft.bedrockbridge":
        fail(f"unexpected bundle ID {info.get('CFBundleIdentifier')}")
    exe = f"{app_dir}/{info.get('CFBundleExecutable', '')}"
    if exe not in names:
        fail(f"executable {exe} missing")
    head = z.read(exe)[:8]
    # 64-bit Mach-O (0xfeedfacf, little endian) for ARM64 (CPU type 0x0100000c).
    if head[:4] != b"\xcf\xfa\xed\xfe" or struct.unpack("<I", head[4:8])[0] != 0x0100000C:
        fail("executable is not an arm64 iOS binary")
    for fw in ("Flutter.framework/Flutter", "App.framework/App"):
        if f"{app_dir}/Frameworks/{fw}" not in names:
            fail(f"Frameworks/{fw} missing, not a Flutter release build")
    if f"{app_dir}/embedded.mobileprovision" in names:
        fail("IPA is signed; build it with --no-codesign for AltStore Classic")
    privacy = {k: v for k, v in info.items() if k.endswith("UsageDescription")}
    return {
        "version": info.get("CFBundleShortVersionString", "?"),
        "build": info.get("CFBundleVersion", "1"),
        "min_ios": info.get("MinimumOSVersion", "?"),
        "privacy": privacy,
    }


SITE_URL = "https://stalincraft.de/bedrockbridge/"
SOURCE_URL = SITE_URL + "altstore.json"
SIDESTORE_URL = SITE_URL + "sidestore.json"


def altstore_source(ipa_meta: dict | None, ipa: Path) -> dict:
    """AltStore Classic source, see https://faq.altstore.io/developers/make-a-source."""
    apps = []
    if ipa_meta:
        apps.append({
            "name": "BedrockBridge",
            "bundleIdentifier": "de.stalincraft.bedrockbridge",
            "developerName": "stalincraft.de",
            "subtitle": "Bedrock-Server im LAN-Tab",
            "localizedDescription": (
                "BedrockBridge zeigt Server-Status von Minecraft-Bedrock-Servern, sucht Welten im WLAN "
                "und bringt Remote-Server wie stalincraft.de in den LAN-Tab anderer Geräte.\n\n"
                "Hinweis: Auf iOS läuft die Bridge nur, solange die App im Vordergrund ist. "
                "LAN-Suche und Bridge brauchen die Berechtigung „Lokales Netzwerk“."
            ),
            "iconURL": SITE_URL + "icon.png",
            "tintColor": "#5D9C3C",
            "category": "utilities",
            "versions": [{
                "version": ipa_meta["version"],
                "buildVersion": str(ipa_meta["build"]),
                "date": datetime.datetime.fromtimestamp(ipa.stat().st_mtime, datetime.timezone.utc)
                .replace(microsecond=0).isoformat(),
                "localizedDescription": "Aktuelle Version von stalincraft.de.",
                "downloadURL": SITE_URL + "downloads/BedrockBridge.ipa",
                "size": ipa.stat().st_size,
                "minOSVersion": str(ipa_meta["min_ios"]),
            }],
            # Unsigned build: no entitlements. AltStore compares this with the IPA.
            "appPermissions": {"entitlements": [], "privacy": ipa_meta["privacy"]},
        })
    return {
        "name": "stalincraft.de",
        "identifier": "de.stalincraft.altstore",
        "subtitle": "Apps rund um den Minecraft-Server stalincraft.de",
        "website": "https://stalincraft.de/",
        "iconURL": SITE_URL + "icon.png",
        "tintColor": "#5D9C3C",
        "featuredApps": [a["bundleIdentifier"] for a in apps],
        "apps": apps,
        "news": [],
    }


ANDROID_VERSIONS = {24: "7.0", 26: "8.0", 28: "9", 29: "10", 30: "11", 31: "12", 33: "13", 34: "14", 35: "15"}


def sidestore_source(ipa_meta: dict | None, ipa: Path) -> dict:
    """Same source for SideStore. SideStore treats sources with build or
    marketplace fields as notarized and refuses them, so those are dropped."""
    src = altstore_source(ipa_meta, ipa)
    src["identifier"] = "de.stalincraft.sidestore"
    for app in src["apps"]:
        app.pop("marketplaceID", None)
        for v in app["versions"]:
            v.pop("buildVersion", None)
    return src


def mb(path: Path) -> str:
    return f"{path.stat().st_size / 1024 / 1024:.1f} MB".replace(".", ",")


def build_page(apk_meta: dict | None, ipa_meta: dict | None, out_dir: Path) -> None:
    e = html.escape
    apk = DOWNLOADS / "BedrockBridge.apk"
    ipa = DOWNLOADS / "BedrockBridge.ipa"
    if apk_meta and apk.exists():
        android = f"""<span class="bb-status bb-status-ok">Verfügbar</span>
        <a class="mc-knopf bb-knopf-download" href="downloads/BedrockBridge.apk" download>APK herunterladen</a>
        <dl class="bb-daten">
          <dt>Version</dt><dd>{e(apk_meta['version'])}</dd>
          <dt>Größe</dt><dd>{mb(apk)}</dd>
          <dt>Benötigt</dt><dd>Android {ANDROID_VERSIONS.get(apk_meta['min_sdk'], apk_meta['min_sdk'])} oder neuer</dd>
          <dt>SHA-256</dt><dd><code class="bb-hash">{sha256(apk)}</code></dd>
        </dl>"""
    else:
        android = """<span class="bb-status bb-status-warte">In Arbeit</span>
        <p>Die Android-Version wird gerade gebaut.</p>"""
    if ipa_meta and ipa.exists():
        ios = f"""<span class="bb-status bb-status-ok">Verfügbar über SideStore und AltStore</span>
        <a class="mc-knopf bb-knopf-download" href="sidestore://source?url={SIDESTORE_URL}">In SideStore öffnen</a>
        <p>SideStore erneuert die App alle 7 Tage auf dem iPhone selbst, ohne Computer.
        Klappt der Knopf nicht: SideStore → Sources → + und diese Adresse einfügen:</p>
        <p><code class="bb-hash">{SIDESTORE_URL}</code></p>
        <a class="mc-knopf" href="altstore-classic://source?url={SOURCE_URL}">In AltStore Classic öffnen</a>
        <dl class="bb-daten">
          <dt>Version</dt><dd>{e(ipa_meta['version'])}</dd>
          <dt>Größe</dt><dd>{mb(ipa)}</dd>
          <dt>Benötigt</dt><dd>iOS {e(str(ipa_meta['min_ios']))} oder neuer, SideStore oder AltStore Classic</dd>
          <dt>IPA</dt><dd><a href="downloads/BedrockBridge.ipa">BedrockBridge.ipa</a></dd>
          <dt>SHA-256</dt><dd><code class="bb-hash">{sha256(ipa)}</code></dd>
        </dl>"""
    else:
        ios = """<span class="bb-status bb-status-warte">Bald über AltStore</span>
        <p>Die iOS-App ist fertig programmiert und kommt über <strong>AltStore Classic</strong>.
        Sobald die IPA gebaut ist, erscheint hier der Knopf zum Hinzufügen.</p>
        <p>Bis dahin: Ein Android-Handy im selben WLAN reicht, damit auch iPhone, iPad und Konsolen den Server sehen.</p>"""

    page = Template((SITE / "index.html.tmpl").read_text()).substitute(
        android_block=android,
        ios_block=ios,
        cert_sha256=e(apk_meta["cert"]) if apk_meta else "–",
        build_date=datetime.date.today().strftime("%d.%m.%Y"),
        css_version=sha256(SITE / "bedrockbridge.css")[:8],
    )
    (out_dir / "index.html").write_text(page)
    shutil.copy(SITE / "bedrockbridge.css", out_dir / "bedrockbridge.css")
    shutil.copy(SITE / "icon.png", out_dir / "icon.png")
    (out_dir / "altstore.json").write_text(
        json.dumps(altstore_source(ipa_meta, ipa), ensure_ascii=False, indent=2) + "\n"
    )
    (out_dir / "sidestore.json").write_text(
        json.dumps(sidestore_source(ipa_meta, ipa), ensure_ascii=False, indent=2) + "\n"
    )
    sums = [f"{sha256(p)}  {p.name}" for p in (apk, ipa) if p.exists()]
    (out_dir / "SHA256SUMS.txt").write_text("\n".join(sums) + "\n" if sums else "")


def sudo(*cmd: str) -> None:
    subprocess.run(["sudo", "-n", *cmd], check=True)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apk", type=Path, default=DEFAULT_APK)
    ap.add_argument("--ipa", type=Path)
    ap.add_argument("--page-only", action="store_true")
    ap.add_argument("--ipa-only", action="store_true", help="publish --ipa without touching the APK")
    args = ap.parse_args()

    sudo("install", "-d", "-m", "755", str(TARGET), str(DOWNLOADS))

    if args.ipa_only:
        if not args.ipa:
            fail("--ipa-only needs --ipa")
        verify_ipa(args.ipa)
        sudo("install", "-m", "644", str(args.ipa), str(DOWNLOADS / "BedrockBridge.ipa"))
    elif not args.page_only:
        if not args.apk.exists():
            fail(f"{args.apk} not found, run flutter build apk --release first")
        verify_apk(args.apk)
        sudo("install", "-m", "644", str(args.apk), str(DOWNLOADS / "BedrockBridge.apk"))
        if args.ipa:
            verify_ipa(args.ipa)
            sudo("install", "-m", "644", str(args.ipa), str(DOWNLOADS / "BedrockBridge.ipa"))

    # The page only lists what is online and verifies again.
    apk_meta = verify_apk(DOWNLOADS / "BedrockBridge.apk") if (DOWNLOADS / "BedrockBridge.apk").exists() else None
    ipa_meta = verify_ipa(DOWNLOADS / "BedrockBridge.ipa") if (DOWNLOADS / "BedrockBridge.ipa").exists() else None

    with tempfile.TemporaryDirectory() as tmp:
        t = Path(tmp)
        build_page(apk_meta, ipa_meta, t)
        sudo("install", "-m", "644", *(str(t / f) for f in ("index.html", "bedrockbridge.css", "icon.png", "altstore.json", "sidestore.json")),
             str(TARGET))
        sudo("install", "-m", "644", str(t / "SHA256SUMS.txt"), str(DOWNLOADS))

    print(f"published to {TARGET}")
    print(f"  APK: {'version ' + apk_meta['version'] if apk_meta else 'none'}")
    print(f"  IPA: {'version ' + ipa_meta['version'] if ipa_meta else 'none'}")


if __name__ == "__main__":
    main()
