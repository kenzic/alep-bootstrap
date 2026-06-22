#!/usr/bin/env bash
set -Eeuo pipefail

# Public-safe Alep bootstrap. This file must not contain private repo names,
# tokens, hostnames, API keys, SSH keys, or machine-local secrets.

PROFILE="${ALEP_PROFILE:-}"
SOURCE_DIR=""
CONFIG_REPO="${ALEP_CONFIG_REPO:-}"
DRY_RUN=0
NON_INTERACTIVE="${ALEP_NON_INTERACTIVE:-0}"
SKIP_PRE_CHECKLIST="${ALEP_SKIP_PRE_CHECKLIST:-${ALEP_SKIP_CHECKLIST:-0}}"
SKIP_POST_CHECKLIST="${ALEP_SKIP_POST_CHECKLIST:-${ALEP_SKIP_CHECKLIST:-0}}"
PRE_CHECKLIST_RAN=0
PUBLIC_PREFLIGHT_RAN=0

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
  ALEP_NON_INTERACTIVE=1     Print public preflight instead of prompting.
  ALEP_SKIP_PRE_CHECKLIST=1  Skip the pre-install checklist.
  ALEP_SKIP_POST_CHECKLIST=1 Skip the post-install checklist.
  ALEP_SKIP_CHECKLIST=1      Skip both manual checklists.
USAGE
}

log() {
  printf '==> %s\n' "$*"
}

