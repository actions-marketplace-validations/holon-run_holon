#!/usr/bin/env bash
# Real-data upgrade verification between two holon builds (previous release
# -> current candidate) using an isolated home, a real model provider, and a
# real runtime database. See README.md for the full contract.
#
# Usage:
#   OLD_BIN=/path/to/previous-release/holon run.sh old   # seed phase
#   run.sh new                                           # upgrade + verify
#
# Environment:
#   OLD_BIN          previous-release holon binary (required for `old`)
#   NEW_BIN          candidate holon binary (default: repo target/debug/holon)
#   MODEL            model route (default: bigmodel/glm-5.2)
#   EXPECTED_SCHEMA  schema revision the candidate must reach (default: 46)
#   PORT_OLD/PORT_NEW  serve ports (default: 7880/7881)
#   WORK_DIR         scratch home + snapshots (default: ~/.holon-upgrade-verify)
#   CONFIG_SRC       dir with config.json/credentials.json (default: ~/.holon)
set -euo pipefail

PHASE="${1:?usage: run.sh old|new}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

OLD_BIN="${OLD_BIN:-}"
NEW_BIN="${NEW_BIN:-$REPO_ROOT/target/debug/holon}"
MODEL="${MODEL:-bigmodel/glm-5.2}"
EXPECTED_SCHEMA="${EXPECTED_SCHEMA:-46}"
PORT_OLD="${PORT_OLD:-7880}"
PORT_NEW="${PORT_NEW:-7881}"
WORK_DIR="${WORK_DIR:-$HOME/.holon-upgrade-verify}"
CONFIG_SRC="${CONFIG_SRC:-$HOME/.holon}"

HOME_DIR="$WORK_DIR/home"
DB_DIR="$HOME_DIR/state"

if [ "$PHASE" = old ]; then
  BIN="$OLD_BIN"; PORT="$PORT_OLD"; MARKER="UPGRADE-REAL-OLD-$(openssl rand -hex 6)"
  OUT="$WORK_DIR/old"
else
  BIN="$NEW_BIN"; PORT="$PORT_NEW"; MARKER="UPGRADE-REAL-NEW-$(openssl rand -hex 6)"
  OUT="$WORK_DIR/new"
fi

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "FAIL: binary not found or not executable: ${BIN:-<unset>}" >&2; exit 2
fi

TOKEN="$(openssl rand -hex 24)"
mkdir -p "$OUT"
echo "MARKER=$MARKER" > "$OUT/marker.env"
API="http://127.0.0.1:$PORT"

auth_curl() { curl -sf -H "Authorization: Bearer $TOKEN" "$@"; }

wait_readiness() {
  for _ in $(seq 1 90); do
    if auth_curl "$API/api/control/runtime/readiness" > "$OUT/readiness.json" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "FAIL: readiness timeout" >&2; tail -20 "$OUT/serve.log" >&2 || true; exit 1
}

agent_id() { jq -r '.startup_surface.default_agent_id // empty' "$OUT/readiness.json"; }

