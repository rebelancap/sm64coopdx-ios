#!/usr/bin/env python3
"""
Regenerate apps-ios.json and apps-visionos.json (SideStore/AltStore sources) from
the LATEST GitHub release of each app repo listed in config.json.

- One iOS IPA per app  = a release .ipa whose name does NOT contain 'vision'/'xros'.
- One visionOS IPA      = a release .ipa whose name contains 'vision' or 'xros'.
- The version is read from the IPA's CFBundleShortVersionString (must match what the
  installed app reports, or SideStore won't offer the update) — falls back to the tag.
- Existing version history is preserved; unchanged apps are left untouched (no re-download).

Stdlib only (works on ubuntu-latest runners). Uses GITHUB_TOKEN if present for rate limits.
"""
import json, os, sys, io, zipfile, plistlib, fnmatch, urllib.request

GH = "https://api.github.com"
TOKEN = os.environ.get("GITHUB_TOKEN")
HERE = os.path.dirname(os.path.abspath(__file__))


def gh(url):
    hdr = {"Accept": "application/vnd.github+json", "User-Agent": "quake-ports-source"}
    if TOKEN:
        hdr["Authorization"] = f"Bearer {TOKEN}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=hdr)) as r:
        return json.load(r)


def latest_release(repo):
    try:
        return gh(f"{GH}/repos/{repo}/releases/latest")
    except Exception as e:
        print(f"  [{repo}] no latest release ({e})")
        return None


def pick_asset(rel, want_vision):
    for a in rel.get("assets", []):
        n = a["name"].lower()
        if not n.endswith(".ipa"):
            continue
        is_vision = ("vision" in n) or ("xros" in n)
        if is_vision == want_vision:
            return a
    return None


def ipa_version(url, fallback):
    """Read CFBundleShortVersionString from Payload/*.app/Info.plist inside the IPA."""
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "quake-ports-source"})) as r:
            z = zipfile.ZipFile(io.BytesIO(r.read()))
        for n in z.namelist():
            if n.startswith("Payload/") and n.endswith(".app/Info.plist") and n.count("/") == 2:
                v = plistlib.loads(z.read(n)).get("CFBundleShortVersionString")
                if v:
                    return v
    except Exception as e:
        print(f"    (couldn't read IPA version, using tag: {e})")
    return fallback


def load_existing(path):
    try:
        with open(path) as f:
            return {a["bundleIdentifier"]: a for a in json.load(f).get("apps", [])}
    except Exception:
        return {}


def build_app(cfg, rel, want_vision, prev):
    asset = pick_asset(rel, want_vision)
    if not asset:
        print(f"  [{cfg['repo']}] no {'visionOS' if want_vision else 'iOS'} .ipa in latest release")
        return None

    url = asset["browser_download_url"]
    prev_versions = (prev or {}).get("versions", [])
    # Unchanged? keep the previous entry verbatim (no re-download of the IPA).
    if prev_versions and prev_versions[0].get("downloadURL") == url:
        versions = prev_versions
    else:
        tag = rel.get("tag_name", "1.0.0").lstrip("v")
        entry = {
            "version": ipa_version(url, tag),
            "date": rel.get("published_at") or rel.get("created_at"),
            "localizedDescription": (rel.get("body") or "").strip() or "See the release notes on GitHub.",
            "downloadURL": url,
            "size": asset["size"],
            "minOSVersion": cfg["visionosMinOS"] if want_vision else cfg["iosMinOS"],
        }
        # Prepend if it's a genuinely new version, else replace the head.
        if prev_versions and prev_versions[0].get("version") == entry["version"]:
            versions = [entry] + prev_versions[1:]
        else:
            versions = [entry] + prev_versions

    return {
        "name": cfg["name"],
        "bundleIdentifier": cfg["bundleIdentifier"],
        "developerName": cfg.get("developerName", ""),
        "subtitle": cfg.get("subtitle", ""),
        "localizedDescription": cfg.get("localizedDescription", ""),
        "iconURL": cfg.get("iconURL", ""),
        "tintColor": cfg.get("tintColor", "#8a1a1a"),
        "category": "games",
        "screenshotURLs": cfg.get("screenshotURLs", []),
        "versions": versions,
    }


def write_source(kind, cfg, apps, out_path):
    src = dict(cfg["sources"][kind])
    src["apps"] = apps
    src["news"] = []
    with open(out_path, "w") as f:
        json.dump(src, f, indent=2)
        f.write("\n")
    print(f"wrote {out_path} ({len(apps)} app(s))")


def main():
    with open(os.path.join(HERE, "config.json")) as f:
        cfg = json.load(f)

    prev_ios = load_existing(os.path.join(HERE, "apps-ios.json"))
    prev_vos = load_existing(os.path.join(HERE, "apps-visionos.json"))

    ios_apps, vos_apps = [], []
    for app in cfg["apps"]:
        print(f"[{app['repo']}]")
        rel = latest_release(app["repo"])
        if not rel:
            # keep whatever we had so a transient API hiccup doesn't drop the app
            if app["bundleIdentifier"] in prev_ios:
                ios_apps.append(prev_ios[app["bundleIdentifier"]])
            if app["bundleIdentifier"] in prev_vos:
                vos_apps.append(prev_vos[app["bundleIdentifier"]])
            continue
        ios = build_app(app, rel, False, prev_ios.get(app["bundleIdentifier"]))
        vos = build_app(app, rel, True, prev_vos.get(app["bundleIdentifier"]))
        if ios:
            ios_apps.append(ios)
            print(f"  iOS      -> {ios['versions'][0]['version']} ({ios['versions'][0]['size']} B)")
        if vos:
            vos_apps.append(vos)
            print(f"  visionOS -> {vos['versions'][0]['version']} ({vos['versions'][0]['size']} B)")

    write_source("ios", cfg, ios_apps, os.path.join(HERE, "apps-ios.json"))
    write_source("visionos", cfg, vos_apps, os.path.join(HERE, "apps-visionos.json"))


if __name__ == "__main__":
    sys.exit(main())
