# Architecture Refactor Proposal

*Status: Proposal — not yet implemented. See summary table at the bottom for prioritisation.*

---

## Purpose

This document proposes restructuring the `ai-sandbox` project to address a specific problem: **CLAUDE.md has become a load-bearing monolith**. Every conversation with an agent starts by ingesting 200+ lines covering identity, bash rules, architecture decisions, security invariants, provider env vars, and a routing table — regardless of what the agent is actually doing. A CLI fix to `bin/ai-sandbox` doesn't need the provider env var reference. A Dockerfile change doesn't need the crash recovery procedure. The file's size isn't the real issue; the lack of layering is.

The proposal draws on the structural principles of the Interpretable Context Methodology (ICM) — specifically the insight that **folder structure is agent architecture**, and that stable reference material belongs in a separate layer from routing and identity. The goal is minimum viable restructuring: add layers where they reduce unnecessary loading, without over-engineering for hypothetical future needs.

---

## The ICM Model, Adapted

ICM defines five context layers. Here is how those layers map to this project:

| ICM Layer | ICM Role | Token Budget | This Project Equivalent |
|-----------|----------|-------------|------------------------|
| L0 | `CLAUDE.md` — "Where am I?" | ~800 tok | `CLAUDE.md` (trimmed to identity + sandbox check + routing pointer) |
| L1 | `CONTEXT.md` — "Where do I go?" | ~300 tok | `CONTEXT.md` (new) — routing table replacing the File Map section |
| L2 | `stages/NN/CONTEXT.md` — "What do I do?" | 200–500 tok | `ops/CONTEXT.md`, `docs/CONTEXT.md` (optional, area-level navigation) |
| L3 | `references/` + `_config/` — "What rules apply?" | 500–2k tok | `_standards/` (new) — bash rules, arch decisions, security invariants, git workflow |
| L4 | `output/` — "What am I working with?" | varies | `bin/`, `src/`, `docs/`, `test/` (unchanged — these are the artifacts) |

**L3 is the factory. L4 is the product.** Architecture decisions, security invariants, and bash rules are stable reference material that belongs in L3 (`_standards/`). They don't change on every run and should be loaded on demand, not by default.

---

## Current Structure — What Exists and Where It Breaks Down

```
ai-sandbox/
├── CLAUDE.md                     # ~230 lines: identity + bash rules + arch decisions +
│                                 #   security invariants + file map + provider env vars
│                                 #   + validation approach + crash recovery
├── Makefile                      # 4 targets: build / clean / rebuild / version only
├── README.md                     # public-facing quick start
├── bin/
│   └── ai-sandbox                # CLI
├── docs/
│   ├── AGENTS_AUTH.md            # auth design decisions
│   ├── CHANGELOG.md              # completed steps + history
│   ├── HANDOFF.md                # task handoff context for current work-in-progress
│   ├── PRD.md                    # product requirements
│   ├── SECURITY.md               # threat model
│   ├── SKILLS_LINKING.md         # skills sharing design
│   ├── TUTORIAL.md               # user-facing how-to
│   ├── VERSIONING.md             # tagging rules
│   ├── migration.md              # XDG symlink migration guide
│   └── sandbox-tasks.md          # task implementation guide (adr-workspace migration)
├── setup/
│   └── examples/
│       └── adr-workspace/        # reference workspace (example only)
├── skills/
│   ├── adr-skill -> (XDG symlink)
│   ├── caveman -> (XDG symlink)
│   ├── humanizer -> (XDG symlink)
│   └── workspace-builder -> (XDG symlink)
├── src/
│   ├── Dockerfile
│   └── claude-settings.json
└── test/
    ├── test_cli.sh
    └── test_devcontainer.sh
```

### Where it breaks down

**CLAUDE.md bloat.** The file currently contains six distinct categories of content that belong in different layers:

