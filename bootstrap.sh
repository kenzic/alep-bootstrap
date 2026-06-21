#!/usr/bin/env bash
set -euo pipefail

# Public-safe Alep bootstrap. This file must not contain private repo names,
# tokens, hostnames, API keys, SSH keys, or machine-local secrets.

PROFILE="${ALEP_PROFILE:-}"
SOURCE_DIR=""
CONFIG_REPO="${ALEP_CONFIG_REPO:-}"
DRY_RUN=0
SKIP_PRE_CHECKLIST="${ALEP_SKIP_PRE_CHECKLIST:-${ALEP_SKIP_CHECKLIST:-0}}"
SKIP_POST_CHECKLIST="${ALEP_SKIP_POST_CHECKLIST:-${ALEP_SKIP_CHECKLIST:-0}}"
PRE_CHECKLIST_RAN=0

usage() {
  cat <<'USAGE'
Usage:
  ./bootstrap.sh --profile mac-mini
  ./bootstrap.sh --profile laptop --source /path/to/alep
  ./bootstrap.sh --profile mac-mini --config-repo owner/alep-private

Options:
  --profile mac-mini|laptop  Required host profile.
  --source PATH              Use an existing local private Alep source directory.
  --config-repo OWNER/REPO   Clone the private Alep config repo with GitHub CLI.
  --repo OWNER/REPO          Compatibility alias for --config-repo.
  --dry-run                  Print planned actions without installing or cloning.
  --skip-pre-checklist       Do not run the pre-install checklist.
  --skip-post-checklist      Do not run the post-install checklist.
  --skip-checklist           Do not run either manual checklist.
  -h, --help                 Show this help.

Environment:
  ALEP_PROFILE               Default profile when --profile is omitted.
  ALEP_CONFIG_REPO           Default private config repo when --config-repo is omitted.
  ALEP_CHEZMOI_SOURCE        Clone target for --config-repo. Defaults to ~/.local/share/chezmoi.
  ALEP_SKIP_PRE_CHECKLIST=1  Skip the pre-install checklist.
  ALEP_SKIP_POST_CHECKLIST=1 Skip the post-install checklist.
  ALEP_SKIP_CHECKLIST=1      Skip both manual checklists.
USAGE
}

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

run_shell() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ %s\n' "$*"
    return 0
  fi

  /bin/bash -c "$*"
}

detect_source_dir() {
  local script_path script_dir

  script_path="$0"
  [ -f "$script_path" ] || return 1

  script_dir="$(cd -- "$(dirname -- "$script_path")" && pwd -P)"
  if [ -d "$script_dir/.chezmoidata" ] && [ -d "$script_dir/.chezmoiscripts" ]; then
    printf '%s\n' "$script_dir"
    return 0
  fi

  return 1
}

abs_dir() {
  local path="$1"

  [ -d "$path" ] || die "directory does not exist: $path"
  (cd -- "$path" && pwd -P)
}

toml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

