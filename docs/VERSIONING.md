# Versioning — the rules

Austin's rules, 2026-07-27. These govern every build that leaves this
machine. If you are a claude picking this repo up cold: follow them
exactly, and do not invent a scheme.

## The two version fields

visionOS/iOS carry two independent version strings, and they mean
different things:

| Field | Plist key | What it is |
| --- | --- | --- |
| **Marketing version** | `CFBundleShortVersionString` | The public version. This is what the rules below are about, and it is the key SideStore string-compares to decide whether to offer an update. |
| **Build number** | `CFBundleVersion` | Churns per build. Defaults to `git rev-list --count HEAD`; override with `SM64_BUILD_NUMBER`. Never carries meaning to users. |

Set the marketing version with `SM64_MARKETING_VERSION` when building:

```
SM64_MARKETING_VERSION=1.2.0 ./scripts/build-visionos.sh
```

`build-visionos.sh` pins a default (currently `1.2.1`) and asserts BOTH
fields actually substituted into the built plist.

## Rule 1 — small updates bump the patch component

An upstream fold-in, a bugfix, a re-sign: bump the **third** component
only.

```
1.1.1  ->  1.1.2  ->  1.1.3
```

Do not jump the minor or major version for routine work. Reserve a minor
bump (`1.2.0`) for a genuine feature, and keep public numbers
contiguous — users see them.

## Rule 2 — OTA and GitHub release versions MUST match

One number, both places, every public release. The tailnet OTA hub entry
and the GitHub release tag/title are the same version string, always. A
release that is `1.1.2` on GitHub is `1.1.2` on the hub.

This is not cosmetic. The SideStore source is generated from the GitHub
release, so a mismatch means users are offered a version that does not
correspond to what the hub served.

## Rule 3 — OTA-only dev builds get a FOURTH component

When iterating locally and pushing builds to the OTA hub **without**
cutting a GitHub release, add a fourth component and increment it:

```
1.1.2.1  ->  1.1.2.2  ->  1.1.2.3  ...
```

These are OTA-only. They never get a GitHub release and never appear in
the SideStore source. They keep accumulating until one of them is worth
releasing publicly — at which point it ships as the next plain
three-component version (here, `1.1.3`), and the four-component series
resets under that.

So the lifecycle is:

```
1.1.2            <- public release (GitHub + OTA, matching)
  1.1.2.1        <- local dev build, OTA only
  1.1.2.2        <- local dev build, OTA only
1.1.3            <- next public release (GitHub + OTA, matching)
```

## Release checklist

1. Build with `SM64_MARKETING_VERSION=<v>`.
2. Publish OTA via `scripts/publish-vision-ota.sh "<notes>"` — notes are
   mandatory (see `~/dev/OTA-PUBLISHING.md`).
3. Cut the GitHub release at the SAME version, titled
   `sm64coopdx-visionos <v>`, with `sm64coopdx-<v>-visionOS.ipa`
   attached. The asset filename must contain "vision" — the SideStore
   `generate.py` filters on it.
4. The release Action refreshes the SideStore source automatically.

Skip steps 3–4 for a four-component OTA-only build.
