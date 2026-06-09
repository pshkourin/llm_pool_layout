#!/usr/bin/env bash
#
# init_pool_layout.sh
#
# Generates a directory tree compliant with the pool_layout_v1 specification.
#
# Layout model:
#   pool-root      administrative root / trust boundary
#   artifacts-root canonical, immutable, format-first published payloads
#                  (mounted read-only into runtimes)
#   cache-root     writable, disposable runtime data
#   staging-root   writable working area for imports before publication
#
# Canonical artifact path shape:
#   <artifacts-root>/<format>/<publisher>/<model>/<file>
#
# Usage:
#   ./init_pool_layout.sh                 # rootless defaults under $HOME
#   ./init_pool_layout.sh --system        # system-managed defaults
#   ./init_pool_layout.sh --prefix /tmp/p # build the tree under a sandbox prefix
#   ./init_pool_layout.sh --example       # also create the minimal example contents
#
# Environment overrides (take precedence over the chosen profile):
#   POOL_ROOT, ARTIFACTS_ROOT, CACHE_ROOT, STAGING_ROOT
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults / argument parsing
# ---------------------------------------------------------------------------
PROFILE="rootless"     # rootless | system
PREFIX=""              # optional sandbox prefix prepended to every root
MAKE_EXAMPLE=0
PRODUCT="${PRODUCT:-myproduct}"
SVC="${SVC:-$(id -un)}"

# Ownership model (set via --owner GROUP). When OWNER_GROUP is non-empty the
# script applies a shared-library permission model:
#   artifacts : <ARTIFACTS_USER>:<group>  mode 2775  (setgid, group-writable)
#   cache     : <group-user>:<group>      mode 2770  (setgid, group-writable)
#   staging   : <group-user>:<group>      mode 2770
#   pool-root : <ARTIFACTS_USER>:<group>  mode 2775
# setgid (the leading 2) makes new files/dirs inherit the group, so any member
# of the group can publish into the shared library and the group stays correct.
# NOTE: with group-write, artifact immutability (spec 7.4) is NOT enforced by
# the filesystem — it relies on the import workflow (staging + atomic rename).
OWNER_GROUP=""                 # e.g. revolver
ARTIFACTS_USER="root"          # owner user for artifacts/pool-root
CACHE_USER=""                  # owner user for cache/staging (defaults to group name)

usage() {
    sed -n '2,30p' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootless) PROFILE="rootless" ;;
        --system)   PROFILE="system" ;;
        --prefix)   PREFIX="${2:?--prefix needs a path}"; shift ;;
        --example)  MAKE_EXAMPLE=1 ;;
        --owner)    OWNER_GROUP="${2:?--owner needs a group name}"; shift ;;
        --artifacts-user) ARTIFACTS_USER="${2:?--artifacts-user needs a user}"; shift ;;
        --cache-user)     CACHE_USER="${2:?--cache-user needs a user}"; shift ;;
        -h|--help)  usage 0 ;;
        *) echo "Unknown argument: $1" >&2; usage 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Resolve the four roots (env override > profile default)
# ---------------------------------------------------------------------------
if [[ "$PROFILE" == "system" ]]; then
    : "${POOL_ROOT:=/srv/llm-pool}"
    : "${ARTIFACTS_ROOT:=/usr/share/llm-pool/artifacts}"
    : "${CACHE_ROOT:=/var/cache/${PRODUCT}/llm-pool}"
    : "${STAGING_ROOT:=/var/lib/${PRODUCT}/llm-pool/staging}"
else
    BASE="$HOME"
    : "${POOL_ROOT:=${BASE}/.local/share/llm-pool}"
    : "${ARTIFACTS_ROOT:=${BASE}/.local/share/llm-pool/artifacts}"
    : "${CACHE_ROOT:=${BASE}/.cache/llm-pool}"
    : "${STAGING_ROOT:=${BASE}/.local/state/llm-pool/staging}"
fi

# Apply an optional sandbox prefix so the script can be tested without touching
# real system paths. Absolute roots are appended verbatim under the prefix.
apply_prefix() {
    local p="$1"
    if [[ -n "$PREFIX" ]]; then
        printf '%s/%s' "${PREFIX%/}" "${p#/}"
    else
        printf '%s' "$p"
    fi
}

POOL_ROOT="$(apply_prefix "$POOL_ROOT")"
ARTIFACTS_ROOT="$(apply_prefix "$ARTIFACTS_ROOT")"
CACHE_ROOT="$(apply_prefix "$CACHE_ROOT")"
STAGING_ROOT="$(apply_prefix "$STAGING_ROOT")"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
mkdir_v() { mkdir -p "$1" && echo "  + $1"; }

# Recognized artifact-format families (format-first top-level taxonomy).
# Runtime names (vllm, llama.cpp, ...) are deliberately NOT used here.
FORMATS=(gguf safetensors awq gptq mlx onnx)

# ---------------------------------------------------------------------------
# Build the tree
# ---------------------------------------------------------------------------
echo "pool_layout_v1 — profile: ${PROFILE}${PREFIX:+ (prefix: $PREFIX)}"
echo

echo "pool-root:"
mkdir_v "$POOL_ROOT"

echo "artifacts-root (canonical, immutable, format-first):"
mkdir_v "$ARTIFACTS_ROOT"
for fmt in "${FORMATS[@]}"; do
    mkdir_v "${ARTIFACTS_ROOT}/${fmt}"
