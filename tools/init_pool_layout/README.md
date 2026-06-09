# init_pool_layout.sh

Generates a directory tree compliant with the **`pool_layout_v1`** specification — a
shared, format-first filesystem layout for LLM artifacts on hosts that may run
multiple inference engines.

---

# Part 1 — Quick reference ("remember everything in 30 seconds")

## What it builds

```
<pool-root>/
├── artifacts/        canonical, immutable, format-first   (read-only to runtimes)
│   ├── gguf/
│   ├── safetensors/
│   ├── awq/  gptq/  mlx/  onnx/
│   └── <format>/<publisher>/<model>/<file>
├── cache/            writable, disposable runtime data
└── staging/          writable import workspace
    └── jobs/<job-id>/
```

Canonical artifact path: `<artifacts-root>/<format>/<publisher>/<model>/<file>`

## Run it

```bash
# rootless defaults under $HOME
./init_pool_layout.sh

# system-managed defaults (/srv, /usr/share, /var/cache, /var/lib)
./init_pool_layout.sh --system

# build into a throwaway sandbox without touching real paths
./init_pool_layout.sh --prefix /tmp/sandbox --example

# explicit paths + shared-library ownership (run as root to apply chown)
sudo POOL_ROOT=/opt/revolver \
  ARTIFACTS_ROOT=/opt/revolver/artifacts \
  CACHE_ROOT=/opt/revolver/cache \
  STAGING_ROOT=/opt/revolver/staging \
  bash init_pool_layout.sh --owner revolver
```

## Flags

| Flag | Effect |
|------|--------|
| `--rootless` | Defaults under `$HOME` (default profile) |
| `--system` | System-managed defaults (`/srv`, `/usr/share`, `/var/cache`, `/var/lib`) |
| `--prefix PATH` | Prepend a sandbox prefix to every root (for testing; skips `chown`) |
| `--example` | Also create the minimal example payloads + `_pool.json` metadata |
| `--owner GROUP` | Apply the shared-library permission model (setgid, group-writable). **Implies `--system` unless a profile is set explicitly.** |
| `--artifacts-user USER` | Owner user for `artifacts`/`pool-root` (default `root`) |
| `--cache-user USER` | Owner user for `cache`/`staging` (default = group name) |
| `-h`, `--help` | Show usage |

### Profile selection

The profile decides the default paths. It resolves in this order:

1. An explicit `--rootless` / `--system` flag always wins.
2. Otherwise, `--owner GROUP` implies `--system` (a shared group library is a
   system-managed scenario, not a per-user one).
3. Otherwise, the default is `rootless`.

In all cases the `*_ROOT` environment variables override the profile's paths,
so if you pass explicit roots the profile only affects the banner, not the
locations.

## Environment overrides (win over the profile)

`POOL_ROOT`, `ARTIFACTS_ROOT`, `CACHE_ROOT`, `STAGING_ROOT`, `PRODUCT`, `SVC`

## Permission models

| Mode | artifacts / pool-root | cache / staging |
|------|----------------------|-----------------|
| default (no `--owner`) | `0755`, owner-writable | `0700`, owner-only |
| `--owner GROUP` | `<artifacts-user>:GROUP` `2775` | `<cache-user>:GROUP` `2770` |

The leading `2` is **setgid**: new files and subdirectories inherit the group,
so every member of `GROUP` can publish into the shared library and the group
stays consistent.

## ⚠️ One thing not to forget

With `--owner` (group-writable artifacts), filesystem permissions **do not**
enforce artifact immutability. Immutability now depends entirely on the import
workflow — stage first, publish with an atomic `rename()`, never rewrite a
published file. If you want hard enforcement, apply `chattr +i` to published
files after publication.

## Filesystem tip

Keep `staging` on the **same filesystem** as `artifacts`. Then publication is a
fast atomic `rename()` and imports can hardlink instead of copying. A dedicated
mount (e.g. `mount /dev/nvme1n1 /opt/revolver` with all roots underneath) gives
you this for free.

---

# Part 2 — The concept behind the layout

The script is just a materializer. The actual contract lives in two companion
documents:

- **`pool_layout_v1_draft.txt`** — the normative specification (the "how").
- **`pool_layout_v1_rationale.md`** — the reasoning (the "why").

