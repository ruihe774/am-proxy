#!/usr/bin/env bash
# Least-privilege launcher for am-proxy.ts.
#
# Derives Deno's permission flags from the proxy's own environment:
#   inbound network  = HOST:PORT
#   outbound network = ANTHROPIC_BASE_URL's host and effective port
#
# Usage is identical to running the proxy directly:
#   HOST=127.0.0.1 PORT=8787 \
#   ANTHROPIC_BASE_URL=https://api.anthropic.com \
#   ANTHROPIC_AUTH_TOKEN=sk-ant-... \
#   ./am-proxy.sh

set -euo pipefail

die() {
  printf 'am-proxy: %s\n' "$*" >&2
  exit 1
}

trim() {
  local value=$1
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# Make unset variables safe to inspect with indirect expansion.
HOST=${HOST-}
PORT=${PORT-}
ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL-}
ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN-}

missing=()
for name in HOST PORT ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN; do
  if [[ -z "$(trim "${!name}")" ]]; then
    missing+=("$name")
  fi
done
if ((${#missing[@]} > 0)); then
  die "refusing to start; missing required environment variable(s): ${missing[*]}"
fi

HOST=$(trim "$HOST")
PORT=$(trim "$PORT")
ANTHROPIC_BASE_URL=$(trim "$ANTHROPIC_BASE_URL")
ANTHROPIC_AUTH_TOKEN=$(trim "$ANTHROPIC_AUTH_TOKEN")
export HOST PORT ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN

# --- PORT ---------------------------------------------------------------
[[ $PORT =~ ^[0-9]+$ ]] ||
  die "PORT must be an integer between 0 and 65535 (got '$PORT')"
port_number=${PORT#"${PORT%%[!0]*}"}
port_number=${port_number:-0}
((${#port_number} <= 5)) ||
  die "PORT must be an integer between 0 and 65535 (got '$PORT')"
((10#$port_number <= 65535)) ||
  die "PORT must be an integer between 0 and 65535 (got '$PORT')"
PORT=$port_number
export PORT

# --- HOST -> inbound permission ----------------------------------------
if [[ $HOST =~ ^\[[^]]+\]:[0-9]+$ ]]; then
  die "HOST must not include a port; set HOST and PORT separately (got '$HOST')"
fi
if [[ $HOST == *\]* && ! $HOST =~ ^\[[^]]+\]$ ]]; then
  die "HOST must be a bare hostname or address (got '$HOST')"
fi
if [[ $HOST == *[[:space:]]* || $HOST == */* || $HOST == *\?* ||
  $HOST == *\#* || $HOST == *@* || $HOST == *\\* ]]; then
  die "HOST contains characters that are not valid in a hostname (got '$HOST')"
fi

if [[ $HOST == \[*\] ]]; then
  listen_net="$HOST:$PORT"
elif [[ $HOST == *:* ]]; then
  # A bare IPv6 literal needs brackets in Deno's permission syntax. A single
  # colon is not a valid IPv6 address, so it is almost certainly host:port.
  colon_count=${HOST//[^:]/}
  if ((${#colon_count} < 2)); then
    die "HOST must not include a port; set HOST and PORT separately (got '$HOST')"
  fi
  listen_net="[$HOST]:$PORT"
else
  listen_net="$HOST:$PORT"
fi

# --- ANTHROPIC_BASE_URL -> outbound permission --------------------------
if [[ $ANTHROPIC_BASE_URL == *"?"* || $ANTHROPIC_BASE_URL == *"#"* ]]; then
  die "ANTHROPIC_BASE_URL must not contain a query string or fragment"
fi

lower_url=${ANTHROPIC_BASE_URL,,}
[[ $lower_url =~ ^(https?):// ]] ||
  die "ANTHROPIC_BASE_URL must be an absolute http(s) URL (got '$ANTHROPIC_BASE_URL')"
scheme=${BASH_REMATCH[1]}

rest=${ANTHROPIC_BASE_URL#*://}
authority=${rest%%/*}
[[ -n $authority ]] || die "ANTHROPIC_BASE_URL has no host"
[[ $authority != *@* ]] ||
  die "ANTHROPIC_BASE_URL must not contain credentials"

if [[ $authority =~ ^\[([^]]+)\](:([0-9]*))?$ ]]; then
  upstream_host=${BASH_REMATCH[1]}
  upstream_port=${BASH_REMATCH[3]}
  is_ipv6=1
elif [[ $authority =~ ^([^:]+)(:([0-9]*))?$ ]]; then
  upstream_host=${BASH_REMATCH[1]}
  upstream_port=${BASH_REMATCH[3]}
  is_ipv6=0
else
  die "ANTHROPIC_BASE_URL has an invalid host:port (got '$authority')"
fi

[[ -n $upstream_host ]] || die "ANTHROPIC_BASE_URL has an empty host"
if [[ $upstream_host == *[[:space:]]* || $upstream_host == *%* ||
  $upstream_host == *[!\ -~]* || $upstream_host == *\\* ]]; then
  die "ANTHROPIC_BASE_URL host must be a plain ASCII hostname or IP literal (got '$upstream_host')"
fi

if [[ -z $upstream_port ]]; then
  case $scheme in
    https) upstream_port=443 ;;
    http) upstream_port=80 ;;
  esac
else
  [[ $upstream_port =~ ^[0-9]+$ ]] ||
    die "ANTHROPIC_BASE_URL has an invalid port (got '$upstream_port')"
  normalized_port=${upstream_port#"${upstream_port%%[!0]*}"}
  normalized_port=${normalized_port:-0}
  ((${#normalized_port} <= 5)) ||
    die "ANTHROPIC_BASE_URL port must be between 0 and 65535 (got '$upstream_port')"
  ((10#$normalized_port <= 65535)) ||
    die "ANTHROPIC_BASE_URL port must be between 0 and 65535 (got '$upstream_port')"
  upstream_port=$normalized_port
fi

upstream_host=${upstream_host,,}
if ((is_ipv6)); then
  upstream_net="[$upstream_host]:$upstream_port"
else
  upstream_net="$upstream_host:$upstream_port"
fi

if [[ $listen_net == "$upstream_net" ]]; then
  net_allow=$listen_net
else
  net_allow="$listen_net,$upstream_net"
fi

# --- launch -------------------------------------------------------------
deno_bin=$(type -P deno) || die "deno was not found in PATH"

source_path=${BASH_SOURCE[0]}
if resolved=$(readlink -f -- "$source_path" 2>/dev/null); then
  source_path=$resolved
fi
case $source_path in
  */*) script_dir=${source_path%/*} ;;
  *) script_dir=. ;;
esac
script_dir=$(cd -- "$script_dir" && pwd -P) ||
  die "cannot resolve the directory containing this script"
proxy_path="$script_dir/am-proxy.ts"
[[ -f $proxy_path ]] || die "cannot find $proxy_path"

exec "$deno_bin" run \
  --no-prompt \
  "--allow-net=$net_allow" \
  "--allow-env=HOST,PORT,ANTHROPIC_BASE_URL,ANTHROPIC_AUTH_TOKEN" \
  "$proxy_path" "$@"
