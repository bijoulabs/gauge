# Security

gauge reads the OAuth access token from your Claude Code credentials file
(`~/.claude/.credentials.json` by default). What it does with it, in full:

- **Read-only.** gauge never writes to the credentials file and never
  refreshes the token. If the token expires, gauge reports an auth error and
  waits for the `claude` CLI to refresh it.
- **One destination.** The token is sent only in the `Authorization` header
  of HTTPS requests to `api.anthropic.com`, and nowhere else.
- **Never persisted or logged.** The token is not written to the state file,
  the cache, or any output mode. The cached state holds only utilization
  percentages and reset timestamps.
- **Bounded reads.** The credentials file is read with an explicit 1 MiB
  size cap, and the API response with its own cap, so a hostile file or
  response cannot balloon memory.

To report a vulnerability, email moe@sy.dev rather than opening a public
issue.