This section is a guided on-ramp into that contract so the directory tree stops
looking arbitrary.

## The problem it solves

A single host may run several inference engines, and the same model artifact can
matter to more than one of them. If you organize storage by engine
(`vllm/`, `llama.cpp/`, …), the same payload ends up duplicated or ambiguously
assigned, and a temporary implementation detail (e.g. one engine's experimental
GGUF support) gets baked into a durable filesystem contract. The layout exists
to avoid exactly that.

## The four roots

Everything rests on separating four concerns that are easy to conflate:

- **`pool-root`** — the administrative root and the **trust boundary** for path
  resolution. It groups the roots of one pool instance. It may be a real
  directory or a logical umbrella over several absolute paths. It does *not*
  hold model payloads itself.
- **`artifacts-root`** — the *only* canonical, durable home for published model
  payloads. Treated as **immutable** and mounted read-only into runtimes.
- **`cache-root`** — writable, disposable runtime state (prompt caches, compiled
  kernels, indices, download caches). A runtime must survive cache loss, modulo
  regeneration cost.
- **`staging-root`** — the writable workspace where downloads, conversions, and
  validation happen *before* publication. A failed import stays here and never
  contaminates the published tree.

## Format-first, not runtime-first

The top-level taxonomy under `artifacts-root` is the **artifact format**
(`gguf/`, `safetensors/`, `awq/`, `gptq/`, `mlx/`, `onnx/`), never a runtime
name. Format is more stable than runtime attachment: one model can serve several
runtimes, and one runtime supports several formats across releases. Format-first
keeps identity stable and lets new runtimes reuse existing artifact families
instead of forcing a storage migration.

## The path shape

```
<artifacts-root>/<format>/<publisher>/<model>/<file>
```

This mirrors how model ecosystems already think — `publisher/model` is the
natural identity boundary (the same mental model as Hugging Face or LM Studio).
All files for one upstream identity live in one model directory, so multiple
GGUF quantizations or a safetensors model plus its tokenizer/config sidecars
sit together without inventing synthetic runtime folders.

## Why publication is a ritual, not a copy

Imports are messy: downloads fail halfway, conversions produce garbage,
validation rejects candidates. So nothing is written directly into
`artifacts-root`. Instead:

1. Land incoming files in a job directory under `staging-root/jobs/<job-id>/`.
2. Validate structure, names, sizes, checksums.
3. Derive the canonical destination path.
4. **Publish atomically** (`rename()` on the same filesystem).
5. Write metadata only after success.
6. Clean up staging.

A reader must never observe a half-published model as if it were complete.
Published files are then immutable — no in-place appends, no byte rewrites, no
silent content swaps under the same identity.

## Symlinks and hardlinks, kept on a leash

Both are allowed as optimizations but constrained, because in a shared pool they
are the easiest way to break the trust boundary:

- **Symlinks** must resolve *inside* the pool boundary — never into `cache-root`,
  `staging-root`, or unrelated host paths. Relative, file-level symlinks are
  preferred; directory symlinks for canonical model dirs are discouraged.
- **Hardlinks** are great for same-filesystem dedup, but a hardlinked published
  file shares an inode with its source — safe *only* under strict immutability.
  Hardlinking from cache content is forbidden.

## Import modes are explicit

`copy` (independent file), `hardlink` (shared inode), `symlink` (alias) have
different semantics, so the mode is recorded in metadata rather than hidden.
Default order: **hardlink when safe and same-filesystem, otherwise copy**.
Symlink import is opt-in and off by default for shared pools.

## Why this is worth the discipline

The layout deliberately favors correctness and operator clarity over
convenience. Direct writes into the model tree are forbidden, symlinks are
constrained, and every import passes through staging. In exchange you get a
boring, predictable contract: packagers publish into one known tree, runtime
integrators mount one read-only root plus one writable root, and tooling authors
build scanners and validators against a stable shape instead of a
product-specific convention. Artifact identity stays stable, publication stays
trustworthy, caches stay disposable, and imports stay recoverable.

> For the full normative rules, read `pool_layout_v1_draft.txt`.
> For the reasoning behind each rule, read `pool_layout_v1_rationale.md`.
