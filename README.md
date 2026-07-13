# gauge

A small command line tool that shows how much of your Claude usage window
you have used, for a terminal or for a waybar status bar. It reads the same
underlying data as Claude Code's `/usage` command: the 5 hour and 7 day
rate-limit windows tied to your account.

## Quick start

With [Zig](https://ziglang.org/download/) installed and Claude Code logged in:

```bash
git clone https://github.com/moesy/gauge
cd gauge
zig build -Doptimize=ReleaseSafe
install -m755 zig-out/bin/gauge ~/.local/bin/
gauge
```

That builds the binary, installs it to `~/.local/bin`, and prints your
current usage. `gauge setup-waybar` wires the waybar module.

## Disclaimer

gauge talks to an endpoint Anthropic has not published or documented. It is
not a supported integration, it is rate-limited, and it can change shape or
disappear without notice. Because of that, gauge never polls it directly on
your behalf: every read goes through a local cache with a time to live and a
backoff ladder, so a waybar module refreshing every 30 seconds does not
translate into a request every 30 seconds. Do not build anything that
bypasses the cache and hits the endpoint on a tight loop.

The response gauge parses looks like this, trimmed to the fields it reads:

```json
{
  "five_hour": { "utilization": 3.0, "resets_at": "2026-07-13T07:00:00.402134+00:00" },
  "seven_day": { "utilization": 41.0, "resets_at": "2026-07-15T16:00:00.402156+00:00" }
}
```

`utilization` is a percentage from 0 to 100, not a 0 to 1 ratio, and
`resets_at` is an ISO 8601 timestamp. gauge probes a short list of candidate
field names for both, so a minor rename on Anthropic's side degrades to
stale cached data instead of a crash.

## Requirements

- Zig `0.17.0-dev.704+b8cb78023` or newer (this is a development snapshot of
  Zig, not a tagged release; see [ziglang.org/download](https://ziglang.org/download/)
  for how to get one).
- A machine with a logged-in Claude Code CLI, since gauge reads its OAuth
  credentials.

## Build and install

```bash
zig build -Doptimize=ReleaseSafe
install -m755 zig-out/bin/gauge ~/.local/bin/
```

Run the test suite with:

```bash
zig build test
```

## Usage

```
gauge [waybar|json|setup-waybar] [--force] [--offline] [--max-age <secs>] [--version] [--help]
```

Four subcommands, selected by the first positional argument:

- (default) human readable text for a terminal.
- `waybar` a single line of JSON matching waybar's custom module contract.
- `json` the raw cached state as JSON, with no formatting applied.
- `setup-waybar` wires the waybar module in automatically; see
  [Waybar setup](#waybar-setup). Ignores `--force`, `--offline`, and
  `--max-age`.

Flags:

- `--force` refresh from upstream even if the cache is fresh or backing off.
- `--offline` never contact upstream, serve only what is cached.
- `--max-age <secs>` cache time to live in seconds, default 180.
- `--version` print the version and exit.
- `--help` print usage and exit.

Environment variables:

- `GAUGE_STATE_DIR` where the cache file lives. Defaults to
  `$XDG_STATE_HOME/gauge`, or `$HOME/.local/state/gauge` if `XDG_STATE_HOME`
  is unset.
- `GAUGE_CREDENTIALS` path to the credentials file to read. Defaults to
  `$HOME/.claude/.credentials.json`, the file Claude Code itself writes.
- `GAUGE_USER_AGENT` overrides the `User-Agent` header sent with the usage
  request.
- `GAUGE_WAYBAR_DIR` waybar config directory used by `setup-waybar`.
  Defaults to `$HOME/.config/waybar`.

## Waybar setup

![gauge in waybar](docs/screenshot.png)

Install gauge, then run:

```bash
gauge setup-waybar
```

It backs up both files first and refuses, printing manual steps, if your
config does not look like it expects. Reload waybar afterward (`pkill
waybar; waybar &`, or your compositor's restart mechanism), and the module
should show usage as `5h NN% · wk NN%` with a tooltip on hover.

The class turns `warn` at 70% utilization and `critical` at 90%, based on
whichever of the two windows is higher; `stale` replaces the class when data
is old or the last fetch failed.

Run it again any time; it is idempotent, a config that already has the
module is left untouched and reported as already set up.

### Manual setup

If you would rather wire it in by hand, or `setup-waybar` refused because
your config does not match a stock shape, add `"custom/gauge"` to a modules
list in your waybar config and merge in:

```jsonc
"custom/gauge": {
    "exec": "gauge waybar",
    "return-type": "json",
    "interval": 30,
    "tooltip": true,
    "format": "✱ {}"
}
```

Style the module's states in your waybar CSS:

```css
#custom-gauge { padding: 0 8px; }
#custom-gauge.warn { color: #e5c07b; }
#custom-gauge.critical { color: #e06c75; }
#custom-gauge.stale { opacity: 0.6; }
```

Reload waybar after wiring both in.

## Failure behavior

gauge is built to degrade rather than break. A few rules govern that:

- **Stale serving.** If a refresh fails for any reason, gauge keeps
  serving the last successful snapshot rather than an error or a blank
  gauge. Once that cached snapshot is old enough or its last fetch failed,
  it is marked stale (the waybar `stale` CSS class, or a `(stale)` suffix in
  human output), but it is still shown.
- **Backoff ladder.** A failed refresh schedules the next attempt further
  out: 5, 10, 20, then 30 minutes, escalating on each consecutive failure
  and capping at 30 minutes so a persistent outage never grows the delay
  without bound. `--force` bypasses backoff for a manual retry.
- **No token refresh.** gauge reads the OAuth access token from your Claude
  Code credentials file and never writes to it or refreshes it. If the
  token has expired, gauge reports an auth error and backs off; run
  `claude` normally to refresh it.

Internally, the cache has a time to live of 180 seconds by default
(`--max-age` overrides it), and concurrent invocations coordinate through a
lock file (`state.lock` in the state directory) so two processes racing a
refresh at the same moment do not both hit the network: the one that loses
the lock just serves whatever is cached. Writes to the state file are
atomic, a temp file written and renamed into place, so a reader never sees a
partially written cache.

Exit codes: `0` whenever a state renders, which for waybar mode is always
true (there is no first-run state where waybar shows nothing), and `2` for
a bad command line or, in the non-waybar modes, for a first run with no
cached data and no successful fetch yet.

## License

MIT. See [LICENSE](./LICENSE).