state_sig() {
  # tab-separated: turn_index, message_count(-1 when the DTO omits it), last terminal turn id, posture
  auth_curl "$API/api/agents/$1/state" | jq -r \
    '[ (.agent.agent.turn_index // .agent.turn_index // -1),
       (.agent.agent.total_message_count // .agent.total_message_count // -1),
       (.agent.agent.last_turn_terminal.turn_id // .agent.last_turn_terminal.turn_id // "none"),
       (.agent.scheduling_posture.posture // "unknown") ] | @tsv'
}

prompt_and_wait() {
  # v0.30.0 already reports turn_index=1 before the first prompt (fresh-home
  # bootstrap turn), so "turn_index must grow" never becomes true there. Wait
  # on the terminal turn id changing while the agent is idle instead; use the
  # message count only when the DTO exposes it (main's slim DTO omits it).
  local ag="$1" text="$2" label="$3" sig b_mc b_id ti mc id pp deadline
  sig="$(state_sig "$ag")"
  { IFS=$'\t' read -r _ b_mc b_id _ || true; } <<<"$sig"
  printf '%s\n' "$text" > "$OUT/$label-prompt.txt"
  auth_curl -X POST -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg t "$text" '{text: $t}')" \
    "$API/api/control/agents/$ag/prompt" > "$OUT/$label-prompt-response.json"
  deadline=$((SECONDS + 300))
  while :; do
    sig="$(state_sig "$ag" || true)"
    if [ -n "$sig" ]; then
      { IFS=$'\t' read -r ti mc id pp || true; } <<<"$sig"
      if [ "$id" != "$b_id" ] && [ "$pp" = idle ] && { [ "$mc" -gt "$b_mc" ] 2>/dev/null || [ "$mc" = -1 ]; }; then
        echo "$label: terminal $b_id -> $id (turn_index=$ti msgs=$mc posture=$pp)"
        return 0
      fi
    fi
    if [ "$SECONDS" -gt "$deadline" ]; then
      echo "FAIL: turn timeout for $label (turn_index=${ti:-?} msgs=${mc:-?} terminal=${id:-?} posture=${pp:-?} baseline_terminal=$b_id)" >&2
      auth_curl "$API/api/agents/$ag/state" > "$OUT/$label-state-timeout.json" || true
      exit 1
    fi
    sleep 3
  done
}

snapshot() {
  local label="$1" dir
  # NB: bash expands all words of a single `local` statement before any
  # assignment lands, so referencing `label` there trips set -u. Split it.
  dir="$OUT/$label-db"
  rm -rf "$dir"; mkdir -p "$dir"
  [ -f "$DB_DIR/runtime.sqlite" ] || { echo "FAIL: db missing" >&2; exit 1; }
  for f in runtime.sqlite runtime.sqlite-wal runtime.sqlite-shm; do
    cp "$DB_DIR/$f" "$dir/" 2>/dev/null || true
  done
  python3 "$SCRIPT_DIR/snap.py" "$dir" "$MARKER" "$OUT/$label-snapshot.json"
}

stop_serve() {
  auth_curl -X POST -H 'Content-Type: application/json' -d '{}' \
    "$API/api/control/runtime/shutdown" > "$OUT/shutdown.json" 2>/dev/null || true
  for _ in $(seq 1 30); do
    kill -0 "$SERVE_PID" 2>/dev/null || return 0
    sleep 1
  done
  kill "$SERVE_PID" 2>/dev/null || true
  sleep 2
  kill -9 "$SERVE_PID" 2>/dev/null || true
}
trap stop_serve EXIT

echo "== phase=$PHASE bin=$($BIN --version) marker=$MARKER"

if [ "$PHASE" = old ]; then
  rm -rf "$HOME_DIR"; mkdir -p "$HOME_DIR"
  cp "$CONFIG_SRC/config.json" "$CONFIG_SRC/credentials.json" "$HOME_DIR/"
  chmod 600 "$HOME_DIR/credentials.json"
  jq --arg m "$MODEL" '.model.default=$m | .model.fallbacks=[] | .runtime.disable_provider_fallback=true' \
    "$HOME_DIR/config.json" > "$HOME_DIR/config.json.tmp" && mv "$HOME_DIR/config.json.tmp" "$HOME_DIR/config.json"
fi

HOLON_HOME="$HOME_DIR" HOLON_CONTROL_TOKEN="$TOKEN" HOLON_CONTROL_AUTH_MODE=required \
  "$BIN" serve --listen "127.0.0.1:$PORT" > "$OUT/serve.log" 2>&1 &
SERVE_PID=$!

wait_readiness
AG="$(agent_id)"
[ -n "$AG" ] || { echo "FAIL: no default agent" >&2; exit 1; }
echo "agent=$AG model=$(jq -c '.startup_surface.model_default // .runtime_surface.model_default // "unknown"' "$OUT/readiness.json")"

if [ "$PHASE" = old ]; then
  prompt_and_wait "$AG" "Real-data upgrade verification on the old runtime. Remember this secret marker for later: $MARKER. Reply with exactly the marker and nothing else." turn1-marker
  prompt_and_wait "$AG" "Use the ExecCommand tool to run the shell command: uname -sr. Then reply with the exact stdout line." turn2-tool
  prompt_and_wait "$AG" "In one short sentence: what secret marker did I ask you to remember earlier in this session?" turn3-recall
  snapshot old-final
  stop_serve
  trap - EXIT
  echo "OLD PHASE DONE"
  exit 0
fi

# ---- candidate phase ----
snapshot new-migrated
SCHEMA_V="$(jq -r '.schema_revision' "$OUT/new-migrated-snapshot.json")"
BASELINE_N="$(jq -r '.baseline_count' "$OUT/new-migrated-snapshot.json")"
INTEG="$(jq -r '.integrity' "$OUT/new-migrated-snapshot.json")"
OVER25="$(jq -r '.versions_over_25' "$OUT/new-migrated-snapshot.json")"
echo "post-migration: schema=$SCHEMA_V baseline=$BASELINE_N over25=$OVER25 integrity=$INTEG"
[ "$INTEG" = ok ] || { echo "FAIL: integrity after migration" >&2; exit 1; }
[ "$SCHEMA_V" = "$EXPECTED_SCHEMA" ] || { echo "FAIL: expected schema $EXPECTED_SCHEMA, got $SCHEMA_V" >&2; exit 1; }
[ "$BASELINE_N" = 1 ] || { echo "FAIL: expected 1 baseline row, got $BASELINE_N" >&2; exit 1; }

OLD_BASE="$WORK_DIR/old"
OLD_MARKER="$(sed -n 's/^MARKER=//p' "$OLD_BASE/marker.env")"
[ -n "$OLD_MARKER" ] || { echo "FAIL: run the 'old' phase first (no marker in $OLD_BASE/marker.env)" >&2; exit 2; }
python3 "$SCRIPT_DIR/preserve.py" "$OLD_BASE/old-final-snapshot.json" "$OUT/new-migrated-snapshot.json" > "$OUT/preservation.json"
OLD_MARK_NOW="$(python3 "$SCRIPT_DIR/dbq.py" "$OUT/new-migrated-db/runtime.sqlite" "SELECT COUNT(*) FROM messages WHERE payload_json LIKE ?" "$OLD_MARKER")"
MISSING_AGENTS="$(jq -r '.agents_lost | length' "$OUT/preservation.json")"
MISSING_MSGS="$(jq -r '.messages_lost | length' "$OUT/preservation.json")"
echo "preservation: missing_agents=$MISSING_AGENTS missing_messages=$MISSING_MSGS old_marker_messages_now=$OLD_MARK_NOW"
[ "$MISSING_AGENTS" = 0 ] || { echo "FAIL: agent rows lost" >&2; exit 1; }
[ "$MISSING_MSGS" = 0 ] || { echo "FAIL: message rows lost" >&2; exit 1; }
[ "${OLD_MARK_NOW:-0}" -ge 1 ] || { echo "FAIL: old marker lost in migration" >&2; exit 1; }

prompt_and_wait "$AG" "Real-data upgrade verification on the upgraded runtime. Remember this new secret marker: $MARKER. Reply with exactly the marker and nothing else." turn4-newmarker
prompt_and_wait "$AG" "Earlier in this session, before the runtime restart and upgrade, I asked you to remember a secret marker that starts with UPGRADE-REAL-OLD. What was that exact marker? Reply with the exact marker only." turn5-recallold
prompt_and_wait "$AG" "Use the ExecCommand tool to run the shell command: uname -sr. Then reply with the exact stdout line." turn6-tool

snapshot new-final
NEW_MARK_MSGS="$(jq -r '.marker_messages' "$OUT/new-final-snapshot.json")"
OLD_MARK_MSGS2="$(python3 "$SCRIPT_DIR/dbq.py" "$OUT/new-final-db/runtime.sqlite" "SELECT COUNT(*) FROM messages WHERE payload_json LIKE ?" "$OLD_MARKER")"
echo "final: new_marker_messages=$NEW_MARK_MSGS old_marker_messages=$OLD_MARK_MSGS2 unamemsgs=$(jq -r '.unamemsgs' "$OUT/new-final-snapshot.json")"
[ "${NEW_MARK_MSGS:-0}" -ge 1 ] || { echo "FAIL: new marker not persisted" >&2; exit 1; }
[ "${OLD_MARK_MSGS2:-0}" -ge 1 ] || { echo "FAIL: old marker missing at final" >&2; exit 1; }

auth_curl "$API/api/agents/$AG/transcript?limit=200" > "$OUT/new-final-transcript.json" || true
TRANSCRIPT_OLD_HITS="$(jq -r --arg m "$OLD_MARKER" '[((.entries? // .)[]?) | select((tostring | contains($m)))] | length' "$OUT/new-final-transcript.json" 2>/dev/null || echo 0)"
echo "transcript_old_marker_hits=$TRANSCRIPT_OLD_HITS"
[ "${TRANSCRIPT_OLD_HITS:-0}" -ge 1 ] || { echo "FAIL: old marker not visible in transcript API" >&2; exit 1; }

stop_serve
trap - EXIT
echo "NEW PHASE DONE"