done

echo "cache-root (writable, disposable):"
mkdir_v "$CACHE_ROOT"

echo "staging-root (writable, unpublished jobs):"
mkdir_v "$STAGING_ROOT"
mkdir_v "${STAGING_ROOT}/jobs"

# ---------------------------------------------------------------------------
# Permissions per spec section 11.
# Two modes:
#   (a) no --owner: simple single-owner model
#       artifacts world-readable/owner-writable, cache+staging owner-only.
#   (b) --owner GROUP: shared-library model with setgid so group members can
#       publish, and new files inherit the group.
# ---------------------------------------------------------------------------
if [[ -n "$OWNER_GROUP" ]]; then
    : "${CACHE_USER:=$OWNER_GROUP}"   # default cache/staging user = group name

    # setgid (leading 2) → inherit group on new files/dirs
    chmod 2775 "$POOL_ROOT"
    chmod -R 2775 "$ARTIFACTS_ROOT"
    chmod 2770 "$CACHE_ROOT"
    chmod 2770 "$STAGING_ROOT"
    chmod 2770 "${STAGING_ROOT}/jobs"

    if [[ -z "$PREFIX" && "$(id -u)" -eq 0 ]]; then
        chown    "${ARTIFACTS_USER}:${OWNER_GROUP}" "$POOL_ROOT"
        chown -R "${ARTIFACTS_USER}:${OWNER_GROUP}" "$ARTIFACTS_ROOT"
        chown    "${CACHE_USER}:${OWNER_GROUP}"     "$CACHE_ROOT"
        chown -R "${CACHE_USER}:${OWNER_GROUP}"     "$STAGING_ROOT"
        echo
        echo "Ownership applied:"
        printf '  %-15s %s\n' "artifacts" "${ARTIFACTS_USER}:${OWNER_GROUP} (2775, setgid)"
        printf '  %-15s %s\n' "cache"     "${CACHE_USER}:${OWNER_GROUP} (2770, setgid)"
        printf '  %-15s %s\n' "staging"   "${CACHE_USER}:${OWNER_GROUP} (2770, setgid)"
    else
        echo
        echo "NOTE: chown skipped (need root, and not in --prefix sandbox)."
        echo "      Run the following as root to set ownership:"
        echo "        chown -R ${ARTIFACTS_USER}:${OWNER_GROUP} ${POOL_ROOT} ${ARTIFACTS_ROOT}"
        echo "        chown -R ${CACHE_USER}:${OWNER_GROUP} ${CACHE_ROOT} ${STAGING_ROOT}"
    fi
else
    chmod 0755 "$ARTIFACTS_ROOT"
    chmod 0700 "$CACHE_ROOT"
    chmod 0700 "$STAGING_ROOT"
fi

# ---------------------------------------------------------------------------
# Optional: populate the minimal example from section 13
# ---------------------------------------------------------------------------
if [[ "$MAKE_EXAMPLE" -eq 1 ]]; then
    echo
    echo "Creating minimal example payload directories:"

    gguf_model="${ARTIFACTS_ROOT}/gguf/bartowski/llama-3.1-8b-instruct-gguf"
    st_model="${ARTIFACTS_ROOT}/safetensors/qwen/qwen3-8b-instruct"

    mkdir_v "$gguf_model"
    mkdir_v "$st_model"

    # Placeholder payload files (empty) just to materialize the shape.
    : > "${gguf_model}/Q4_K_M.gguf"
    : > "${gguf_model}/Q8_0.gguf"
    : > "${st_model}/config.json"
    : > "${st_model}/tokenizer.json"
    : > "${st_model}/model-00001-of-00002.safetensors"
    : > "${st_model}/model-00002-of-00002.safetensors"

    # _pool.json metadata (section 5.2 fields)
    cat > "${gguf_model}/_pool.json" <<'JSON'
{
  "layout_version": "pool_layout_v1",
  "format": "gguf",
  "publisher": "bartowski",
  "model": "llama-3.1-8b-instruct-gguf",
  "upstream_id": "bartowski/Llama-3.1-8B-Instruct-GGUF",
  "source": "",
  "files": ["Q4_K_M.gguf", "Q8_0.gguf"],
  "checksums": {}
}
JSON

    cat > "${st_model}/_pool.json" <<'JSON'
{
  "layout_version": "pool_layout_v1",
  "format": "safetensors",
  "publisher": "qwen",
  "model": "qwen3-8b-instruct",
  "upstream_id": "Qwen/Qwen3-8B-Instruct",
  "source": "",
  "files": [
    "config.json",
    "tokenizer.json",
    "model-00001-of-00002.safetensors",
    "model-00002-of-00002.safetensors"
  ],
  "checksums": {}
}
JSON
    echo "  + example _pool.json metadata written"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "Done. Roots:"
printf '  %-15s %s\n' "pool-root"      "$POOL_ROOT"
printf '  %-15s %s\n' "artifacts-root" "$ARTIFACTS_ROOT"
printf '  %-15s %s\n' "cache-root"     "$CACHE_ROOT"
printf '  %-15s %s\n' "staging-root"   "$STAGING_ROOT"

if command -v tree >/dev/null 2>&1; then
    echo
    tree -a "$POOL_ROOT" 2>/dev/null || true
fi
