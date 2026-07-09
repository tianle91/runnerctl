#!/usr/bin/env bash
#
# Tests for runnerctl. Dependency-free: pure Bash plus the same standard tools
# runnerctl itself needs (find, pgrep, pkill, nohup). Run from anywhere:
#
#   ./test/runnerctl.test.sh
#
# Each test builds a throwaway directory of fake runner installs. A fake runner
# is a run.sh that execs a bash loop under the path runnerctl matches
# (<dir>/bin/Runner.Listener, via `exec -a`) so pgrep/pkill see a realistic
# process, and records its own scheduling priority so we can assert on it.

set -uo pipefail

RUNNERCTL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/runnerctl"
OS="$(uname)"

# Each test group runs in its own ( ) subshell for isolation, so counters kept
# in shell variables wouldn't survive back to the parent. Record one line per
# assertion ('P'/'F') in a shared file and tally it at the end.
RESULTS="$(mktemp)"
export RESULTS
trap 'rm -f "$RESULTS"' EXIT

# --- tiny assertion helpers -------------------------------------------------

fail() { printf '  ✗ %s\n' "$1"; echo F >>"$RESULTS"; }
ok()   { printf '  ✓ %s\n' "$1"; echo P >>"$RESULTS"; }

assert_contains() { # haystack needle desc
  case "$1" in
    *"$2"*) ok "$3" ;;
    *)      fail "$3 — expected to contain: $2"; printf '    got: %s\n' "$1" ;;
  esac
}
assert_eq() { # actual expected desc
  if [ "$1" = "$2" ]; then ok "$3"; else fail "$3 — expected '$2', got '$1'"; fi
}
assert_not_contains() { # haystack needle desc
  case "$1" in
    *"$2"*) fail "$3 — did not expect: $2"; printf '    got: %s\n' "$1" ;;
    *)      ok "$3" ;;
  esac
}

# --- fixture helpers --------------------------------------------------------

# make_runner DIR REPO MODE
#   MODE=graceful  -> exits ~0.2s after SIGINT
#   MODE=stubborn  -> ignores SIGINT (forces the force-kill path)
make_runner() {
  local root="$1" repo="$2" mode="$3"
  local rdir="$root/$repo/actions-runner"
  mkdir -p "$rdir/bin"
  local trap_body
  case "$mode" in
    stubborn) trap_body='trap "" INT' ;;
    *)        trap_body='trap "exit 0" INT' ;;
  esac
  cat > "$rdir/run.sh" <<EOF
#!/usr/bin/env bash
# record our scheduling priority for the test to inspect
{ echo "nice=\$(ps -o ni= -p \$\$ | tr -d '[:space:]')"; ionice -p \$\$ 2>/dev/null || true; } > "$rdir/sched.txt"
exec -a "$rdir/bin/Runner.Listener" bash -c '$trap_body; while true; do sleep 0.1; done'
EOF
  chmod +x "$rdir/run.sh"
}

# Kill anything still running under a fixture root, quietly.
cleanup_root() { pkill -KILL -f "$1/" >/dev/null 2>&1 || true; }

newroot() { mktemp -d; }

# ---------------------------------------------------------------------------

echo "runnerctl: $RUNNERCTL"
echo "os: $OS"
echo

echo "no runners found"
(
  root="$(newroot)"
  out="$("$RUNNERCTL" -d "$root" start 2>&1)"
  assert_contains "$out" "No runners found" "start reports empty directory"
  out="$("$RUNNERCTL" -d "$root" status 2>&1)"
  assert_contains "$out" "No runners found" "status reports empty directory"
  rm -rf "$root"
)

echo "start / status / pid file"
(
  root="$(newroot)"; make_runner "$root" repoA graceful
  # run from an unrelated cwd to catch pid written to the wrong directory
  out="$(cd / && "$RUNNERCTL" -d "$root" --no-nice start 2>&1)"
  assert_contains "$out" "✓ repoA: started" "start reports the runner started"
  assert_not_contains "$out" "No such file" "start does not error reading the pid file"
  assert_not_contains "$out" "pid )" "start message includes a pid"

  pidfile="$root/repoA/actions-runner/runner.pid"
  if [ -f "$pidfile" ]; then ok "runner.pid written in the runner dir"; else fail "runner.pid missing from runner dir"; fi
  [ -f /runner.pid ] && { fail "pid leaked into cwd (/runner.pid)"; rm -f /runner.pid; } || ok "no stray pid file in cwd"

  pid="$(cat "$pidfile" 2>/dev/null)"
  assert_contains "$out" "pid $pid" "reported pid matches runner.pid contents"

  out="$("$RUNNERCTL" -d "$root" status 2>&1)"
  assert_contains "$out" "● repoA: running" "status shows the runner running"

  # re-run safe
  out="$("$RUNNERCTL" -d "$root" --no-nice start 2>&1)"
  assert_contains "$out" "already running" "start is re-run safe"

  cleanup_root "$root"; rm -rf "$root"
)

