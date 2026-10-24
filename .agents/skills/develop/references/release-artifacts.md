# Release archives

- Date: 2026-10-24.
- Scope: CI native downloads, `.github/workflows/release.yml` archive assembly
  and verification.

## Native downloads

OTP 28.5.0.6 introduced a default 10 KiB `:httpc` response-header limit. The
main-branch CI runs on OTP 28.5.0.8 failed downloading RRule 0.7.0, before
product tests ran. RustlerPrecompiled 0.10.0 and ZiglerPrecompiled 0.1.6 do not
expose the per-request header-size override; pinning an older runtime or
changing global profile settings is not the fix.

CI, Test, TLS and Release workflows now run `scripts/prefetch_nifs.exs` after
fetching dependencies. It downloads the locked packages' shipped x86_64 Linux
glibc archives over HTTPS with curl into the loaders' documented global cache
directories. It checks package versions against `mix.lock`, requires every
package's checksum manifest and target archives, and verifies SHA-256 before
atomically installing each archive. Native loaders retain their own checksum
verification and variant selection. Missing or mismatched inputs fail the
build; dependency sources and TLS verification are unchanged.

The helper currently covers RRule, MDEx Native, DuskMoon OXC/Oxide/Vize/
QuickBEAM and lazy_html. Package upgrades must retain their shipped checksum
format and release URL contracts or update this explicit inventory. The helper
rejects other runner platforms. Docker builds retain their existing OTP 28.2
base and do not require this workflow-specific cache step.

Validation evidence lives under root `tmp/release-v0.6.9/nif-prefetch/`: empty
cache downloads of 15 real archives, rejection of absent manifests/targets,
invalid hashes, corrupt cache files, bad downloads and curl failures, plus
successful offline cache reuse and clean strict compilation. Original failed
CI logs remain alongside that directory.

## Output isolation

The release workflow restores a broad `_build` cache. Reusing its existing
`_build/prod/rel` outputs with `mix release --overwrite` retains obsolete
application/version directories. Earlier archives contained surplus libraries;
the Gaoxy migration must not ship cached Bandit/ThousandIsland files.

Each workflow run now creates a fresh directory under `RUNNER_TEMP` and builds
both releases with explicit `--path` destinations. Archive filenames and top-level
`manifold` / `manifold_edge` layout are unchanged. Version bumping, tagging,
GitHub publication and Docker workflow inputs retain their existing behavior.

## Validation

Before publishing, check the workflow shell syntax and assemble both releases
into new destinations. Verify archive contents against the active release
closure, including one directory per packaged application, matching versions,
no Bandit/ThousandIsland and no test artifacts.

After publishing, verify both GitHub asset digests and sizes, extract into fresh
directories, and run actual Web/API/signed Edge HTTP probes with disposable
configuration. Check published image provenance separately from runtime
BuildInfo: archive compilation precedes the workflow's version-bump commit,
while Docker builds from the final tag. Record both expected source revisions.

The release evidence is retained under root `tmp/release-v0.6.9/`. Publication
and packaged acceptance remain pending until the workflow/artifact checks pass.