| Content in CLAUDE.md today | Correct layer | Should live at |
|---------------------------|---------------|----------------|
| Identity, sandbox check | L0 — always needed | `CLAUDE.md` (keep) |
| File map / routing table | L1 — navigation | `CONTEXT.md` (move) |
| Architecture decisions table | L3 — stable reference | `_standards/architecture.md` |
| Bash script rules | L3 — stable reference | `_standards/bash-style.md` |
| Security invariants | L3 — stable reference | `_standards/security-invariants.md` |
| Provider env var reference | L3 — stable reference | `_standards/provider-env.md` |
| Changelog + versioning discipline | L3 — stable reference | `_standards/git-workflow.md` |
| Validation approach | Operational procedure | `ops/update-protocol.md` |
| Crash recovery | User-facing how-to | `docs/TUTORIAL.md` (already covered) |

**No update protocol.** There is no structured guide for how to safely make changes to the CLI, Dockerfile, or config files. The validation approach in CLAUDE.md is a single paragraph with no procedure. A new agent starting a task in this repo has to infer from commit messages and changelogs what approach is safe.

**No active state tracker.** `docs/HANDOFF.md` serves this role for one specific task but is not a general-purpose mechanism. After that task is complete, there's no canonical place for "what's in progress, what's next, what's blocked." The CHANGELOG covers completed work, but there's no STATUS equivalent.

**Makefile is build-only.** Running tests requires knowing the exact command (`bash test/test_cli.sh`). There's no `make test`, no `make check`, no `make setup`. Common operations require reading the TUTORIAL or CHANGELOG to find the right command.

**No first-time setup guide.** `docs/migration.md` covers XDG symlink migration. `docs/TUTORIAL.md` covers usage. But there is no single-file guide for "I just cloned this repo — what do I do first?" on a new machine.

---

## Proposed Structure — After Refactor

```
ai-sandbox/
├── CLAUDE.md                     # L0: ~50 lines — identity + sandbox check +
│                                 #   one-line pointers to CONTEXT.md and _standards/
├── CONTEXT.md                    # L1: routing table — which file for which task
├── STATUS.md                     # active work, recent changes, known blockers
├── Makefile                      # build + test + check + setup targets
├── README.md                     # unchanged
│
├── _standards/                   # L3: stable reference — load on demand, not by default
│   ├── architecture.md           # architecture decisions table (from CLAUDE.md)
│   ├── bash-style.md             # bash script rules (from CLAUDE.md)
│   ├── git-workflow.md           # commit format + versioning + changelog discipline
│   │                             #   (from CLAUDE.md + docs/VERSIONING.md consolidated)
│   ├── provider-env.md           # provider env var reference (from CLAUDE.md)
│   └── security-invariants.md   # security invariants: the never-break rules (from CLAUDE.md)
│
├── bin/
│   └── ai-sandbox                # unchanged
│
├── docs/
│   ├── AGENTS_AUTH.md            # unchanged
│   ├── CHANGELOG.md              # unchanged
│   ├── PRD.md                    # unchanged
│   ├── SECURITY.md               # unchanged
│   ├── SKILLS_LINKING.md         # unchanged
│   ├── TUTORIAL.md               # + crash recovery section (moved from CLAUDE.md)
│   ├── VERSIONING.md             # keep as canonical reference; content also in git-workflow.md
│   ├── migration.md              # unchanged
│   └── sandbox-tasks.md          # unchanged (or moved to ops/TASKS.md — see P4)
│
├── ops/                          # L2: operational procedures — how to work in this repo
│   ├── setup.md                  # first-time machine setup steps
│   ├── TASKS.md                  # active task backlog — replaces sandbox-tasks.md + HANDOFF.md
│   └── update-protocol.md        # how to safely change CLI / Dockerfile / config
│
├── setup/
│   └── examples/
│       └── adr-workspace/        # unchanged
│
├── skills/                       # unchanged (XDG symlinks)
│   └── ...
│
├── src/
│   ├── Dockerfile                # unchanged
│   └── claude-settings.json      # unchanged
│
└── test/
    ├── test_cli.sh               # unchanged
    └── test_devcontainer.sh      # unchanged
```

---

## P1 — Slim CLAUDE.md to a True Layer 0

**What changes:** CLAUDE.md drops from ~230 lines to ~50 lines. All content that isn't routing or identity moves out.

