# gauge

*A little fuel gauge for your Claude usage — in your terminal, or in your waybar.*

It reads the same 5-hour and 7-day rate-limit windows as Claude Code's
`/usage`, and prints them small enough to leave running somewhere:

```
5h 12% · wk 41%
```

## Get it

Needs [Zig](https://ziglang.org/download/) and a logged-in Claude Code.

```bash
git clone https://github.com/moesy/gauge
cd gauge
zig build -Doptimize=ReleaseSafe
install -m755 zig-out/bin/gauge ~/.local/bin/
gauge
```

## Put it in your waybar

```bash
gauge setup-waybar
```

![gauge's waybar module reading: ✱ 5h 25% · wk 45%](docs/screenshot.png)

One command. It backs up your config, refuses if it doesn't recognize the
shape, and is safe to re-run. The module goes yellow at 70%, red at 90%, and
dims when the data is stale. Reload waybar and you're done.

## The fine print

gauge talks to an endpoint Anthropic **hasn't published**. It's unsupported,
rate-limited, and can change shape or vanish without warning — so gauge never
hits it more than it has to. Every read goes through a local cache with a TTL
and a backoff ladder (5 → 10 → 20 → 30 min on repeated failure). A waybar
refreshing every 30s does **not** mean a request every 30s. Please don't build
anything that bypasses the cache and hammers it.

When a fetch fails, gauge keeps showing the last good number — marked stale —
instead of breaking. It reads your OAuth token read-only and never refreshes
it; if it's expired, run `claude` and gauge catches up on its own.

<details>
<summary><b>Usage, flags & env vars</b></summary>

```
gauge [waybar|json|setup-waybar] [flags]
```

| command | what it prints |
|---|---|
| *(none)* | human-readable text for a terminal |
| `waybar` | one line of JSON for waybar's custom module |
| `json` | the raw cached state, unformatted |
| `setup-waybar` | wires the waybar module in for you |

Flags: `--force` (refresh now, ignore backoff) · `--offline` (serve cache only)
· `--max-age <secs>` (cache TTL, default 180) · `--version` · `--help`.

Env: `GAUGE_STATE_DIR`, `GAUGE_CREDENTIALS`, `GAUGE_USER_AGENT`,
`GAUGE_WAYBAR_DIR`. Run `gauge --help` for their defaults.

Builds against a Zig dev snapshot (`0.17.0-dev.704+b8cb78023` or newer).
`zig build test` runs the suite.

</details>

<details>
<summary><b>Wiring waybar by hand</b></summary>

If you'd rather not run `setup-waybar`, add `"custom/gauge"` to a modules list
and merge in:

```jsonc
"custom/gauge": {
    "exec": "gauge waybar",
    "return-type": "json",
    "interval": 30,
    "tooltip": true,
    "format": "✱ {}"
}
```

Then style its states:

```css
#custom-gauge { padding: 0 8px; }
#custom-gauge.warn { color: #e5c07b; }
#custom-gauge.critical { color: #e06c75; }
#custom-gauge.stale { opacity: 0.6; }
```

</details>

## License

MIT. See [LICENSE](./LICENSE).
