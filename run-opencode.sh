#!/usr/bin/env bash
# run-opencode.sh — launch opencode in Docker, mounting ONLY the target project dir.
# The project is mounted at the SAME absolute path inside the container as on the
# host (not remapped to /workspace) so that `-c`/--continue can match sessions by
# project path. Uses the official image (opencode binary baked in).
#
# Usage:
#   ./run-opencode.sh                 # interactive project picker
#   ./run-opencode.sh <project-name>  # non-interactive, must be in ALLOWED_PROJECTS
#
# Session selection, in priority order:
#   1. OPENCODE_SESSION env var, if set        -> resume that exact session
#   2. an entry for the chosen project in the session map file (see below)
#   3. OPENCODE_CONTINUE=1                      -> continue the most recent session
#   4. OPENCODE_CONTINUE=0                      -> start a new session
#   5. otherwise: interactive prompt (continue last vs. start new)
#
# Per-project session map:
#   Kept OUT of this script (which may be public/open-sourced) in a small shell
#   file that fills a PROJECT_SESSIONS[<project-name>]=<session-id> assoc array,
#   e.g.:
#       PROJECT_SESSIONS[PeopleModeler]="ses_0e6821896ffehruuYg2pBf9G0v"
#       PROJECT_SESSIONS[TripMind]="ses_048f17cf2ffe9dEhXF0lEcpL90"
#   By default this file is expected at sessions.env next to this script.
#   Override its location with OPENCODE_SESSION_MAP_FILE. Add it to .gitignore.

set -euo pipefail

IMAGE_NAME="ghcr.io/falltrades/opencode-config/rust:1.0.0"
BASE_DIR="${HOME}/git/StellaSecret"

# Keep this list in sync with AGENTS.md's allowed project list.
ALLOWED_PROJECTS=(CVGenerator TripMind GameTracker AsthmeTrack PeopleModeler SmartShoppingCalculator StellaSecret.github.io)

# --- resolve the directory this script lives in, regardless of cwd or alias ---
SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"

