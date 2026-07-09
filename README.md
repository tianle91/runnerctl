# runnerctl

Start, stop, and check the status of [self-hosted GitHub Actions runners][gha]
across every repository under a directory — one command instead of `cd`-ing into
each repo and babysitting `run.sh`.

Handy when you host several repos' runners on a single machine (e.g. a Mac
building iOS/macOS apps) and want to bring the whole fleet up or down at once.

## How it works

`runnerctl` scans a directory for runner installs — any `run.sh` at
`<repo>/actions-runner/run.sh` — and manages them as a group:

- **start** launches each runner in the background with `nohup`, so they keep
  listening after the terminal closes. A `runner.log` and `runner.pid` are
  written next to each runner. Starting is re-run safe: a runner that's already
  listening is skipped (matched by its absolute path, so repos never collide).
  By default runners start at the **lowest scheduling priority** so a busy CI
  job never starves your foreground work — on Linux that's `nice -n 19` plus the
  idle I/O class (`ionice -c 3`); on macOS it's `taskpolicy -b`, which throttles
  both CPU and I/O. Pass `--no-nice` to run them at normal priority instead.
- **status** reports which runners are up.
- **stop** sends `SIGINT` to each running listener so it deregisters cleanly,
  then waits for it to actually exit before reporting `stopped`. Runners are
  signalled all at once and share a single grace window (10s by default; set
  `RUNNERCTL_STOP_GRACE` to change it). Any runner that hasn't exited by then is
  force-killed with `SIGKILL`.

## Usage

```
runnerctl [-d DIR] <command>

Commands:
  start     start all runners under DIR
  status    show which runners are up
  stop      stop runners that are up

Options:
  -d DIR     directory to scan for runners (default: current directory)
  --no-nice  run runners at normal priority (default: lowest CPU/I/O priority)
  -h         show help
```

### Examples

```sh
runnerctl start              # scan the current directory
runnerctl -d ~/Github start  # scan a specific directory
runnerctl -d ~/Github status
runnerctl -d ~/Github stop
```

## Install

It's a single dependency-free Bash script. Clone and put it on your `PATH`:

```sh
git clone https://github.com/tianle91/runnerctl.git
ln -s "$PWD/runnerctl/runnerctl" /usr/local/bin/runnerctl
```

Requires Bash and standard Unix tools (`find`, `pgrep`, `pkill`, `nohup`, and
`nice`/`ionice` on Linux or `taskpolicy` on macOS) — present by default on
macOS and Linux.

## Caveats

- **Startup race.** `run.sh` takes a few seconds to become a `Runner.Listener`
  process (it copies templates, may update certs, and can auto-update). The
  "already running" guard is by process match, so launching `start` twice within
  that window can start a duplicate for a repo. In steady state (runners already
  up) re-running `start` is a no-op.
- It manages runners that are **already installed and configured**
  (`config.sh` has been run). It does not register new runners.

## Development

Run the test suite (dependency-free Bash):

```sh
./test/runnerctl.test.sh
```

See [AGENTS.md](AGENTS.md) for the architecture and the subtle shell behaviours
the launcher depends on.

## License

[MIT](LICENSE)

[gha]: https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners
