# init_pool_layout.sh

Generates a directory tree compliant with the **`pool_layout_v1`** specification —
a shared, format-first filesystem layout for LLM artifacts on hosts that may run
multiple inference engines. The whole layout is built under one base directory.

---

# Part 1 — Quick reference ("remember everything in 30 seconds")

## What it builds

Given `--path /opt/revolver/llm-pool`, the base directory itself is the
**pool-root**, and the three roots are created inside it:

```
/opt/revolver/llm-pool/          ← pool-root / trust boundary
├── artifacts/                   canonical, immutable, format-first  (read-only to runtimes)
│   ├── gguf/
│   ├── safetensors/
│   ├── awq/  gptq/  mlx/  onnx/
│   └── <format>/<publisher>/<model>/<file>
├── cache/                       writable, disposable runtime data
└── staging/                     writable import workspace
    └── jobs/
```

Canonical artifact path: `<path>/artifacts/<format>/<publisher>/<model>/<file>`

## Parameters

| Parameter | Required | Meaning |
|-----------|----------|---------|
| `--path </path/to/dir>` | yes | Base directory. The script builds `artifacts/`, `cache/`, and `staging/` inside it; the directory itself becomes pool-root. |
| `--owner <GID \| groupname>` | no | Group that owns the created directories. Enables the shared-library permission model (setgid, group-writable). The group must already exist. |
| `-h`, `--help` | no | Show usage. |

## Run it

```bash
# minimal: just build the tree (single owner, no group sharing)
bash init_pool_layout.sh --path /opt/revolver/llm-pool

# shared library owned by group "revolver" (run as root to apply chown)
bash init_pool_layout.sh --path /opt/revolver/llm-pool --owner revolver

# the group may also be given by GID
bash init_pool_layout.sh --path /opt/revolver/llm-pool --owner 2000
```

No environment variables, no `sudo VAR=...` tricks — paths and ownership are
passed directly as arguments, so copy-paste works the same under root, under
`sudo`, or as a normal user.

## Permission models

| Mode | pool-root / artifacts | cache / staging |
|------|-----------------------|-----------------|
| no `--owner` | `0755` (world-readable, owner-writable) | `0700` (owner-only) |
| `--owner GROUP` | `root:GROUP` `2775` | `:GROUP` `2770` |

The leading `2` is **setgid**: new files and subdirectories inherit the group,
so every member of `GROUP` can publish into the shared library and the group
stays consistent.

If `--owner` is given but the script is **not** running as root, the directory
**modes** are still set, but the `chown` is skipped — the script prints the exact
`chown` commands to run as root.

## ⚠️ One thing not to forget

With `--owner` (group-writable artifacts), filesystem permissions **do not**
enforce artifact immutability. Immutability now depends entirely on the import
workflow — stage first, publish with an atomic `rename()`, never rewrite a
published file. If you want hard enforcement, apply `chattr +i` to published
files after publication.

## Filesystem tip

`artifacts` and `staging` live under the same `--path`, so they are on the same
filesystem by construction: publication is a fast atomic `rename()` and imports
can hardlink instead of copying. A dedicated mount (e.g.
`mount /dev/nvme1n1 /opt/revolver` with `--path /opt/revolver/llm-pool`) gives
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

Everything rests on separating four concerns that are easy to conflate. In this
version they all descend from the single `--path` base:

- **pool-root** (`<path>`) — the administrative root and the **trust boundary**
  for path resolution. It groups the roots of one pool instance. It does *not*
  hold model payloads directly.
- **artifacts-root** (`<path>/artifacts`) — the *only* canonical, durable home
  for published model payloads. Treated as **immutable** and mounted read-only
  into runtimes.
- **cache-root** (`<path>/cache`) — writable, disposable runtime state (prompt
  caches, compiled kernels, indices, download caches). A runtime must survive
  cache loss, modulo regeneration cost.
- **staging-root** (`<path>/staging`) — the writable workspace where downloads,
  conversions, and validation happen *before* publication. A failed import stays
  here and never contaminates the published tree.

## Format-first, not runtime-first

The top-level taxonomy under `artifacts` is the **artifact format**
(`gguf/`, `safetensors/`, `awq/`, `gptq/`, `mlx/`, `onnx/`), never a runtime
name. Format is more stable than runtime attachment: one model can serve several
runtimes, and one runtime supports several formats across releases. Format-first
keeps identity stable and lets new runtimes reuse existing artifact families
instead of forcing a storage migration.

## The path shape

```
<path>/artifacts/<format>/<publisher>/<model>/<file>
```

This mirrors how model ecosystems already think — `publisher/model` is the
natural identity boundary (the same mental model as Hugging Face or LM Studio).
All files for one upstream identity live in one model directory, so multiple
GGUF quantizations or a safetensors model plus its tokenizer/config sidecars
sit together without inventing synthetic runtime folders.

## Why publication is a ritual, not a copy

Imports are messy: downloads fail halfway, conversions produce garbage,
validation rejects candidates. So nothing is written directly into `artifacts`.
Instead:

1. Land incoming files in a job directory under `staging/jobs/<job-id>/`.
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

- **Symlinks** must resolve *inside* the pool boundary — never into `cache`,
  `staging`, or unrelated host paths. Relative, file-level symlinks are
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