# --- per-project session mapping, kept OUT of this (public) script.
#     Provide a shell file that fills PROJECT_SESSIONS[<project-name>]=<session-id>.
#     Defaults to sessions.env next to this script; overridable via
#     OPENCODE_SESSION_MAP_FILE. Not committed. ---
declare -A PROJECT_SESSIONS
SESSION_MAP_FILE="${OPENCODE_SESSION_MAP_FILE:-${SCRIPT_DIR}/sessions.env}"
if [[ -f "$SESSION_MAP_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SESSION_MAP_FILE"
fi

# --- opencode's own config/data/state/cache (your REAL host dirs, so you don't
#     have to re-authenticate inside the container). Mounted read-write since
#     opencode updates model choice, session state, and cache in here.
#     Created here (as YOUR user) so Docker never auto-creates them as root. ---
CONFIG_DIR="${HOME}/.config/opencode"
DATA_DIR="${HOME}/.local/share/opencode"
STATE_DIR="${HOME}/.local/state/opencode"
CACHE_DIR="${HOME}/.cache/opencode"

# --- cargo/rustup state: real host dirs, read-write. Needed for actual
#     `cargo build`/`cargo install` work you do inside a project (registry
#     cache, build artifacts) — NOT for the `rustup` binary itself, which
#     now lives at /usr/local/bin inside the image (see Dockerfile).
#     Created here as YOUR user so Docker never auto-creates them as root,
#     and so the bind-mounted contents are writable by the UID the
#     container runs as (--user "$(id -u):$(id -g)" below). ---
CARGO_HOME_DIR="${HOME}/.cargo"
RUSTUP_HOME_DIR="${HOME}/.rustup"

# --- git identity/creds, read-only (container shouldn't rewrite your git config) ---
GIT_CONFIG_FILE="${HOME}/.gitconfig"

# Global instructions file, mounted read-only so the container can't alter it.
GLOBAL_AGENTS_MD="${HOME}/.config/opencode/AGENTS.md"

# --- pick a project: arg if given, else interactive menu ---
if [[ $# -eq 0 ]]; then
    echo "Select a project:" >&2
    select choice in "${ALLOWED_PROJECTS[@]}"; do
        if [[ -n "${choice:-}" ]]; then
            PROJECT_NAME="$choice"
            break
        fi
        echo "Invalid choice, try again." >&2
    done
elif [[ $# -eq 1 ]]; then
    PROJECT_NAME="$1"
else
    echo "Usage: $0 [project-name]" >&2
    echo "Allowed: ${ALLOWED_PROJECTS[*]}" >&2
    exit 1
fi

is_allowed=false
for p in "${ALLOWED_PROJECTS[@]}"; do
    if [[ "$PROJECT_NAME" == "$p" ]]; then
        is_allowed=true
        break
    fi
done

if [[ "$is_allowed" != true ]]; then
    echo "Refusing: '$PROJECT_NAME' is not in the allowed project list." >&2
    echo "Allowed: ${ALLOWED_PROJECTS[*]}" >&2
    exit 1
fi

# --- auto-select the session for this project unless the caller already
#     pinned one via the OPENCODE_SESSION env var (explicit override wins) ---
if [[ -z "${OPENCODE_SESSION:-}" && -n "${PROJECT_SESSIONS[$PROJECT_NAME]:-}" ]]; then
    OPENCODE_SESSION="${PROJECT_SESSIONS[$PROJECT_NAME]}"
    echo "Using mapped session for '$PROJECT_NAME': $OPENCODE_SESSION" >&2
fi

PROJECT_PATH="${BASE_DIR}/${PROJECT_NAME}"

# Resolve to an absolute, symlink-free path and re-check it's really inside BASE_DIR.
REAL_BASE="$(realpath "$BASE_DIR")"
REAL_PROJECT="$(realpath "$PROJECT_PATH" 2>/dev/null || true)"

if [[ -z "$REAL_PROJECT" ]]; then
    echo "Refusing: '$PROJECT_PATH' does not exist." >&2
    exit 1
fi

case "$REAL_PROJECT" in
    "$REAL_BASE"/*) ;;
    *)
        echo "Refusing: resolved path '$REAL_PROJECT' escapes '$REAL_BASE'." >&2
        exit 1
        ;;
esac

# --- session handling: explicit id/flag via env skips the prompt; otherwise ask ---
SESSION_ARGS=()
if [[ -n "${OPENCODE_SESSION:-}" ]]; then
    SESSION_ARGS=(-s "$OPENCODE_SESSION")
elif [[ -n "${OPENCODE_CONTINUE:-}" ]]; then
    if [[ "$OPENCODE_CONTINUE" == "1" ]]; then
        SESSION_ARGS=(-c)
    fi
else
    echo "Session for '$PROJECT_NAME':" >&2
    select session_choice in "Continue last session" "Start new session"; do
        case "$session_choice" in
            "Continue last session") SESSION_ARGS=(-c); break ;;
            "Start new session") SESSION_ARGS=(); break ;;
            *) echo "Invalid choice, try again." >&2 ;;
        esac
    done
fi

# --- assemble mounts ---
DOCKER_ARGS=(
    --rm -it
    --network bridge
    --cap-drop=ALL
    --security-opt no-new-privileges
    --user "$(id -u):$(id -g)"
    -e "HOME=/home/opencode"
    -w "$REAL_PROJECT"
    -v "${REAL_PROJECT}:${REAL_PROJECT}"
    -v "${CONFIG_DIR}:/home/opencode/.config/opencode"
    -v "${DATA_DIR}:/home/opencode/.local/share/opencode"
    -v "${STATE_DIR}:/home/opencode/.local/state/opencode"
    -v "${CACHE_DIR}:/home/opencode/.cache/opencode"
    -v "${CARGO_HOME_DIR}:/home/opencode/.cargo"
    -v "${RUSTUP_HOME_DIR}:/home/opencode/.rustup"
    -v "/etc/passwd:/etc/passwd:ro"
    -v "/etc/group:/etc/group:ro"
    -e "CARGO_HOME=/home/opencode/.cargo"
    -e "RUSTUP_HOME=/home/opencode/.rustup"
    -e "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/opencode/.cargo/bin"
    -e "OPENCODE_API_KEY=${OPENCODE_API_KEY:-}"
)

if [[ -f "$GIT_CONFIG_FILE" ]]; then
    DOCKER_ARGS+=(-v "${GIT_CONFIG_FILE}:/home/opencode/.gitconfig:ro")
else
    echo "Note: no ~/.gitconfig found — skipping that mount." >&2
fi

if [[ -f "$GLOBAL_AGENTS_MD" ]]; then
    DOCKER_ARGS+=(-v "${GLOBAL_AGENTS_MD}:/home/opencode/.config/opencode/AGENTS.md:ro")
else
    echo "Note: no global AGENTS.md found at ${GLOBAL_AGENTS_MD} — skipping that mount." >&2
fi

docker run "${DOCKER_ARGS[@]}" "$IMAGE_NAME" "${SESSION_ARGS[@]}"