**What stays in CLAUDE.md:**
- Sandbox check (run `whoami` immediately — affects path validity)
- Identity (2–3 sentences: role, primary concern)
- Changelog discipline (one-line rule with pointer to `_standards/git-workflow.md`)
- Pointer to `CONTEXT.md` for all routing ("For which file to open, see `CONTEXT.md`")
- Pointer to `_standards/` for rules ("For coding rules and invariants, see `_standards/`")

**Sketch of slimmed CLAUDE.md:**

```markdown
# CLAUDE.md — AI Sandbox Project

## Sandbox check
Immediately after reading this file, run `whoami`. If `agent`, you are inside
the devcontainer — paths, mounts, and rebuild requirements apply accordingly.

## Identity
DevOps and security engineer. Primary concern: containment. The host filesystem
and credentials must be structurally inaccessible from inside the container.

## Routing
For which file to open for a given task → `CONTEXT.md`
For coding rules and invariants → `_standards/`

## Changelog discipline
After any significant change, add an entry to `docs/CHANGELOG.md`.
Format and tagging rules → `_standards/git-workflow.md`.
```

**Why:** At ~800 tokens the current CLAUDE.md is already within budget, but its content is wrong for L0 — architecture decisions and bash rules are not "Where am I?" content. They're "What rules apply?" content that an agent doing a specific task should pull explicitly, not carry from the start.

**Risk:** Agents that have learned to find rules in CLAUDE.md will need to follow the pointer to `_standards/`. This is a one-time adaptation cost.

---

## P2 — Add CONTEXT.md as Layer 1