log_err() {
  printf '==> %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

on_error() {
  local status=$?
  local line command

  line="${BASH_LINENO[0]:-${LINENO:-unknown}}"
  command="${BASH_COMMAND:-unknown}"
  log_err "Bootstrap failed near line $line while running: $command"
  exit "$status"
}

trap on_error ERR

install_error_trap() {
  trap on_error ERR
}

run() {
  local status

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  trap - ERR
  set +e
  "$@"
  status=$?
  set -e
  install_error_trap

  if [ "$status" -ne 0 ]; then
    printf 'error: command failed with status %d:' "$status" >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    exit "$status"
  fi
}

run_shell() {
  local status

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ %s\n' "$*"
    return 0
  fi

  trap - ERR
  set +e
  /bin/bash -c "$*"
  status=$?
  set -e
  install_error_trap

  if [ "$status" -ne 0 ]; then
    printf 'error: shell command failed with status %d: %s\n' "$status" "$*" >&2
    exit "$status"
  fi
}

detect_source_dir() {
  local script_path script_dir candidate

  script_path="$0"
  [ -f "$script_path" ] || return 1

  script_dir="$(cd -- "$(dirname -- "$script_path")" && pwd -P)"
  for candidate in "$script_dir" "$script_dir/.."; do
    candidate="$(cd -- "$candidate" && pwd -P)"
    if [ -d "$candidate/.chezmoidata" ] && [ -d "$candidate/.chezmoiscripts" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

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

remove_delete_repo_scope() {
  local output

  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would remove delete_repo from GitHub CLI token if present"
    run gh auth refresh --hostname github.com --remove-scopes delete_repo
    return 0
  fi

  output="$(gh auth status --hostname github.com 2>&1 || true)"
  if ! printf '%s\n' "$output" | grep -Eq '(^|[^[:alnum:]_])delete_repo([^[:alnum:]_]|$)'; then
    return 0
  fi

  log "Removing delete_repo from GitHub CLI token scopes"
  if ! gh auth refresh --hostname github.com --remove-scopes delete_repo; then
    log "Warning: could not remove delete_repo from GitHub CLI token scopes"
  fi
}

ensure_github_auth() {
  if [ "$DRY_RUN" -eq 1 ]; then
    if command -v gh >/dev/null 2>&1 && gh auth status --hostname github.com >/dev/null 2>&1; then
      log "GitHub CLI is authenticated"
      run gh auth setup-git --hostname github.com
      remove_delete_repo_scope
      return 0
    fi

    log "Would authenticate GitHub CLI with SSH git protocol"
    run gh auth login --hostname github.com --git-protocol ssh --scopes write:public_key
    run gh auth setup-git --hostname github.com
    remove_delete_repo_scope
    return 0
  fi

  if ! command -v gh >/dev/null 2>&1; then
    die "gh is required before GitHub authentication"
  fi

  if gh auth status --hostname github.com >/dev/null 2>&1; then
    log "GitHub CLI is authenticated"
    run gh auth setup-git --hostname github.com
    remove_delete_repo_scope
    return 0
  fi

  log "Authenticating GitHub CLI with SSH git protocol"
  run gh auth login --hostname github.com --git-protocol ssh --scopes write:public_key
  run gh auth setup-git --hostname github.com
  remove_delete_repo_scope
}

github_ssh_auth_ok() {
  local output

  set +e
  output="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -T git@github.com 2>&1)"
  set -e

  printf '%s\n' "$output" | grep -qi 'successfully authenticated'
}

ensure_ssh_config_uses_key() {
  local private="$1"
  local config="$HOME/.ssh/config"

  if [ "$DRY_RUN" -eq 1 ]; then
    log_err "Would configure SSH to use $private for github.com"
    return 0
  fi

  touch "$config"
  chmod 600 "$config"

  if grep -Fq "IdentityFile $private" "$config"; then
    return 0
  fi

  {
    printf '\n# Managed by Alep bootstrap.\n'
    printf 'Host github.com\n'
    printf '  AddKeysToAgent yes\n'
    printf '  IdentityFile %s\n' "$private"
  } >>"$config"
}

ensure_alep_ssh_key() {
  local private public comment host

  if [ "$DRY_RUN" -eq 1 ]; then
    log_err "Would ensure a dedicated Alep SSH authentication key exists"
    printf '%s\n' "$HOME/.ssh/id_ed25519_alep.pub"
    return 0
  fi

  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  private="$HOME/.ssh/id_ed25519_alep"
  public="$private.pub"
  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'mac')"
  comment="alep-$(id -un)@$host"

  if [ -f "$private" ] && [ ! -f "$public" ]; then
    log_err "Reconstructing missing public key $public"
    ssh-keygen -y -f "$private" >"$public"
  elif [ ! -f "$private" ]; then
    log_err "Generating SSH key $private"
    ssh-keygen -t ed25519 -C "$comment" -f "$private" -N ""
  fi

  chmod 600 "$private"
  [ ! -f "$public" ] || chmod 644 "$public"
  ensure_ssh_config_uses_key "$private"
  printf '%s\n' "$public"
}

upload_github_ssh_key() {
  local public title host

  public="$1"
  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'mac')"
  title="alep-$host-$(date +%Y%m%d%H%M%S)"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would upload SSH public key to GitHub"
    run gh auth refresh --hostname github.com --scopes write:public_key --remove-scopes delete_repo
    run gh ssh-key add "$public" --title "$title"
    return 0
  fi

  log "Uploading SSH public key to GitHub"
  if gh ssh-key add "$public" --title "$title"; then
    return 0
  fi

  log "Refreshing GitHub CLI SSH-key upload scope"
  if gh auth refresh --hostname github.com --scopes write:public_key --remove-scopes delete_repo &&
    gh ssh-key add "$public" --title "$title"; then
    return 0
  fi

  log "Warning: could not upload SSH key; checking whether GitHub SSH auth works anyway"
}

ensure_github_ssh_auth() {
  local public

  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would verify GitHub SSH authentication"
    run ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -T git@github.com
    public="$(ensure_alep_ssh_key)"
    upload_github_ssh_key "$public"
    return 0
  fi

  if github_ssh_auth_ok; then
    log "GitHub SSH authentication is working"
    return 0
  fi

  public="$(ensure_alep_ssh_key)"
  upload_github_ssh_key "$public"

  if github_ssh_auth_ok; then
    log "GitHub SSH authentication is working"
    return 0
  fi

  die "GitHub SSH authentication failed. Add $public to GitHub SSH keys or grant this account access to $CONFIG_REPO, then rerun Alep."
}

clone_source_repo() {
  local target backup

  target="${ALEP_CHEZMOI_SOURCE:-$HOME/.local/share/chezmoi}"

  if [ -d "$target/.git" ] && ! git -C "$target" rev-parse --verify HEAD >/dev/null 2>&1; then
    backup="$target.alep-incomplete-$(date +%Y%m%d%H%M%S)"
    log "Moving incomplete source clone to $backup"
    run mv "$target" "$backup"
    log "Cloning $CONFIG_REPO to $target"
    run mkdir -p "$(dirname -- "$target")"
    run gh repo clone "$CONFIG_REPO" "$target"
    SOURCE_DIR="$target"
    return 0
  fi

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

  if [ -d "$target" ] && [ -z "$(ls -A "$target")" ]; then
    log "Reusing empty source target at $target"
  elif [ -e "$target" ]; then
    die "source target exists but is not a git repo: $target"
  fi

  log "Cloning $CONFIG_REPO to $target"
  run mkdir -p "$(dirname -- "$target")"
  run gh repo clone "$CONFIG_REPO" "$target"
  SOURCE_DIR="$target"
}

write_chezmoi_config() {
  local config_dir config_file backup escaped_source escaped_profile tmp_file

  config_dir="$HOME/.config/chezmoi"
  config_file="$config_dir/chezmoi.toml"
  escaped_source="$(toml_escape "$SOURCE_DIR")"
  escaped_profile="$(toml_escape "$PROFILE")"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would write $config_file for profile $PROFILE and source $SOURCE_DIR"
    return 0
  fi

  log "Writing chezmoi config for profile $PROFILE"
  mkdir -p "$config_dir"

  if [ -f "$config_file" ] && ! grep -q 'Managed by Alep bootstrap' "$config_file"; then
    backup="$config_file.alep-backup-$(date +%Y%m%d%H%M%S)"
    if ! cp "$config_file" "$backup"; then
      die "failed to back up existing chezmoi config: $config_file"
    fi
    log "Backed up existing chezmoi config to $backup"
  fi

  tmp_file="$(mktemp "$config_dir/chezmoi.toml.XXXXXX")"
  {
    printf '# Managed by Alep bootstrap. Edit the Alep repo data files, then rerun bootstrap.\n'
    printf 'sourceDir = "%s"\n\n' "$escaped_source"
    printf '[data]\n'
    printf 'profile = "%s"\n' "$escaped_profile"
  } >"$tmp_file"
  mv "$tmp_file" "$config_file"
  log "Chezmoi config written to $config_file"
}

apply_chezmoi() {
  log "Applying Alep profile $PROFILE from $SOURCE_DIR"
  run chezmoi --source "$SOURCE_DIR" apply
  log "Chezmoi apply complete"
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
    if [ "$DRY_RUN" -eq 1 ]; then
      log "Would run pre-install checklist after source is available: $checklist"
      PRE_CHECKLIST_RAN=1
      return 0
    fi

    log "Pre-install checklist not found at $checklist"
    PRE_CHECKLIST_RAN=1
    return 0
  fi

  args=(--profile "$PROFILE")
  if [ "$DRY_RUN" -eq 1 ]; then
    args+=(--print-only)
  fi

  log "Running pre-install checklist"
  if ! run "$checklist" "${args[@]}"; then
    die "pre-install checklist failed"
  fi
  log "Pre-install checklist complete; continuing"
  PRE_CHECKLIST_RAN=1
}

run_public_preflight_checklist() {
  local items total index item reply completed skipped

  if [ "$PUBLIC_PREFLIGHT_RAN" -eq 1 ] || [ -n "$SOURCE_DIR" ]; then
    return 0
  fi

  if [ "$SKIP_PRE_CHECKLIST" = "1" ]; then
    log "Skipping public preflight checklist"
    PUBLIC_PREFLIGHT_RAN=1
    return 0
  fi

  items=(
    "Confirm this Mac is on trusted power and network."
    "Confirm this macOS user is an administrator and can run: sudo -v."
    "Keep GitHub credentials and 2FA ready for gh auth login."
    "Confirm the GitHub account has access to $CONFIG_REPO and is not an owner/admin if deletion protection matters."
    "Allow Alep to create or upload a GitHub SSH authentication key for this Mac."
  )

  printf '\nAlep Public Bootstrap Preflight (%s)\n' "$PROFILE"
  printf '%s\n' '-------------------------------------'
  index=1
  for item in "${items[@]}"; do
    printf '%2d. %s\n' "$index" "$item"
    index=$((index + 1))
  done

  if [ "$DRY_RUN" -eq 1 ] || [ "$NON_INTERACTIVE" = "1" ] || [ ! -r /dev/tty ]; then
    PUBLIC_PREFLIGHT_RAN=1
    return 0
  fi

  total="${#items[@]}"
  index=1
  completed=0
  skipped=0

  printf '\nPress Enter to mark an item done, type s to skip, or q to quit.\n'
  for item in "${items[@]}"; do
    printf '\n[%d/%d] %s\n' "$index" "$total" "$item"
    while true; do
      printf 'Done? [Enter/s/q] '
      if ! IFS= read -r reply < /dev/tty; then
        die "lost access to /dev/tty while running public preflight checklist"
      fi
      case "$reply" in
        "")
          completed=$((completed + 1))
          break
          ;;
        s | S)
          skipped=$((skipped + 1))
          break
          ;;
        q | Q)
          die "public preflight checklist stopped before provisioning"
          ;;
        *)
          printf 'Use Enter, s, or q.\n'
          ;;
      esac
    done

    index=$((index + 1))
  done

  printf '\nPublic preflight complete. Completed: %d. Skipped: %d.\n' "$completed" "$skipped"
  log "Public preflight complete; continuing"
  PUBLIC_PREFLIGHT_RAN=1
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
  if ! run "$checklist" --profile "$PROFILE"; then
    die "post-install checklist failed"
  fi
  log "Post-install checklist complete"
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

if [ -z "$SOURCE_DIR" ] && [ -z "$CONFIG_REPO" ]; then
  die "provide --source PATH or --config-repo OWNER/REPO"
fi

if [ -n "$SOURCE_DIR" ]; then
  run_pre_install_checklist
else
  run_public_preflight_checklist
fi

ensure_homebrew
ensure_bootstrap_tools

if [ -z "$SOURCE_DIR" ]; then
  ensure_github_auth
  ensure_github_ssh_auth
  clone_source_repo
  run_pre_install_checklist
fi

write_chezmoi_config
apply_chezmoi
run_post_install_checklist

log "Alep provisioning complete"