echo "niceness (default on, --no-nice off)"
(
  root="$(newroot)"; make_runner "$root" repoN graceful
  "$RUNNERCTL" -d "$root" start >/dev/null 2>&1
  sleep 0.4
  sched="$(cat "$root/repoN/actions-runner/sched.txt" 2>/dev/null)"
  if [ "$OS" = "Linux" ]; then
    assert_contains "$sched" "nice=19" "default start runs at max niceness (nice 19)"
    assert_contains "$sched" "idle"    "default start runs at idle I/O priority"
  else
    # macOS uses taskpolicy -b (background QoS), not a visible nice value; just
    # confirm it launched.
    if [ -n "$sched" ]; then ok "default start launched (macOS QoS not inspectable via ps)"; else fail "runner did not launch"; fi
  fi
  cleanup_root "$root"; rm -rf "$root"

  root="$(newroot)"; make_runner "$root" repoN graceful
  "$RUNNERCTL" -d "$root" --no-nice start >/dev/null 2>&1
  sleep 0.4
  sched="$(cat "$root/repoN/actions-runner/sched.txt" 2>/dev/null)"
  if [ "$OS" = "Linux" ]; then
    assert_contains "$sched" "nice=0" "--no-nice start runs at normal priority (nice 0)"
  else
    if [ -n "$sched" ]; then ok "--no-nice start launched"; else fail "runner did not launch"; fi
  fi
  cleanup_root "$root"; rm -rf "$root"
)

echo "stop: graceful shutdown"
(
  root="$(newroot)"; make_runner "$root" repoG graceful
  "$RUNNERCTL" -d "$root" --no-nice start >/dev/null 2>&1
  sleep 0.4
  out="$("$RUNNERCTL" -d "$root" stop 2>&1)"
  assert_contains "$out" "→ repoG: stopping…" "stop confirms which runner it is stopping"
  assert_contains "$out" "✗ repoG: stopped" "stop reports the runner stopped gracefully"
  assert_not_contains "$out" "force-killed" "graceful runner is not force-killed"
  out="$("$RUNNERCTL" -d "$root" status 2>&1)"
  assert_contains "$out" "○ repoG: stopped" "status shows the runner stopped afterwards"
  cleanup_root "$root"; rm -rf "$root"
)

echo "stop: force-kill of a runner that ignores SIGINT"
(
  root="$(newroot)"; make_runner "$root" repoS stubborn
  "$RUNNERCTL" -d "$root" --no-nice start >/dev/null 2>&1
  sleep 0.4
  # short grace window so the test is fast
  out="$(RUNNERCTL_STOP_GRACE=1 "$RUNNERCTL" -d "$root" stop 2>&1)"
  assert_contains "$out" "force-killed" "stubborn runner is force-killed after the grace period"
  out="$("$RUNNERCTL" -d "$root" status 2>&1)"
  assert_contains "$out" "○ repoS: stopped" "runner is gone after force-kill"
  cleanup_root "$root"; rm -rf "$root"
)

echo "stop: not-running runner"
(
  root="$(newroot)"; make_runner "$root" repoX graceful  # installed but never started
  out="$("$RUNNERCTL" -d "$root" stop 2>&1)"
  assert_contains "$out" "○ repoX: not running" "stop reports a runner that was never started"
  rm -rf "$root"
)

echo "cli: help and bad usage"
(
  out="$("$RUNNERCTL" --help 2>&1)"; rc=$?
  assert_contains "$out" "Usage:" "--help prints usage"
  assert_eq "$rc" "0" "--help exits 0"
  out="$("$RUNNERCTL" bogus 2>&1)"; rc=$?
  assert_contains "$out" "unknown command" "unknown command is rejected"
  assert_eq "$rc" "2" "unknown command exits 2"
  out="$("$RUNNERCTL" --nope start 2>&1)"; rc=$?
  assert_contains "$out" "unknown option" "unknown option is rejected"
  assert_eq "$rc" "2" "unknown option exits 2"
)

echo
echo "----------------------------------------"
PASS="$(grep -c P "$RESULTS" || true)"
FAIL="$(grep -c F "$RESULTS" || true)"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