**What changes:** The File Map table moves from CLAUDE.md to a new root-level `CONTEXT.md`. CONTEXT.md also gets the project overview and repo layout (currently in CLAUDE.md's "Project Overview" section).

**Sketch of CONTEXT.md:**

```markdown
# CONTEXT.md — AI Sandbox

## What this repo is
`ai-sandbox` is a Bash CLI that wraps `docker run` to launch AI agent harnesses
inside an isolated Debian container. Only `$PWD` is mounted; `$HOME` is never exposed.

## Where to go

| Task | File |
|------|------|
| Understand what the project is, features, security model | docs/PRD.md |
| See completed steps, validation records, key decisions | docs/CHANGELOG.md |
| Learn to use the tool — harnesses, models, flags, devcontainer | docs/TUTORIAL.md |
| Agent auth design — what was tried, why it failed | docs/AGENTS_AUTH.md |
| Skills sharing — path arithmetic, decisions, constraints | docs/SKILLS_LINKING.md |
| Security threat model, Copy Fail / kernel limitations | docs/SECURITY.md |
| CLI logic — flag parsing, docker assembly, env resolution | bin/ai-sandbox |
| Container environment — base image, installed tools | src/Dockerfile |
| Build / rebuild the image | Makefile (make build) |
| Configure harnesses, models, sandbox options | .ai-sandbox/sandbox.json |
| VS Code devcontainer config | .devcontainer/devcontainer.json |
| Coding rules, bash style | _standards/bash-style.md |
| Security invariants — the never-break rules | _standards/security-invariants.md |
| Architecture decisions | _standards/architecture.md |
| Git workflow — commit format, versioning, changelog | _standards/git-workflow.md |
| Provider env var reference | _standards/provider-env.md |
| Active tasks, in-progress work | ops/TASKS.md |
| How to safely make changes to this repo | ops/update-protocol.md |
| First-time machine setup | ops/setup.md |

## Repo layout
[abbreviated tree — same as README.md section]
```

**Why:** The routing table belongs in a dedicated file, not inside the identity file. CONTEXT.md is the one file an agent reads to learn what exists and where to look — loading it explicitly for navigation tasks, not by default.

---

## P3 — Add `_standards/` as Layer 3

**What changes:** Five files are extracted from CLAUDE.md into a dedicated `_standards/` directory. The leading underscore follows the ICM convention (`_config/`) for separating stable reference from routing files.

### `_standards/bash-style.md`
Current source: `CLAUDE.md` §"Bash Script Rules"

Content: the 8 bash scripting rules as-is, formatted as a reference guide rather than embedded in an identity file. Add brief rationale for each rule (currently implicit).

### `_standards/security-invariants.md`
Current source: `CLAUDE.md` §"Security Invariants"

Content: the 6 never-break rules. Expand each with the structural mechanism that enforces it — not just "no `$HOME` mount" but which line of `bin/ai-sandbox` enforces it, so an agent verifying compliance knows where to look.

### `_standards/architecture.md`
Current source: `CLAUDE.md` §"Architecture Decisions"

Content: the architecture decisions table. Add a "Reconsidering?" section noting which decisions are load-bearing (changing the base image is major; changing the container user name is minor) to help an agent scope a proposed change.

### `_standards/provider-env.md`
Current source: `CLAUDE.md` §"Provider Env Var Reference"

Content: the provider → env var mapping table. Add the source of each var (host env, config file, hardcoded) for clarity.

### `_standards/git-workflow.md`
Current sources: `CLAUDE.md` §"Changelog Discipline" + `docs/VERSIONING.md`

Content: consolidated single reference for all git hygiene:
- Changelog entry format and discipline
- Commit message format (the HEREDOC template)
- Tag creation, format, when to tag
- Commands reference (currently in VERSIONING.md)

`docs/VERSIONING.md` either becomes a redirect pointer to `_standards/git-workflow.md`, or stays as the canonical source with `git-workflow.md` excerpting it. Either is valid; the important thing is agents find it in one place.

**Why `_standards/` not `docs/`?** The `docs/` directory holds user-facing and design documents (PRD, TUTORIAL, AGENTS_AUTH). Standards are engineering rules — they apply to agents working on this repo, not to users of the tool. The layer separation also signals to an agent that `_standards/` content is stable (load when rules apply) vs. `docs/` content which evolves with the design.

---

## P4 — Add `ops/` for Operational Procedures

**What changes:** A new `ops/` directory holds the three files needed to work safely in this repo over time. This is the Layer 2 equivalent — "What do I do in this area?"

### `ops/update-protocol.md`
Analogous to the workspace-builder's `skill/update-protocol.md`.

Sections:
1. **Core constraint** — minimum viable change; touch only what the task requires
2. **Procedure** — read first → clarify → identify files affected → propose before acting → make the change → validate → update TASKS.md
3. **Common change types** (table) — what each type of change touches and what to leave alone:

| Change type | Files to touch | Files to leave alone |
|-------------|---------------|----------------------|
| Add a CLI flag | `bin/ai-sandbox` (add arm, update help); `test/test_cli.sh` (new test); `docs/TUTORIAL.md` (new flag row) | `_standards/`, `.devcontainer/`, `src/Dockerfile` |
| Modify container image | `src/Dockerfile`; `Makefile` (version auto-derives from hash, no change); `docs/CHANGELOG.md` | `bin/ai-sandbox` unless image change affects a CLI behaviour |
| Add a provider | `bin/ai-sandbox` (`_inject_*` function + case arm); `_standards/provider-env.md`; `docs/TUTORIAL.md` (provider table); `test/test_cli.sh` | `src/Dockerfile` (provider config is runtime env, not image-time) |
| Add a new mount | `bin/ai-sandbox`; `src/claude-settings.json` (deny rules); `test/test_cli.sh` (mount count); `docs/TUTORIAL.md` if user-facing | `_standards/security-invariants.md` unless a new invariant is introduced |
| Update devcontainer config | `.devcontainer/devcontainer.json`; `test/test_devcontainer.sh` | `bin/ai-sandbox` (devcontainer and CLI are independent paths) |
| Fix a security invariant violation | The violating code; `_standards/security-invariants.md` if the invariant text is wrong; `test/test_cli.sh` (add regression test) | Unrelated CLI behaviour |

4. **Validation checklist** — run `make test` before marking any change complete
5. **Commit message template** — the HEREDOC format with Co-Author line

### `ops/setup.md`
First-time machine setup steps. Answers: "I just cloned this repo. What do I do?"

Sections:
1. **Prerequisites** — Docker installed, `ai-sandbox:latest` image built (`make build`)
2. **Skills setup** — create `~/.local/share/ai-agents/skills/`, clone skill repos, verify symlinks resolve
3. **VS Code devcontainer** — rebuild to activate depth-matched workspace mount
4. **Verify everything** — a copy-paste checklist of verification commands
5. **New project config** — minimal `sandbox.json` template

This consolidates what is currently scattered across: `README.md` quick start, `docs/TUTORIAL.md` §setup, `docs/migration.md`, and `docs/SKILLS_LINKING.md` §required container mounts.

### `ops/TASKS.md`
Active task backlog. Supersedes `docs/sandbox-tasks.md` and `docs/HANDOFF.md` as the canonical "what's outstanding" file.

Structure:
```markdown
# Active Tasks

## In Progress
[task name] — [one-line description] — started YYYY-MM-DD

## Backlog
[priority-ordered list]

## Completed (recent)
[last 3–5 completed tasks with completion date — older entries move to CHANGELOG.md]
```

`docs/sandbox-tasks.md` is archived or folded into `ops/TASKS.md` (the adr-workspace migration section already has a completed status at its top).

**Why `ops/` not `docs/`?** Operational procedures are agent-facing instructions for working on the repo itself. They're not user documentation, design records, or reference material. The name `ops/` distinguishes "how we work" from "what the tool does" (docs/) and "what the rules are" (`_standards/`).

---

## P5 — Expand the Makefile as Task Runner

**What changes:** Add three targets so common operations have a single, discoverable command.

```makefile
# Existing targets: build / clean / rebuild / version

test:
	bash test/test_cli.sh
	bash test/test_devcontainer.sh

check: test
	@echo "--- checking _standards/ referenced from CLAUDE.md ---"
	@for f in _standards/*.md; do test -f "$$f" && echo "  ok: $$f" || echo "  MISSING: $$f"; done

setup:
	@echo "=== ai-sandbox first-time setup ==="
	@echo "See ops/setup.md for full steps."
	@echo ""
	@echo "Quick checklist:"
	@echo "  1. make build"
	@echo "  2. mkdir -p ~/.local/share/ai-agents/skills"
	@echo "  3. Clone skill repos into ~/.local/share/ai-agents/skills/"
	@echo "  4. Rebuild devcontainer"
```

**Why:** `make test` is the single command every contribution validation step starts with. Without it, agents and contributors must read the TUTORIAL or CHANGELOG to find the right invocation. `make check` adds structural validation — verifying that files referenced from CLAUDE.md and CONTEXT.md actually exist, catching broken reorganisations before they reach a commit.

**Tradeoff:** Adding targets to a Makefile that currently serves purely as a build tool changes its character slightly. The alternative is a `scripts/` directory with standalone scripts; that's equivalent complexity for less discoverability.

---

## P6 — Add STATUS.md as Active State Tracker

**What changes:** A `STATUS.md` at the root level answers "where are we right now?" — a question neither CHANGELOG.md (completed work) nor CONTEXT.md (routing) answers.

```markdown
# Status

**As of:** YYYY-MM-DD

## Active work
- [task name] — [brief description] — see ops/TASKS.md

## Recent completions (last 14 days)
- YYYY-MM-DD: [what was done]

## Known blockers
- [none / description]

## Next up
- [1–2 bullet priorities]
```

**Why not PROGRESS.md (the ICM name)?** PROGRESS.md in ICM tracks which stage a pipeline is in — a concept that doesn't directly apply to a tool repo. STATUS.md more accurately describes what this file does: it's a snapshot of current state, not a pipeline tracker.

**Staleness risk:** Any status file can go stale. Mitigate by making the update rule explicit: STATUS.md is updated when a task moves to "In Progress" or "Completed" — same moment TASKS.md and CHANGELOG.md are updated. The three files form a discipline: TASKS.md is the backlog, STATUS.md is the snapshot, CHANGELOG.md is the permanent record.

**Tradeoff:** One more file to maintain. If the project is small enough that context fits in CLAUDE.md anyway, the overhead may exceed the benefit. Status: low priority; implement after P1–P3 and evaluate whether it adds value.

---

## Before / After: File Count and Context Loading

### What an agent loads today for a CLI change

1. `CLAUDE.md` — all 230 lines (identity + bash rules + arch decisions + env var reference + file map + security invariants)
2. `bin/ai-sandbox` — the file to change

Unnecessary load: arch decisions, env var reference, crash recovery, project overview.

### What the same agent loads after the refactor

1. `CLAUDE.md` — ~50 lines (identity + sandbox check + routing pointer)
2. `CONTEXT.md` — ~30 lines (routing table, finds `_standards/bash-style.md` and `ops/update-protocol.md`)
3. `_standards/bash-style.md` — ~20 lines (bash rules, loaded on demand)
4. `ops/update-protocol.md` — change type table row for "Add a CLI flag"
5. `bin/ai-sandbox` — the file to change

Total loaded: same number of files but each one is scoped to the task. The arch decisions table and env var reference are not loaded at all.

---

## Summary Table

| # | Proposal | Element added/changed | Pros | Cons | Impact | Priority |
|---|----------|-----------------------|------|------|--------|----------|
| P1 | Slim CLAUDE.md | CLAUDE.md trimmed from ~230 to ~50 lines | Faster context load; L0 contains only what every task needs; rules stop leaking into the identity file | One-time adaptation: agents must follow the pointer to `_standards/` and `CONTEXT.md` | **High** — affects every conversation | 1 — do first |
| P2 | Add CONTEXT.md | New root-level routing file | Explicit routing replaces implicit File Map in CLAUDE.md; navigation is a distinct concern from identity | One more file to keep current when docs/ changes | **Medium** — improves discoverability, reduces CLAUDE.md | 2 — do with P1 |
| P3 | Add `_standards/` | 5 new files extracted from CLAUDE.md | Stable reference separate from routing; each file is loaded on demand; layer boundary is explicit | More files to navigate; agents must know to look in `_standards/` not CLAUDE.md | **High** — eliminates the L3/L0 conflation | 2 — do with P1 |
| P4 | Add `ops/` | 3 new files: update-protocol, setup, TASKS | Structured change procedure reduces risk; single source for active work; setup guide is now findable | Adds overhead for trivial changes; TASKS.md requires discipline to keep current | **Medium** — primarily benefits larger or multi-session changes | 3 — do after P1–P3 |
| P5 | Expand Makefile | `make test`, `make check`, `make setup` | Common operations become single discoverable commands; `make test` is a standard validation gate | Minor character shift for a build-only Makefile; test suites are already functional without it | **Low–Medium** — convenience; reduces friction for contributors | 3 — do with P4 |
| P6 | Add STATUS.md | New root-level active state file | Clear "where are we now?" for agents starting mid-project; complements CHANGELOG (past) and TASKS (backlog) | Can go stale; small project may not need it | **Low** — high maintenance risk for limited gain at current project size | 4 — evaluate after P1–P4 |

### Sequencing recommendation

**Phase 1 (P1 + P2 + P3 together):** The three proposals are tightly coupled — slimming CLAUDE.md only works if CONTEXT.md and `_standards/` exist first. Do all three in one commit sequence. Total effort: restructuring of existing content, no new content.

**Phase 2 (P4 + P5):** `ops/setup.md` consolidates existing scattered setup instructions. `ops/update-protocol.md` and `ops/TASKS.md` require new content. Makefile targets are two lines each. Evaluate after Phase 1 is running.

**Phase 3 (P6):** Add STATUS.md only if multi-session work makes the "where are we?" problem real. Skip if the project remains single-session / low-concurrency.

---

## What This Does Not Change

- Security model and invariants (these are preserved in `_standards/security-invariants.md`)
- CLI design, Dockerfile, devcontainer config — no functional changes
- `docs/` structure — CHANGELOG, TUTORIAL, PRD, SECURITY are unchanged
- `test/` — both test suites are unchanged
- Skills structure and XDG symlinks — unchanged
- `setup/examples/` — unchanged
- `.ai-sandbox/sandbox.json` and devcontainer configs — unchanged

The refactor is purely structural reorganisation of context delivery. The tool works identically before and after.
