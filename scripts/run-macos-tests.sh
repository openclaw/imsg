#!/usr/bin/env bash

set -u
set -o pipefail

TIMEOUT_SECONDS=${IMSG_TEST_TIMEOUT_SECONDS:-600}
HEARTBEAT_SECONDS=30
POLL_SECONDS=0.25
EXIT_GRACE_TICKS=8
TERM_GRACE_TICKS=12

case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*)
    echo "IMSG_TEST_TIMEOUT_SECONDS must be a positive integer." >&2
    exit 2
    ;;
esac

TIMEOUT_SECONDS=$((10#$TIMEOUT_SECONDS))
if (( TIMEOUT_SECONDS <= 0 )); then
  echo "IMSG_TEST_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 2
fi

if (( $# == 0 )); then
  set -- make test
fi

TABLE_PIDS=()
TABLE_PPIDS=()
TABLE_STARTS=()
TREE_PIDS=()
TREE_STARTS=()
TREE_DEPTHS=()
TRACKED_PIDS=()
TRACKED_STARTS=()
TRACKED_DEPTHS=()
COMBINED_PIDS=()
COMBINED_STARTS=()
COMBINED_DEPTHS=()
CLEANUP_STARTED=0
ROOT_OWNED=0

process_start() {
  local clock
  local day
  local month
  local weekday
  local year

  read -r weekday month day clock year < <(/bin/ps -o lstart= -p "$1" 2>/dev/null) || true
  [[ -n "${year:-}" ]] && printf '%s %s %s %s %s\n' "$weekday" "$month" "$day" "$clock" "$year"
}

process_parent() {
  /bin/ps -o ppid= -p "$1" 2>/dev/null | tr -d '[:space:]'
}

process_matches() {
  local pid=$1
  local expected_start=$2
  local current_start

  current_start=$(process_start "$pid")
  [[ -n "$current_start" && "$current_start" == "$expected_start" ]]
}

root_is_owned() {
  [[ "$(process_parent "$ROOT_PID")" == "$$" ]] || return 1
  process_matches "$ROOT_PID" "$ROOT_START"
}

load_process_table() {
  local clock
  local day
  local month
  local pid
  local ppid
  local weekday
  local year

  TABLE_PIDS=()
  TABLE_PPIDS=()
  TABLE_STARTS=()

  while read -r pid ppid weekday month day clock year; do
    case "$pid:$ppid" in
      *[!0-9:]*|:*) continue ;;
    esac
    TABLE_PIDS+=("$pid")
    TABLE_PPIDS+=("$ppid")
    TABLE_STARTS+=("$weekday $month $day $clock $year")
  done < <(/bin/ps -axo pid=,ppid=,lstart= 2>/dev/null)
}

table_has_identity() {
  local expected_pid=$1
  local expected_start=$2
  local index

  for ((index = 0; index < ${#TABLE_PIDS[@]}; index++)); do
    if [[ "${TABLE_PIDS[$index]}" == "$expected_pid" && "${TABLE_STARTS[$index]}" == "$expected_start" ]]; then
      return 0
    fi
  done
  return 1
}

collect_subtree() {
  local parent=$1
  local depth=$2
  local index

  for ((index = 0; index < ${#TABLE_PIDS[@]}; index++)); do
    [[ "${TABLE_PPIDS[$index]}" == "$parent" ]] || continue
    collect_subtree "${TABLE_PIDS[$index]}" "$((depth + 1))"
  done

  for ((index = 0; index < ${#TABLE_PIDS[@]}; index++)); do
    [[ "${TABLE_PIDS[$index]}" == "$parent" ]] || continue
    TREE_PIDS+=("$parent")
    TREE_STARTS+=("${TABLE_STARTS[$index]}")
    TREE_DEPTHS+=("$depth")
    return
  done
}

track_identity() {
  local pid=$1
  local start=$2
  local depth=$3
  local index

  for ((index = 0; index < ${#TRACKED_PIDS[@]}; index++)); do
    if [[ "${TRACKED_PIDS[$index]}" == "$pid" && "${TRACKED_STARTS[$index]}" == "$start" ]]; then
      if (( depth > TRACKED_DEPTHS[index] )); then
        TRACKED_DEPTHS[index]=$depth
      fi
      return
    fi
  done

  TRACKED_PIDS+=("$pid")
  TRACKED_STARTS+=("$start")
  TRACKED_DEPTHS+=("$depth")
}

observe_descendants() {
  local index
  local root_index=-1

  load_process_table
  TREE_PIDS=()
  TREE_STARTS=()
  TREE_DEPTHS=()
  ROOT_OWNED=0

  for ((index = 0; index < ${#TABLE_PIDS[@]}; index++)); do
    if [[ "${TABLE_PIDS[$index]}" == "$ROOT_PID" && "${TABLE_STARTS[$index]}" == "$ROOT_START" ]]; then
      root_index=$index
      break
    fi
  done

  if (( root_index < 0 )); then
    if root_is_owned; then
      ROOT_OWNED=1
      return 0
    fi
    return 1
  fi

  if [[ "${TABLE_PPIDS[$root_index]}" != "$$" ]]; then
    return 1
  fi

  ROOT_OWNED=1
  collect_subtree "$ROOT_PID" 0

  for ((index = 0; index < ${#TREE_PIDS[@]}; index++)); do
    [[ "${TREE_PIDS[$index]}" == "$ROOT_PID" ]] && continue
    track_identity "${TREE_PIDS[$index]}" "${TREE_STARTS[$index]}" "${TREE_DEPTHS[$index]}"
  done
  return 0
}

build_combined_set() {
  local depth
  local index
  local maximum_depth=0

  COMBINED_PIDS=()
  COMBINED_STARTS=()
  COMBINED_DEPTHS=()

  for ((index = 0; index < ${#TRACKED_PIDS[@]}; index++)); do
    if (( TRACKED_DEPTHS[index] > maximum_depth )); then
      maximum_depth=${TRACKED_DEPTHS[$index]}
    fi
  done

  for ((depth = maximum_depth; depth >= 1; depth--)); do
    for ((index = 0; index < ${#TRACKED_PIDS[@]}; index++)); do
      (( TRACKED_DEPTHS[index] == depth )) || continue
      table_has_identity "${TRACKED_PIDS[$index]}" "${TRACKED_STARTS[$index]}" || continue
      COMBINED_PIDS+=("${TRACKED_PIDS[$index]}")
      COMBINED_STARTS+=("${TRACKED_STARTS[$index]}")
      COMBINED_DEPTHS+=("$depth")
    done
  done

  if (( ROOT_OWNED != 0 )); then
    COMBINED_PIDS+=("$ROOT_PID")
    COMBINED_STARTS+=("$ROOT_START")
    COMBINED_DEPTHS+=("0")
  fi
}

refresh_combined_set() {
  observe_descendants || true
  build_combined_set
}

print_process_table() {
  local index
  local pid

  if (( ${#COMBINED_PIDS[@]} == 0 )); then
    echo "test supervisor: tracked process set is no longer running"
    return
  fi

  echo "test supervisor: tracked process set (descendants first)"
  printf '%6s %6s %-5s %11s %s\n' PID PPID STATE ELAPSED COMMAND
  for ((index = 0; index < ${#COMBINED_PIDS[@]}; index++)); do
    pid=${COMBINED_PIDS[$index]}
    process_matches "$pid" "${COMBINED_STARTS[$index]}" || continue
    /bin/ps -o pid=,ppid=,state=,etime=,command= -p "$pid" || true
  done
}

sample_swift_tests() {
  local command
  local did_sample=0
  local index
  local pid

  [[ "$(uname -s)" == "Darwin" && -x /usr/bin/sample ]] || return 0

  for ((index = 0; index < ${#COMBINED_PIDS[@]}; index++)); do
    pid=${COMBINED_PIDS[$index]}
    process_matches "$pid" "${COMBINED_STARTS[$index]}" || continue
    command=$(/bin/ps -o command= -p "$pid" 2>/dev/null || true)

    case "$command" in
      *swift-package*|*swift-test*|*swiftpm-testing*|*xctest*|*XCTest*|*PackageTests*)
        did_sample=1
        echo "test supervisor: sampling pid=$pid command=$command"
        if ! /usr/bin/sample "$pid" 5 1; then
          echo "test supervisor: sample failed for pid=$pid (diagnostic only)" >&2
        fi
        ;;
    esac
  done

  if (( did_sample == 0 )); then
    echo "test supervisor: no living Swift test processes to sample"
  fi
}

send_signal_to_combined() {
  local index
  local pid
  local signal_name=$1

  for ((index = 0; index < ${#COMBINED_PIDS[@]}; index++)); do
    pid=${COMBINED_PIDS[$index]}
    [[ "$pid" == "$ROOT_PID" ]] && continue
    process_matches "$pid" "${COMBINED_STARTS[$index]}" || continue
    kill -"$signal_name" "$pid" 2>/dev/null || true
  done

  if (( ROOT_OWNED != 0 )) && root_is_owned; then
    kill -"$signal_name" "$ROOT_PID" 2>/dev/null || true
  fi
}

terminate_tracked_processes() {
  local tick

  refresh_combined_set
  if (( ${#COMBINED_PIDS[@]} > 0 )); then
    echo "test supervisor: sending TERM to tracked processes"
    send_signal_to_combined TERM
  fi

  for ((tick = 0; tick < TERM_GRACE_TICKS; tick++)); do
    sleep "$POLL_SECONDS"
    refresh_combined_set
    (( ${#COMBINED_PIDS[@]} == 0 )) && break
  done

  refresh_combined_set
  if (( ${#COMBINED_PIDS[@]} > 0 )); then
    echo "test supervisor: sending KILL to remaining tracked processes"
    send_signal_to_combined KILL
  fi

  wait "$ROOT_PID" 2>/dev/null || true

  for ((tick = 0; tick < EXIT_GRACE_TICKS; tick++)); do
    sleep "$POLL_SECONDS"
    refresh_combined_set
    (( ${#COMBINED_PIDS[@]} == 0 )) && break
  done
}

diagnose_and_exit() {
  local reason=$1

  if (( CLEANUP_STARTED != 0 )); then
    return
  fi
  CLEANUP_STARTED=1
  trap '' HUP INT TERM

  ELAPSED_SECONDS=$((SECONDS - START_SECONDS))
  echo "test supervisor: $reason after ${ELAPSED_SECONDS}s root_pid=$ROOT_PID" >&2
  refresh_combined_set
  print_process_table
  sample_swift_tests
  terminate_tracked_processes
  exit 124
}

# Invoked indirectly by the signal traps below.
# shellcheck disable=SC2329
on_signal() {
  diagnose_and_exit "received $1"
}

"$@" &
ROOT_PID=$!
ROOT_START=$(process_start "$ROOT_PID")
START_SECONDS=$SECONDS
ELAPSED_SECONDS=0
NEXT_HEARTBEAT=$HEARTBEAT_SECONDS

trap 'on_signal HUP' HUP
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

echo "test supervisor: started root_pid=$ROOT_PID timeout=${TIMEOUT_SECONDS}s"

while observe_descendants; do
  ELAPSED_SECONDS=$((SECONDS - START_SECONDS))
  if (( ELAPSED_SECONDS >= TIMEOUT_SECONDS )); then
    diagnose_and_exit "timeout"
  fi

  if (( ELAPSED_SECONDS >= NEXT_HEARTBEAT )); then
    echo "test supervisor: elapsed=${ELAPSED_SECONDS}s root_pid=$ROOT_PID tracked_descendants=${#TRACKED_PIDS[@]}"
    NEXT_HEARTBEAT=$((NEXT_HEARTBEAT + HEARTBEAT_SECONDS))
  fi

  sleep "$POLL_SECONDS"
done

if wait "$ROOT_PID"; then
  COMMAND_STATUS=0
else
  COMMAND_STATUS=$?
fi

for ((tick = 0; tick < EXIT_GRACE_TICKS; tick++)); do
  refresh_combined_set
  (( ${#COMBINED_PIDS[@]} == 0 )) && break
  sleep "$POLL_SECONDS"
done

refresh_combined_set
if (( ${#COMBINED_PIDS[@]} > 0 )); then
  diagnose_and_exit "tracked descendants survived root exit"
fi

trap - HUP INT TERM
exit "$COMMAND_STATUS"
