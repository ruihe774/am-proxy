# am-proxy
A minimal proxy for Anthropic-compatible Messages API with credential control and logging, implemented in Deno with minimal permissions

## What it does

- Forwards every request to an upstream Anthropic-compatible API.
- Replaces any client-supplied `Authorization` / `x-api-key` header with the
  proxy's own `ANTHROPIC_AUTH_TOKEN`, so clients never need the real credential.
- Logs every request and response (headers and bodies) to **stdout** as one JSON
  object per line (JSONL). Credential-bearing headers are redacted in the log.
  Diagnostics and errors go to **stderr**, so stdout stays pure JSONL.

## Requirements

- [Deno](https://deno.com/)
- Bash (only for the `am-proxy.sh` launcher)

## Configuration

All variables are required; the proxy refuses to start if any is missing.

| Variable               | Description                                                        |
| ---------------------- | ------------------------------------------------------------------ |
| `HOST`                 | Hostname/address to listen on (e.g. `127.0.0.1`)                   |
| `PORT`                 | TCP port to listen on                                              |
| `ANTHROPIC_BASE_URL`   | Upstream base URL (e.g. `https://api.anthropic.com`)               |
| `ANTHROPIC_AUTH_TOKEN` | Token sent upstream as `Authorization: Bearer <token>`             |

## Usage

### Recommended: `am-proxy.sh`

The launcher derives least-privilege Deno flags from the environment: network
access is limited to `HOST:PORT` (inbound) and the host/port of
`ANTHROPIC_BASE_URL` (outbound), and env access to the four variables above.

```sh
HOST=127.0.0.1 PORT=8787 \
ANTHROPIC_BASE_URL=https://api.anthropic.com \
ANTHROPIC_AUTH_TOKEN=sk-ant-... \
./am-proxy.sh > requests.jsonl
```

### Directly with Deno

```sh
HOST=127.0.0.1 PORT=8787 \
ANTHROPIC_BASE_URL=https://api.anthropic.com \
ANTHROPIC_AUTH_TOKEN=sk-ant-... \
deno run --allow-net --allow-env am-proxy.ts > requests.jsonl
```

(This grants broader permissions than the launcher.)

### Pointing a client at the proxy

For example, Claude Code:

```sh
ANTHROPIC_BASE_URL=http://127.0.0.1:8787 \
ANTHROPIC_AUTH_TOKEN=anything \
claude
```

The client's token is ignored; the proxy injects its own.

### Installing on your PATH (optional)

Keep `am-proxy.sh` and `am-proxy.ts` together (the launcher resolves symlinks to
find the `.ts` file):

```sh
ln -s "$PWD/am-proxy.sh" ~/.local/bin/am-proxy
```

## Security and limitations

am-proxy assumes trusted clients and a well-behaved upstream.

- **No client authentication.** Anyone who can reach the listening address can
  use the proxy's `ANTHROPIC_AUTH_TOKEN`. Bind to a loopback address (the
  default in the examples) or restrict access at the network level; do not
  expose it to untrusted networks.
- **No size limits.** Request bodies are buffered in memory, and every response
  is retained in full until it is logged, including long streams. Memory use
  therefore scales with the largest request/response, which is fine for
  ordinary Messages API traffic but unsuitable for untrusted or abusive clients.
- **Logs contain full bodies.** Only credential headers are redacted; prompts,
  completions, and any sensitive data inside them are written to stdout as-is.
  Treat the log file accordingly.

## Logs

Pipe stdout to a file and inspect with `jq`:

```sh
./am-proxy.sh > requests.jsonl
jq . requests.jsonl
```

## License

See [LICENSE](LICENSE).
