# AGENTS.md

Developer/contributor notes for `runnerctl`. User-facing docs live in
[README.md](README.md).

## Layout

```
runnerctl                 the whole tool — one dependency-free Bash script
test/runnerctl.test.sh    the test suite (also dependency-free Bash)
.github/workflows/test.yml  CI: runs the suite on Linux + macOS
```

There is intentionally no build step and no runtime dependency beyond Bash and
standard Unix tools (`find`, `pgrep`, `pkill`, `nohup`, `nice`/`ionice` on
Linux, `taskpolicy` on macOS). Keep it that way — portability to a stock macOS
(Bash 3.2!) and Linux is the point.

## Running the tests

```sh
./test/runnerctl.test.sh
```

Exit code is non-zero if any assertion fails. The suite builds throwaway
directories of *fake* runners: each `run.sh` execs a bash loop under the path
`runnerctl` matches (`<dir>/bin/Runner.Listener`, via `exec -a`) so
`pgrep`/`pkill` see a realistic process, and records its own scheduling
priority so tests can assert on it. Fake runners come in two flavours —
`graceful` (exits on SIGINT) and `stubborn` (ignores SIGINT, to exercise the
force-kill path).

To keep the force-kill test fast it sets `RUNNERCTL_STOP_GRACE=1` so the grace
window is 1s instead of the default 10s.

## Architecture

`runnerctl` scans `-d DIR` for `*/actions-runner/run.sh` and manages each as a
group. A runner is considered "up" when a `Runner.Listener` process exists whose
command line contains the runner's **absolute** install path (`is_running`) —
this is how runners in different repos are told apart, so never loosen that
match to a bare process name.

- **start** launches each runner detached and niced (see below).
- **status** reports up/down via `is_running`.
- **stop** signals every running runner with `SIGINT` up front, then waits for
  them to exit in one shared grace window (`RUNNERCTL_STOP_GRACE`, default 10s),
  and `SIGKILL`s any straggler. Signalling all first lets graceful shutdowns
  overlap instead of serialising.

## Shell behaviours the launcher depends on

The `start` launch line looks trivial but each part is load-bearing. These were
all real bugs at some point — please don't "simplify" them away without running
the suite (and ideally re-reading this list):

- **Foreground `( … )` subshell, not `$( … )`.** The runner is launched by
  backgrounding the whole `cd "$dir" && nohup … &` compound inside a *foreground*
  subshell. If you wrap it in command substitution `$(…)` (or background a
  *simple* command), Bash sets `SIGINT`/`SIGQUIT` to `SIG_IGN` on the async
  child. The runner inherits that, and a signal ignored at process start
  **cannot be trapped** — so `stop`'s `SIGINT` silently does nothing and every
  runner ends up force-killed. Verify with `/proc/<pid>/status` `SigIgn` (bit 2
  = SIGINT).

- **Launcher stdio redirected to `/dev/null`** (`>/dev/null 2>&1 </dev/null` on
  the subshell). The backgrounded supervisor otherwise keeps the caller's stdout
  open for the runner's entire lifetime, so `runnerctl start | tee log` — or any
  captured output — hangs. The runner's own output still goes to `runner.log`.

- **`runner.pid` written by absolute path** (`"$dir/runner.pid"`). The `cd` only
  takes effect inside the backgrounded child, so a *relative* `runner.pid` would
  be written to the caller's cwd, not next to the runner.

- **Niceness prefix is a string, split on purpose.** `nice_prefix` echoes a
  command prefix (`nice -n 19 ionice -c 3` on Linux, `taskpolicy -b` on macOS)
  that is left **unquoted** so it word-splits into the command (hence the
  `# shellcheck disable=SC2086`). It is deliberately *not* a Bash array: under
  `set -u`, expanding an empty array as `"${arr[@]}"` errors on macOS's Bash 3.2.

## Conventions

- Keep `usage()`'s `sed -n '2,NNp'` range in sync with the header comment block
  if you add/remove lines there.
- Prefer adding a test for any behaviour change; the suite is fast and the bugs
  above were all cheap to catch once tests existed.
- CI runs on `ubuntu-latest` and `macos-latest`. Platform-specific assertions
  (e.g. the exact `nice` value) are guarded by `uname` in the suite.
