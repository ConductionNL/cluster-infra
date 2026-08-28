#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/check-saas-hostname.sh — verifieer een Cloudflare-for-SaaS custom
# hostname van een klantdomein.
#
# Test B uit het IPv6-onderzoek. Controleert per host: CNAME naar ons target,
# AAAA aan de edge, bereikbaarheid over IPv6, wie het certificaat uitgaf, de
# sleutelsoort, of onze security-headers door de proxy komen, en de twee records
# die de klant moet zetten (DCV-delegatie en CAA). Meet alleen; wijzigt niets.
#
# Vóór cutover kun je de edge al testen met EDGE_IP: dan wordt de hostnaam
# geforceerd naar dat Cloudflare-adres opgelost in plaats van via DNS.
#
# TARGET is de fallback origin waar de klant-CNAME heen moet wijzen; de default
# `saas.openwoo.app` is wat er sinds 2026-08-18 staat. Wijkt die naam ooit af,
# zet TARGET dan mee — anders is het "verwacht"-oordeel misleidend.
#
# Writes: read-only
# Idempotent: yes
# Requires: dig, curl, openssl
#
# Usage:
#   ./scripts/check-saas-hostname.sh open.dinkelland.nl
#   TARGET=customers.openwoo.app ./scripts/check-saas-hostname.sh open.dinkelland.nl   # ander doel
#   EDGE_IP=104.21.60.114 ./scripts/check-saas-hostname.sh open.dinkelland.nl

set -euo pipefail

readonly TARGET="${TARGET:-saas.openwoo.app}"
readonly EDGE_IP="${EDGE_IP:-}"
readonly TIMEOUT="${TIMEOUT:-15}"
readonly HEADERS='content-security-policy|x-frame-options|referrer-policy|strict-transport-security|x-content-type-options'

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

fetch() {
  local host="$1"
  if [[ -n "$EDGE_IP" ]]; then
    curl -sSI --max-time "$TIMEOUT" --resolve "${host}:443:${EDGE_IP}" "https://${host}/" 2>/dev/null
  else
    curl -sSI --max-time "$TIMEOUT" "https://${host}/" 2>/dev/null
  fi
}

line() { printf '%-14s %s\n' "$1" "${2:-<geen>}"; }

check_dns() {
  local host="$1"
  line "CNAME" "$(dig +short "$host" CNAME | tr '\n' ' ')"
  line "A" "$(dig +short "$host" A | tr '\n' ' ')"
  line "AAAA" "$(dig +short "$host" AAAA | tr '\n' ' ')"
  line "verwacht" "CNAME → ${TARGET}"
  line "DCV-CNAME" "$(dig +short "_acme-challenge.${host}" CNAME | tr '\n' ' ')"
  line "CAA" "$(dig +short "$host" CAA | tr '\n' ' ')"
}

check_edge() {
  local host="$1" head
  head="$(fetch "$host")"
  [[ -z "$head" ]] && { line "HTTPS" "GEEN ANTWOORD"; return 1; }

  line "status" "$(printf '%s' "$head" | head -1 | tr -d '\r')"
  line "server" "$(printf '%s' "$head" | tr -d '\r' | awk 'tolower($1)=="server:"{print $2}')"
  line "headers" "$(printf '%s' "$head" | tr -d '\r' |
    grep -icE "^(${HEADERS}):") van 5 aanwezig"

  if [[ -z "$EDGE_IP" ]] && [[ -n "$(dig +short "$host" AAAA)" ]]; then
    if curl -6 -sS -o /dev/null --max-time "$TIMEOUT" "https://${host}/"; then
      line "over IPv6" "OK"
    else
      line "over IPv6" "FAALT"
    fi
  fi
}

check_cert() {
  local host="$1"
  local connect="${host}:443" cert
  [[ -n "$EDGE_IP" ]] && connect="${EDGE_IP}:443"
  cert="$(echo | timeout "$TIMEOUT" openssl s_client -connect "$connect" \
    -servername "$host" 2>/dev/null | openssl x509 -noout -issuer -dates -text 2>/dev/null || true)"
  [[ -z "$cert" ]] && { line "cert" "niet op te halen"; return 1; }

  line "cert-issuer" "$(printf '%s' "$cert" | sed -n 's/^issuer=//p')"
  line "cert-sleutel" "$(printf '%s' "$cert" | grep -m1 -E 'Public-Key|id-ecPublicKey' | tr -s ' ')"
  line "cert-tot" "$(printf '%s' "$cert" | sed -n 's/^notAfter=//p')"
}

main() {
  local host="${1:-}"
  [[ -z "$host" || "$host" == "-h" || "$host" == "--help" ]] && { usage; exit 2; }

  echo "== DNS =="
  check_dns "$host"
  echo "== edge =="
  check_edge "$host" || true
  echo "== certificaat =="
  check_cert "$host" || true
}

main "$@"
