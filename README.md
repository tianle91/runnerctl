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
- **status** reports which runners are up.
- **stop** sends `SIGINT` to each running listener so it deregisters cleanly.

## Usage

```
runnerctl [-d DIR] <command>

Commands:
  start     start all runners under DIR
  status    show which runners are up
  stop      stop runners that are up

Options:
  -d DIR    directory to scan for runners (default: current directory)
  -h        show help
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

Requires Bash and standard Unix tools (`find`, `pgrep`, `pkill`, `nohup`) —
present by default on macOS and Linux.

## Caveats

- **Startup race.** `run.sh` takes a few seconds to become a `Runner.Listener`
  process (it copies templates, may update certs, and can auto-update). The
  "already running" guard is by process match, so launching `start` twice within
  that window can start a duplicate for a repo. In steady state (runners already
  up) re-running `start` is a no-op.
- It manages runners that are **already installed and configured**
  (`config.sh` has been run). It does not register new runners.

## License

[MIT](LICENSE)

[gha]: https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners
