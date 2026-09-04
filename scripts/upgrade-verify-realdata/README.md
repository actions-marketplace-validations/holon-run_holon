# Real-Data Upgrade Verification

End-to-end upgrade check between two `holon` builds — typically the previous
release tag and the current release candidate — using an isolated home, a real
model provider, and a real runtime database. It answers the release question:
can a deployment running the old version be upgraded in place, with no lost
state and no visible seam for the agent?

Unlike the `previous_image` upgrade case inside Release E2E (which drives a
containerized pair with synthetic checks), this harness runs on the host with
your real provider credentials and exercises memory, tools, and transcript
continuity through the model itself.

## What it verifies

`run.sh old` — seed phase on the previous-release binary (fresh isolated
home):

- three real-model turns: secret-marker memory, `ExecCommand` tool use, and
  marker recall
- a final DB snapshot (`old/old-final-snapshot.json`)

`run.sh new` — upgrade phase on the candidate binary (same home, state kept):

- startup migration completed: `integrity_check` ok, schema revision equals
  `EXPECTED_SCHEMA`, and exactly one migration baseline row
- zero agent or message rows lost versus the old snapshot; the old marker
  message still exists in the migrated DB
- turn_index continues seamlessly; a new marker is remembered and persisted
- the agent recalls the old marker from before the restart (cross-upgrade
  context/memory continuity)
- tool execution works after the upgrade, and the old marker remains visible
  through the transcript API

Any failed assertion prints `FAIL: ...` and exits non-zero.

## Prerequisites

- `bash`, `curl`, `jq`, `openssl`, `python3`
- a previous-release binary and a candidate binary (see below)
- `CONFIG_SRC` (default `~/.holon`) containing `config.json` and
  `credentials.json` with working real-provider access for `MODEL`

Build the previous-release binary in a worktree, for example for `v0.30.0`:

```bash
git worktree add ../holon-prev v0.30.0
cargo build --manifest-path ../holon-prev/Cargo.toml
```

Build the candidate from the repo under test:

```bash
cargo build
```

## Usage

```bash
OLD_BIN=../holon-prev/target/debug/holon scripts/upgrade-verify-realdata/run.sh old
scripts/upgrade-verify-realdata/run.sh new
```

Both phases must run against the same `WORK_DIR` (default
`~/.holon-upgrade-verify`); the `new` phase reads `old/marker.env` and the old
snapshot. On success each phase prints `OLD PHASE DONE` / `NEW PHASE DONE`.

### Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `OLD_BIN` | — | previous-release binary, required for `old` |
| `NEW_BIN` | repo `target/debug/holon` | candidate binary |
| `MODEL` | `bigmodel/glm-5.2` | model route used for all turns |
| `EXPECTED_SCHEMA` | `46` | schema revision the candidate must reach |
| `PORT_OLD` / `PORT_NEW` | `7880` / `7881` | serve ports |
| `WORK_DIR` | `~/.holon-upgrade-verify` | isolated home + snapshots |
| `CONFIG_SRC` | `~/.holon` | source of `config.json`/`credentials.json` |

`EXPECTED_SCHEMA` must match the candidate's current schema revision; bump it
when the schema moves past 46. The model route is pinned with fallbacks
disabled so a pass means the configured route really worked.

## Outputs and cleanup

`WORK_DIR` holds the isolated `home/` (including a copy of your
`credentials.json`), per-phase `serve.log`, prompts, snapshots, and DB copies
under `old/` and `new/`. It contains secrets and runtime data — delete it
after the run:

```bash
rm -rf ~/.holon-upgrade-verify
```

## Provenance

Validated 2026-08-16 for `v0.30.0` (schema 25) -> main `ecd4c93c`
(schema 46): both phases exit 0, 0 agents/0 messages lost, old marker
recalled across the upgrade and still visible via the transcript API.
