# Alep Bootstrap

Public bootstrap entrypoint for the private Alep provisioning repo.

This repo should contain only public-safe bootstrap files. Do not put secrets, host-specific config, repo manifests, API keys, SSH keys, or private provisioning data here.

## Run

On a fresh Mac mini:

```sh
bootstrap="$(mktemp "${TMPDIR:-/tmp}/alep-bootstrap.XXXXXX")"
curl -fsSL https://raw.githubusercontent.com/kenzic/alep-bootstrap/main/bootstrap.sh -o "$bootstrap"
bash "$bootstrap" --profile mac-mini --config-repo kenzic/alep
```

For a laptop profile:

```sh
bootstrap="$(mktemp "${TMPDIR:-/tmp}/alep-bootstrap.XXXXXX")"
curl -fsSL https://raw.githubusercontent.com/kenzic/alep-bootstrap/main/bootstrap.sh -o "$bootstrap"
bash "$bootstrap" --profile laptop --config-repo kenzic/alep
```

The temp-file form is preferred over `curl | bash` because child tools cannot accidentally consume the unread bootstrap script from stdin.

## What It Does

The bootstrap script installs Homebrew, `gh`, and `chezmoi`; authenticates GitHub over SSH; clones or updates the private `kenzic/alep` config repo at `~/.local/share/chezmoi`; then applies the selected Alep profile.

If the private config repo is already cloned, rerun the same command. The bootstrap refreshes the source clone and reapplies the profile.