load_homebrew() {
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
    return 0
  fi

  if [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
    return 0
  fi

  command -v brew >/dev/null 2>&1
}

is_macos() {
  [ "$(uname -s 2>/dev/null || true)" = "Darwin" ]
}

has_admin_group() {
  id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx admin
}

require_sudo_for_homebrew() {
  if ! is_macos; then
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would validate sudo access before installing Homebrew"
    return 0
  fi

  if ! has_admin_group; then
    die "Homebrew install requires macOS administrator access. Add user $(id -un) to the admin group, then rerun Alep."
  fi

  log "Validating sudo access for Homebrew"
  if ! sudo -v; then
    die "Homebrew install requires sudo access. Confirm user $(id -un) can administer this Mac, then rerun Alep."
  fi
}

ensure_homebrew() {
  if load_homebrew; then
    log "Homebrew is available"
    return 0
  fi

  require_sudo_for_homebrew

  log "Installing Homebrew"
  run_shell 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

  if [ "$DRY_RUN" -eq 0 ]; then
    load_homebrew || die "Homebrew installed but brew is not on PATH"
  fi
}

ensure_formula() {
  local formula="$1"
  local binary="$2"

  if command -v "$binary" >/dev/null 2>&1; then
    log "$binary is available"
    return 0
  fi

  log "Installing $formula"
  run brew install "$formula"
}

ensure_bootstrap_tools() {
  ensure_formula gh gh
  ensure_formula chezmoi chezmoi
}

ensure_github_auth() {
  if [ "$DRY_RUN" -eq 1 ]; then
    if command -v gh >/dev/null 2>&1 && gh auth status --hostname github.com >/dev/null 2>&1; then
      log "GitHub CLI is authenticated"
      run gh auth setup-git --hostname github.com
      return 0
    fi

    log "Would authenticate GitHub CLI with SSH git protocol"
    run gh auth login --hostname github.com --git-protocol ssh
    run gh auth setup-git --hostname github.com
    return 0
  fi

  if ! command -v gh >/dev/null 2>&1; then
    die "gh is required before GitHub authentication"
  fi

  if gh auth status --hostname github.com >/dev/null 2>&1; then
    log "GitHub CLI is authenticated"
    run gh auth setup-git --hostname github.com
    return 0
  fi

  log "Authenticating GitHub CLI with SSH git protocol"
  run gh auth login --hostname github.com --git-protocol ssh
  run gh auth setup-git --hostname github.com
}

clone_source_repo() {
  local target

  target="${ALEP_CHEZMOI_SOURCE:-$HOME/.local/share/chezmoi}"

  if [ -d "$target/.git" ]; then
    SOURCE_DIR="$(abs_dir "$target")"
    log "Refreshing existing source clone at $SOURCE_DIR"
    run git -C "$SOURCE_DIR" fetch --prune origin

    if [ "$DRY_RUN" -eq 1 ]; then
      run git -C "$SOURCE_DIR" merge --ff-only '@{u}'
      return 0
    fi

    if [ -n "$(git -C "$SOURCE_DIR" status --porcelain)" ]; then
      die "existing source clone has local changes; refusing to update: $SOURCE_DIR"
    fi

    if ! git -C "$SOURCE_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      die "existing source clone has no upstream; set an upstream or update it manually: $SOURCE_DIR"
    fi

    git -C "$SOURCE_DIR" merge --ff-only '@{u}'
    return 0
  fi

  if [ -e "$target" ]; then
    die "source target exists but is not a git repo: $target"
  fi

  log "Cloning $CONFIG_REPO to $target"
  run mkdir -p "$(dirname -- "$target")"
  run gh repo clone "$CONFIG_REPO" "$target"
  SOURCE_DIR="$target"
}

write_chezmoi_config() {
  local config_dir config_file backup escaped_source escaped_profile

  config_dir="$HOME/.config/chezmoi"
  config_file="$config_dir/chezmoi.toml"
  escaped_source="$(toml_escape "$SOURCE_DIR")"
  escaped_profile="$(toml_escape "$PROFILE")"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would write $config_file for profile $PROFILE and source $SOURCE_DIR"
    return 0
  fi

  mkdir -p "$config_dir"

  if [ -f "$config_file" ] && ! grep -q 'Managed by Alep bootstrap' "$config_file"; then
    backup="$config_file.alep-backup-$(date +%Y%m%d%H%M%S)"
    cp "$config_file" "$backup"
    log "Backed up existing chezmoi config to $backup"
  fi

  {
    printf '# Managed by Alep bootstrap. Edit the Alep repo data files, then rerun bootstrap.\n'
    printf 'sourceDir = "%s"\n\n' "$escaped_source"
    printf '[data]\n'
    printf 'profile = "%s"\n' "$escaped_profile"
  } >"$config_file"
}

apply_chezmoi() {
  log "Applying Alep profile $PROFILE"
  run chezmoi apply
}

run_pre_install_checklist() {
  local checklist args

  if [ "$PRE_CHECKLIST_RAN" -eq 1 ]; then
    return 0
  fi

  if [ "$SKIP_PRE_CHECKLIST" = "1" ]; then
    log "Skipping pre-install checklist"
    PRE_CHECKLIST_RAN=1
    return 0
  fi

  checklist="$SOURCE_DIR/scripts/pre-install-checklist.sh"

  if [ ! -f "$checklist" ]; then
    log "Pre-install checklist not found at $checklist"
    PRE_CHECKLIST_RAN=1
    return 0
  fi

  args=(--profile "$PROFILE")
  if [ "$DRY_RUN" -eq 1 ]; then
    args+=(--print-only)
  fi

  log "Running pre-install checklist"
  run "$checklist" "${args[@]}"
  PRE_CHECKLIST_RAN=1
}

run_post_install_checklist() {
  local checklist

  if [ "$SKIP_POST_CHECKLIST" = "1" ]; then
    log "Skipping post-install checklist"
    return 0
  fi

  checklist="$SOURCE_DIR/scripts/post-install-checklist.sh"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would run post-install checklist"
    run "$checklist" --profile "$PROFILE" --print-only
    return 0
  fi

  if [ ! -f "$checklist" ]; then
    log "Post-install checklist not found at $checklist"
    return 0
  fi

  log "Running post-install checklist"
  run "$checklist" --profile "$PROFILE"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -ge 2 ] || die "--profile requires a value"
      PROFILE="$2"
      shift 2
      ;;
    --source)
      [ "$#" -ge 2 ] || die "--source requires a value"
      SOURCE_DIR="$2"
      shift 2
      ;;
    --config-repo | --repo)
      [ "$#" -ge 2 ] || die "$1 requires a value"
      CONFIG_REPO="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --skip-pre-checklist)
      SKIP_PRE_CHECKLIST=1
      shift
      ;;
    --skip-post-checklist)
      SKIP_POST_CHECKLIST=1
      shift
      ;;
    --skip-checklist)
      SKIP_PRE_CHECKLIST=1
      SKIP_POST_CHECKLIST=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

case "$PROFILE" in
  mac-mini | laptop)
    ;;
  "")
    die "--profile mac-mini|laptop is required"
    ;;
  *)
    die "unsupported profile: $PROFILE"
    ;;
esac

if [ -n "$SOURCE_DIR" ] && [ -n "$CONFIG_REPO" ]; then
  die "use --source or --config-repo, not both"
fi

if [ -n "$SOURCE_DIR" ]; then
  SOURCE_DIR="$(abs_dir "$SOURCE_DIR")"
else
  SOURCE_DIR="$(detect_source_dir || true)"
fi

if [ -n "$SOURCE_DIR" ]; then
  run_pre_install_checklist
fi

ensure_homebrew
ensure_bootstrap_tools

if [ -z "$SOURCE_DIR" ]; then
  [ -n "$CONFIG_REPO" ] || die "provide --source PATH or --config-repo OWNER/REPO"
  ensure_github_auth
  clone_source_repo
  run_pre_install_checklist
fi

write_chezmoi_config
apply_chezmoi
run_post_install_checklist

log "Alep provisioning complete"
