#!/usr/bin/env bash

set -u
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WRAPPER="$SCRIPT_DIR/run-macos-tests.sh"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/imsg-test-supervisor.XXXXXX")
KNOWN_PIDS=()
KNOWN_STARTS=()

process_start() {
  local clock
  local day
  local month
  local weekday
  local year

  read -r weekday month day clock year < <(/bin/ps -o lstart= -p "$1" 2>/dev/null) || true
  [[ -n "${year:-}" ]] && printf '%s %s %s %s %s\n' "$weekday" "$month" "$day" "$clock" "$year"
}

remember_pid() {
  local pid=$1
  local start

  start=$(process_start "$pid")
  [[ -n "$start" ]] || return
  KNOWN_PIDS+=("$pid")
  KNOWN_STARTS+=("$start")
}

cleanup() {
  local current_start
  local index
  local pid

  for ((index = 0; index < ${#KNOWN_PIDS[@]}; index++)); do
    pid=${KNOWN_PIDS[$index]}
    current_start=$(process_start "$pid")
    [[ -n "$current_start" && "$current_start" == "${KNOWN_STARTS[$index]}" ]] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  echo "self-test failed: $*" >&2
  exit 1
}

wait_for_file() {
  local path=$1
  local tick

  for ((tick = 0; tick < 40; tick++)); do
    [[ -s "$path" ]] && return 0
    sleep 0.25
  done
  fail "timed out waiting for $path"
}

wait_for_exit() {
  local pid=$1
  local tick

  case "$pid" in
    ''|*[!0-9]*) fail "invalid pid '$pid'" ;;
  esac

  for ((tick = 0; tick < 40; tick++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.25
  done
  fail "pid $pid survived wrapper cleanup"
}

read_started_root() {
  local log=$1

  sed -n 's/.*started root_pid=\([0-9][0-9]*\).*/\1/p' "$log" | head -n 1
}

echo "self-test: normal root and child exit"
normal_log="$TEST_TMP/normal.log"
IMSG_TEST_TIMEOUT_SECONDS=5 "$WRAPPER" /bin/bash -c 'sleep 0.25 & wait; exit 7' >"$normal_log" 2>&1
normal_status=$?
[[ "$normal_status" == 7 ]] || fail "normal command returned $normal_status instead of 7"

echo "self-test: root success with inherited-stdout descendant"
orphan_log="$TEST_TMP/orphan.log"
orphan_pid_file="$TEST_TMP/orphan.pid"
# The Perl signal expressions are intentionally single-quoted inside the nested fixture shell.
# shellcheck disable=SC2016
IMSG_TEST_TIMEOUT_SECONDS=10 "$WRAPPER" /bin/bash -c '
  /usr/bin/perl -e '\''$SIG{HUP} = "IGNORE"; sleep 60'\'' swiftpm-testing-self-test &
  child=$!
  printf "%s\n" "$child" >"$1"
  sleep 1
  exit 0
' wrapper-fixture "$orphan_pid_file" >"$orphan_log" 2>&1
orphan_status=$?
wait_for_file "$orphan_pid_file"
orphan_pid=$(<"$orphan_pid_file")
remember_pid "$orphan_pid"
[[ "$orphan_status" == 124 ]] || fail "orphan case returned $orphan_status instead of 124"
grep -q 'tracked descendants survived root exit' "$orphan_log" || fail "orphan diagnostic was not emitted"
if [[ "$(uname -s)" == "Darwin" && -x /usr/bin/sample ]]; then
  grep -q "sampling pid=$orphan_pid" "$orphan_log" || fail "orphan Swift test process was not sampled"
fi
wait_for_exit "$orphan_pid"

echo "self-test: timeout cleans a live process tree"
timeout_log="$TEST_TMP/timeout.log"
timeout_pid_file="$TEST_TMP/timeout.pid"
# shellcheck disable=SC2016
IMSG_TEST_TIMEOUT_SECONDS=2 "$WRAPPER" /bin/bash -c '
  /usr/bin/perl -e '\''$SIG{TERM} = "IGNORE"; sleep 60'\'' timeout-child &
  child=$!
  printf "%s\n" "$child" >"$1"
  trap "" TERM
  wait "$child"
' wrapper-fixture "$timeout_pid_file" >"$timeout_log" 2>&1
timeout_status=$?
wait_for_file "$timeout_pid_file"
timeout_child_pid=$(<"$timeout_pid_file")
timeout_root_pid=$(read_started_root "$timeout_log")
remember_pid "$timeout_child_pid"
remember_pid "$timeout_root_pid"
[[ "$timeout_status" == 124 ]] || fail "timeout case returned $timeout_status instead of 124"
grep -q 'test supervisor: timeout after' "$timeout_log" || fail "timeout diagnostic was not emitted"
wait_for_exit "$timeout_child_pid"
wait_for_exit "$timeout_root_pid"

echo "self-test: signal cleans a live process tree"
signal_log="$TEST_TMP/signal.log"
signal_pid_file="$TEST_TMP/signal.pid"
# shellcheck disable=SC2016
IMSG_TEST_TIMEOUT_SECONDS=30 "$WRAPPER" /bin/bash -c '
  /usr/bin/perl -e '\''$SIG{TERM} = "IGNORE"; sleep 60'\'' signal-child &
  child=$!
  printf "%s\n" "$child" >"$1"
  trap "" TERM
  wait "$child"
' wrapper-fixture "$signal_pid_file" >"$signal_log" 2>&1 &
supervisor_pid=$!
remember_pid "$supervisor_pid"
wait_for_file "$signal_pid_file"
signal_child_pid=$(<"$signal_pid_file")
remember_pid "$signal_child_pid"
sleep 0.5
signal_root_pid=$(read_started_root "$signal_log")
remember_pid "$signal_root_pid"
kill -TERM "$supervisor_pid"
if wait "$supervisor_pid"; then
  signal_status=0
else
  signal_status=$?
fi
[[ "$signal_status" == 124 ]] || fail "signal case returned $signal_status instead of 124"
grep -q 'received TERM' "$signal_log" || fail "signal diagnostic was not emitted"
wait_for_exit "$signal_child_pid"
wait_for_exit "$signal_root_pid"

echo "self-test: all supervisor cases passed"
