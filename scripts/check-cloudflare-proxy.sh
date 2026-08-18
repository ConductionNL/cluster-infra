#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/check-cloudflare-proxy.sh — meet of een host via de Cloudflare-proxy
# loopt en of dat IPv6 oplevert.
#
# Test A uit het IPv6-onderzoek: zet in het portaal de proxy-vlag op één van
# onze eigen hosts en draai dit script vóór en ná. Het meet alleen; het wijzigt
# niets. Met --watch <sec> herhaalt het, zodat je ziet of external-dns de
# proxy-vlag terugdraait (policy sync, interval 1m).
#
# Writes: read-only
# Idempotent: yes
# Requires: dig, curl, openssl
#
# Usage:
#   ./scripts/check-cloudflare-proxy.sh canary.openwoo.app
#   ./scripts/check-cloudflare-proxy.sh canary.openwoo.app --watch 180
#   ORIGIN_IP=81.24.6.82 ./scripts/check-cloudflare-proxy.sh canary.openwoo.app

set -euo pipefail

readonly ORIGIN_IP="${ORIGIN_IP:-81.24.6.82}"
readonly TIMEOUT="${TIMEOUT:-15}"

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

# Geproxied of niet is af te leiden uit het A-record: onze LB of Cloudflare.
probe() {
  local host="$1"
  local a aaaa server proxied

  a="$(dig +short "$host" A | tr '\n' ' ')"
  aaaa="$(dig +short "$host" AAAA | tr '\n' ' ')"

  if [[ "$a" == *"$ORIGIN_IP"* ]]; then
    proxied="nee (wijst naar onze LB)"
  elif [[ -n "$a" ]]; then
    proxied="ja (wijst niet naar onze LB)"
  else
    proxied="onbekend (geen A-record)"
  fi

  server="$(curl -sSI --max-time "$TIMEOUT" "https://${host}/" 2>/dev/null |
    tr -d '\r' | awk 'tolower($1)=="server:"{print $2}')"

  printf 'host        %s\n' "$host"
  printf 'A           %s\n' "${a:-<geen>}"
  printf 'AAAA        %s\n' "${aaaa:-<geen>}"
  printf 'geproxied   %s\n' "$proxied"
  printf 'server      %s\n' "${server:-<geen antwoord>}"

  if [[ -n "$aaaa" ]]; then
    if curl -6 -sS -o /dev/null --max-time "$TIMEOUT" "https://${host}/" 2>/dev/null; then
      printf 'over IPv6   OK\n'
    else
      printf 'over IPv6   FAALT (AAAA staat er, verbinding lukt niet)\n'
    fi
  else
    printf 'over IPv6   n.v.t. (geen AAAA)\n'
  fi

  printf 'cert        %s\n' "$(echo | timeout "$TIMEOUT" openssl s_client \
    -connect "${host}:443" -servername "$host" 2>/dev/null |
    openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//' || echo '<niet op te halen>')"
}

main() {
  local host="${1:-}" watch=0
  [[ -z "$host" || "$host" == "-h" || "$host" == "--help" ]] && { usage; exit 2; }
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --watch) watch="${2:?--watch vereist seconden}"; shift 2 ;;
      *) echo "onbekend argument: $1" >&2; usage >&2; exit 2 ;;
    esac
  done

  probe "$host"

  if (( watch > 0 )); then
    local deadline=$((SECONDS + watch))
    while (( SECONDS < deadline )); do
      sleep 30
      echo "---"
      probe "$host"
    done
  fi
}

main "$@"
