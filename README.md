# pool_layout_v1

`pool_layout_v1` is a format-first filesystem layout for shared local LLM artifact pools on hosts that may run more than one inference engine.
It defines a stable way to place published model artifacts, writable runtime cache data, and staging workspaces so operators and tooling do not have to rely on product-specific directory conventions.

## What this project is

This repository is centered on the **specification**, not on a single implementation.
The canonical contract lives in `pool_layout_v1_draft.txt`, while the companion rationale explains why the layout is format-first, why published artifacts are treated as immutable, and why cache and staging are separated.

The main goal is simple: make shared local model storage predictable, inspectable, and safe to reuse across runtimes, packagers, and operators.
Instead of organizing files by runtime name, `pool_layout_v1` organizes published artifacts by artifact format and upstream model identity.

## Where to start

If you are new to the project, start here:

1. Read `pool_layout_v1_draft.txt` for the normative rules of the layout.
2. Read `pool_layout_v1_rationale.md` for the design intent and trade-offs behind those rules.
3. Use `tools/init_pool_layout/` if you want a practical Bash tool that materializes the directory tree described by the specification.

A good mental model is that the draft answers **how the layout works**, while the rationale answers **why it was designed this way**.

## Core ideas

The layout separates four concerns that are easy to mix together in ad hoc deployments: an administrative pool boundary, canonical published artifacts, disposable runtime cache data, and a staging area for unfinished imports.
This separation exists so incomplete downloads, runtime debris, and mutable working state never contaminate the canonical published tree.

Published artifacts live under a format-first path shape:

```text
<artifacts-root>/<format>/<publisher>/<model>/<file>
```

This path shape keeps artifact identity above runtime identity, which avoids duplication and ambiguity when the same model format can be used by more than one runtime.
The specification also treats publication as a staged workflow: prepare in `staging`, validate, then publish atomically into the canonical artifact tree.

## Repository layout

```text
/
├── README.md
├── pool_layout_v1_draft.txt
├── pool_layout_v1_rationale.md
├── docs/
│   ├── pool_layout_v1_rationale.docx
│   └── pool_layout_v1_rationale.pdf
└── tools/
    └── init_pool_layout/
        ├── README.md
        └── init_pool_layout.sh
```

| Path | Purpose |
|------|---------|
| `README.md` | Entry point to the project and quick orientation for new readers. |
| `pool_layout_v1_draft.txt` | Normative specification of the layout. |
| `pool_layout_v1_rationale.md` | Companion explanation of the design choices and trade-offs. |
| `docs/` | Alternative document formats for the rationale. |
| `tools/init_pool_layout/` | Practical tooling for creating a directory tree that follows the specification. |

## Tooling

The repository includes a Bash helper under `tools/init_pool_layout/` that creates the top-level directory families and supports both rootless and system-managed defaults.
That tool is a materializer of the layout, not the layout contract itself, so its documentation belongs with the tool while the root of the repository stays focused on the specification.

## Audience

`pool_layout_v1` is intended for developers, packagers, operators, and runtime integrators who need a shared vocabulary and a stable on-host layout for local LLM artifacts.
It is designed to work in both rootless and system-managed environments without changing the conceptual model.
