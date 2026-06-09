#!/usr/bin/env bash
#
# init_pool_layout.sh
#
# Generates a directory tree compliant with the pool_layout_v1 specification,
# rooted at a single base directory.
#
# Layout produced (pool-root = the --path directory):
#   <path>/                       pool-root / trust boundary
#   <path>/artifacts/             canonical, immutable, format-first payloads
#       gguf/ safetensors/ awq/ gptq/ mlx/ onnx/
#   <path>/cache/                 writable, disposable runtime data
#   <path>/staging/jobs/          writable import workspace
#
# Canonical artifact path shape:
#   <path>/artifacts/<format>/<publisher>/<model>/<file>
#
# Parameters:
#   --path  </path/to/dir>     base directory to build the layout in (required)
#   --owner <GID | groupname>  group that owns the created directories (optional)
#
# Permission model (spec section 11):
#   without --owner:
#       artifacts  0755   (world-readable, owner-writable)
#       cache      0700   (owner-only)
#       staging    0700   (owner-only)
#   with --owner GROUP (shared library):
#       artifacts  root:GROUP   2775   (setgid, group-writable)
#       cache      GROUP            2770   (setgid, group-writable)
#       staging    GROUP            2770   (setgid, group-writable)
#   setgid (leading 2) makes new files/dirs inherit the group, so any member
#   of GROUP can publish and the group stays consistent.
#
# NOTE: with --owner, group-write means filesystem permissions do NOT enforce
# artifact immutability (spec 7.4) — that relies on the import workflow
# (stage first, publish with an atomic rename, never rewrite a published file).
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------
BASE_PATH=""
OWNER_GROUP=""

usage() {
    sed -n '2,38p' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)  BASE_PATH="${2:?--path needs a directory}"; shift ;;
        --owner) OWNER_GROUP="${2:?--owner needs a group (GID or name)}"; shift ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown argument: $1" >&2; usage 1 ;;
    esac
    shift
done

if [[ -z "$BASE_PATH" ]]; then
    echo "Error: --path is required." >&2
    usage 1
fi

# Normalize: strip trailing slash (but keep root "/" intact).
if [[ "$BASE_PATH" != "/" ]]; then
    BASE_PATH="${BASE_PATH%/}"
fi

# ---------------------------------------------------------------------------
# Derive the four roots from the single base path
# ---------------------------------------------------------------------------
POOL_ROOT="$BASE_PATH"
ARTIFACTS_ROOT="${BASE_PATH}/artifacts"
CACHE_ROOT="${BASE_PATH}/cache"
STAGING_ROOT="${BASE_PATH}/staging"

# Artifact-format families (format-first taxonomy; never runtime names).
FORMATS=(gguf safetensors awq gptq mlx onnx)

mkdir_v() { mkdir -p "$1" && echo "  + $1"; }

# ---------------------------------------------------------------------------
# Validate --owner (group must exist) before creating anything
# ---------------------------------------------------------------------------
if [[ -n "$OWNER_GROUP" ]]; then
    if ! getent group "$OWNER_GROUP" >/dev/null 2>&1; then
        echo "Error: group '$OWNER_GROUP' does not exist (checked with getent)." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Build the tree
# ---------------------------------------------------------------------------
echo "pool_layout_v1 — base path: ${POOL_ROOT}"
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
# Permissions (spec section 11)
# ---------------------------------------------------------------------------
if [[ -n "$OWNER_GROUP" ]]; then
    # setgid (leading 2) → new files/dirs inherit the group
    chmod 2775 "$POOL_ROOT"
    chmod -R 2775 "$ARTIFACTS_ROOT"
    chmod 2770 "$CACHE_ROOT"
    chmod 2770 "$STAGING_ROOT"
    chmod 2770 "${STAGING_ROOT}/jobs"

    if [[ "$(id -u)" -eq 0 ]]; then
        # artifacts / pool-root: owned by root, group = OWNER_GROUP
        chown    "root:${OWNER_GROUP}" "$POOL_ROOT"
        chown -R "root:${OWNER_GROUP}" "$ARTIFACTS_ROOT"
        # cache / staging: group-owned working areas (owner left as current root)
        chown -R ":${OWNER_GROUP}" "$CACHE_ROOT"
        chown -R ":${OWNER_GROUP}" "$STAGING_ROOT"
        echo
        echo "Ownership applied (group: ${OWNER_GROUP}):"
        printf '  %-15s %s\n' "artifacts" "root:${OWNER_GROUP} (2775, setgid)"
        printf '  %-15s %s\n' "cache"     ":${OWNER_GROUP} (2770, setgid)"
        printf '  %-15s %s\n' "staging"   ":${OWNER_GROUP} (2770, setgid)"
    else
        echo
        echo "NOTE: not running as root — modes set, but chown skipped."
        echo "      Run as root to assign group ownership:"
        echo "        chown -R root:${OWNER_GROUP} ${POOL_ROOT} ${ARTIFACTS_ROOT}"
        echo "        chown -R :${OWNER_GROUP} ${CACHE_ROOT} ${STAGING_ROOT}"
    fi
else
    chmod 0755 "$ARTIFACTS_ROOT"
    chmod 0700 "$CACHE_ROOT"
    chmod 0700 "$STAGING_ROOT"
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

