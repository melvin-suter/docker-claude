#!/usr/bin/env bash
set -euo pipefail

echo "[claude-entrypoint] Starting Claude Code container..."

HOME_DIR="/home/developer"

# --- Home directory setup ---
# /home/developer is usually a (persistent) volume, so nothing in it is baked into
# the image. Create the per-user state only if it does not exist yet.

# Create a directory if missing, and take ownership if it exists but is not
# writable (e.g. a root-owned volume mounted at that path).
ensure_dir() {
  local dir="$1"
  if [[ ! -d "${dir}" ]]; then
    mkdir -p "${dir}" 2>/dev/null || sudo mkdir -p "${dir}"
  fi
  if [[ ! -w "${dir}" ]]; then
    echo "[claude-entrypoint] ${dir} is not writable; fixing ownership..."
    sudo chown "$(id -u):$(id -g)" "${dir}" \
      || echo "[claude-entrypoint] WARNING: could not take ownership of ${dir} (read-only mount?)"
  fi
}

ensure_dir "${HOME_DIR}"
if [[ ! -f "${HOME_DIR}/.bashrc" ]]; then
  cp -rn /etc/skel/. "${HOME_DIR}/"
fi
ensure_dir "${HOME_DIR}/.claude"
[[ -d "${HOME_DIR}/.ssh" ]] || NEW_SSH_DIR=1
ensure_dir "${HOME_DIR}/.ssh"
[[ -z "${NEW_SSH_DIR:-}" ]] || chmod 700 "${HOME_DIR}/.ssh"

# --- Workspace path ---
WORKSPACE="${HOME_DIR}/workspace"
ensure_dir "${WORKSPACE}"

# --- SSH deploy key setup ---
# Host keys of any SSH host are auto-accepted (see /etc/ssh/ssh_config.d/), so
# cloning from servers other than github.com works without a prompt.
# Keys may be owned by root (volume created by root, or a mounted k8s Secret), which
# makes them unreadable for ssh ("Load key ...: Permission denied"). Take ownership
# and set 0600 when needed; if the file cannot be changed (read-only mount), copy it
# to a private runtime dir and register that copy as an IdentityFile.
RUNTIME_SSH_DIR="/tmp/ssh-keys"
RUNTIME_SSH_CONF="/etc/ssh/ssh_config.d/20-runtime-keys.conf"
SSH_KEYS=()
for key in "${HOME_DIR}"/.ssh/id_{ed25519,ecdsa,rsa}; do
  if [[ -f "${key}" ]] || sudo test -f "${key}"; then
    SSH_KEYS+=("${key}")
  fi
done
if [[ ${#SSH_KEYS[@]} -gt 0 ]]; then
  echo "[claude-entrypoint] Using existing SSH key(s): ${SSH_KEYS[*]}"
  IDENTITY_FILES=()
  NEEDS_COPY=""
  for key in "${SSH_KEYS[@]}"; do
    if [[ -O "${key}" ]] && [[ "$(stat -c %a "${key}")" =~ ^[46]00$ ]]; then
      IDENTITY_FILES+=("${key}")
    elif sudo chown "$(id -u):$(id -g)" "${key}" 2>/dev/null && chmod 600 "${key}" 2>/dev/null; then
      echo "[claude-entrypoint] Fixed ownership/permissions of ${key}"
      IDENTITY_FILES+=("${key}")
    else
      mkdir -p "${RUNTIME_SSH_DIR}"
      chmod 700 "${RUNTIME_SSH_DIR}"
      copy="${RUNTIME_SSH_DIR}/$(basename "${key}")"
      sudo cat "${key}" > "${copy}"
      chmod 600 "${copy}"
      echo "[claude-entrypoint] ${key} is read-only; using a private copy at ${copy}"
      IDENTITY_FILES+=("${copy}")
      NEEDS_COPY=1
    fi
  done
  # Copies are not in a default location, so tell ssh about all keys explicitly
  if [[ -n "${NEEDS_COPY}" ]]; then
    { echo "Host *"; printf '    IdentityFile %s\n' "${IDENTITY_FILES[@]}"; } \
      | sudo tee "${RUNTIME_SSH_CONF}" > /dev/null
  fi
elif [[ -n "${DEPLOY_KEY_B64:-}" ]]; then
  echo "[claude-entrypoint] Configuring SSH deploy key..."
  echo "${DEPLOY_KEY_B64}" | base64 -d > "${HOME_DIR}/.ssh/id_ed25519"
  chmod 600 "${HOME_DIR}/.ssh/id_ed25519"
  echo "[claude-entrypoint] SSH deploy key configured."
else
  echo "[claude-entrypoint] No SSH key found in ${HOME_DIR}/.ssh and no DEPLOY_KEY_B64; skipping SSH setup."
fi

# --- Bitwarden / Vaultwarden server ---
# Only configured on first start; the CLI keeps it in ~/.config/Bitwarden CLI/.
BW_DATA="${HOME_DIR}/.config/Bitwarden CLI/data.json"
if [[ -n "${BW_SERVER:-}" ]] && [[ ! -f "${BW_DATA}" ]]; then
  bw config server "${BW_SERVER}" > /dev/null
  echo "[claude-entrypoint] Bitwarden CLI server set to '${BW_SERVER}'"
fi

# --- Git user config ---
if [[ -n "${GIT_USER_NAME:-}" ]]; then
  git config --global user.name "${GIT_USER_NAME}"
  echo "[claude-entrypoint] Git user.name set to '${GIT_USER_NAME}'"
fi
if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
  git config --global user.email "${GIT_USER_EMAIL}"
  echo "[claude-entrypoint] Git user.email set to '${GIT_USER_EMAIL}'"
fi

# --- Auto-clone repository ---
if [[ -n "${GIT_REPO:-}" ]]; then
  BRANCH="${GIT_BRANCH:-}"
  if [[ -z "$(ls -A "${WORKSPACE}" 2>/dev/null)" ]]; then
    echo "[claude-entrypoint] Cloning ${GIT_REPO}..."
    CLONE_ARGS=("--single-branch")
    if [[ -n "${BRANCH}" ]]; then
      CLONE_ARGS+=("--branch" "${BRANCH}")
    fi
    git clone "${CLONE_ARGS[@]}" "${GIT_REPO}" "${WORKSPACE}"
    echo "[claude-entrypoint] Repository cloned."
  else
    echo "[claude-entrypoint] ${WORKSPACE} is not empty; skipping clone."
  fi
fi

# --- One-time init command ---
INIT_MARKER="${HOME_DIR}/.claude/.init_done"
if [[ -n "${INIT_COMMAND:-}" ]]; then
  if [[ ! -f "${INIT_MARKER}" ]]; then
    echo "[claude-entrypoint] Running INIT_COMMAND..."
    bash -lc "${INIT_COMMAND}"
    touch "${INIT_MARKER}"
    echo "[claude-entrypoint] INIT_COMMAND complete."
  else
    echo "[claude-entrypoint] INIT_COMMAND already completed; skipping."
  fi
fi

echo "[claude-entrypoint] Claude Code version: $(claude --version)"

# --- Seed Claude config with onboarding + workspace trust if missing (prevents "Workspace not trusted" error in remote-control mode) ---
CLAUDE_JSON="${HOME_DIR}/.claude.json"
if [[ ! -f "${CLAUDE_JSON}" ]]; then
  jq -n --arg ws "${WORKSPACE}" '{hasCompletedOnboarding: true, remoteDialogSeen: true, projects: {($ws): {hasTrustDialogAccepted: true}}}' > "${CLAUDE_JSON}"
  echo "[claude-entrypoint] Created ${CLAUDE_JSON} with workspace trust for ${WORKSPACE}."
else
  echo "[claude-entrypoint] ${CLAUDE_JSON} already exists; leaving it untouched."
fi

# --- Authentication check ---
CRED_FILE="${HOME_DIR}/.claude/.credentials.json"

if [[ -f "${CRED_FILE}" ]] && [[ -s "${CRED_FILE}" ]]; then
  echo "[claude-entrypoint] Existing credentials found; skipping login."
else
  echo ""
  echo "=============================================="
  echo "  FIRST LAUNCH — Interactive login required"
  echo "=============================================="
  echo ""
  echo "  Claude Code remote-control requires an OAuth login."
  echo "  Please complete the login flow below."
  echo ""
  echo "  After login succeeds, press Ctrl+C to continue"
  echo "  and launch remote-control mode."
  echo ""
  echo "=============================================="
  echo ""

  # Run login interactively; user completes OAuth in browser
  claude login || true

  if [[ -f "${CRED_FILE}" ]] && [[ -s "${CRED_FILE}" ]]; then
    echo "[claude-entrypoint] Login successful. Credentials saved."
  else
    echo "[claude-entrypoint] WARNING: Login may not have completed. Attempting to launch anyway..."
  fi
fi

# --- Build launch command ---
LAUNCH_ARGS=("claude" "remote-control")

# Permission mode (default: acceptEdits)
MODE="${CLAUDE_PERMISSION_MODE:-acceptEdits}"
LAUNCH_ARGS+=("--permission-mode" "${MODE}")

# Session name (visible in claude.ai/code)
if [[ -n "${CLAUDE_SESSION_NAME:-}" ]]; then
  LAUNCH_ARGS+=("--name" "${CLAUDE_SESSION_NAME}")
fi

# Append any extra user-provided flags
if [[ -n "${CLAUDE_EXTRA_ARGS:-}" ]]; then
  # Word-split CLAUDE_EXTRA_ARGS intentionally
  read -ra EXTRA <<< "${CLAUDE_EXTRA_ARGS}"
  LAUNCH_ARGS+=("${EXTRA[@]}")
fi

# Claude works in the current directory, so start it in the workspace
cd "${WORKSPACE}"

echo "[claude-entrypoint] Launching: ${LAUNCH_ARGS[*]}"

# Remote Control requires a TTY; docker-compose sets tty: true and stdin_open: true
exec "${LAUNCH_ARGS[@]}"
