#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/cf-verify.sh — controleer via de Cloudflare-API of de SaaS-opzet staat
# zoals bedoeld.
#
# Leest vier dingen en velt per stuk een oordeel: de SSL-modus van de zone, het
# fallback-origin-record (bestaat en geproxied), de custom hostnames met hun
# status, en de Configuration Rule die SSL op Full (strict) zet. Read-only; er
# wordt niets gewijzigd.
#
# Het token komt uit de omgeving en wordt nooit geprint. Een mislukte call meldt
# het HTTP-antwoord van Cloudflare, zodat een ontbrekend recht luidruchtig is en
# niet als "OK" wegvalt.
#
# Benodigde rechten op het token (allemaal Read, niets meer):
#   Zone → Zone: Read
#   Zone → Zone Settings: Read
#   Zone → DNS: Read
#   Zone → SSL and Certificates: Read
#   Zone → Config Rules: Read
#
# Writes: read-only
# Idempotent: yes
# Requires: curl, python3, CF_API_TOKEN in de omgeving
#
# Usage:
#   CF_API_TOKEN=... ./scripts/cf-verify.sh
#   CF_API_TOKEN=... CF_ZONE=openwoo.app ./scripts/cf-verify.sh
#   CF_API_TOKEN=... FALLBACK=saas.openwoo.app ./scripts/cf-verify.sh

set -euo pipefail

readonly API="${API:-https://api.cloudflare.com/client/v4}"
readonly CF_ZONE="${CF_ZONE:-openwoo.app}"
readonly FALLBACK="${FALLBACK:-saas.openwoo.app}"
readonly TIMEOUT="${TIMEOUT:-20}"

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

die() { echo "fout: $*" >&2; exit 1; }
verdict() { printf '%-22s %s\n' "$1" "$2"; }

# Alle calls lopen hierlangs, zodat een foutantwoord één keer wordt afgehandeld.
cf() {
  curl -sS --max-time "$TIMEOUT" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API}/$1"
}

# Geeft het data-veld terug, of faalt luidruchtig met de fout van Cloudflare.
cf_result() {
  local path="$1" body
  body="$(cf "$path")" || die "call faalde: $path"
  python3 -c "
import json,sys
d=json.loads(sys.argv[1])
if not d.get('success'):
    errs='; '.join(f\"{e.get('code')}: {e.get('message')}\" for e in d.get('errors') or [])
    print('APIFOUT ' + (errs or 'onbekend'), file=sys.stderr)
    sys.exit(1)
print(json.dumps(d['result']))
" "$body"
}

main() {
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 2; }
  [[ -n "${CF_API_TOKEN:-}" ]] || die "zet CF_API_TOKEN in de omgeving"

  local zone_id
  zone_id="$(cf_result "zones?name=${CF_ZONE}" | python3 -c "
import json,sys
z=json.load(sys.stdin)
print(z[0]['id'] if z else '')
")" || die "zone ${CF_ZONE} niet op te halen (recht: Zone → Zone: Read)"
  [[ -n "$zone_id" ]] || die "zone ${CF_ZONE} niet gevonden op dit token"
  verdict "zone" "${CF_ZONE}"

  local ssl
  if ssl="$(cf_result "zones/${zone_id}/settings/ssl" 2>/dev/null)"; then
    verdict "zone-SSL-modus" "$(python3 -c "
import json,sys
print(json.load(sys.stdin)['value'])
" <<<"$ssl")  (flexible is akkoord mits de Configuration Rule staat)"
  else
    verdict "zone-SSL-modus" "NIET OP TE HALEN (recht: Zone Settings: Read)"
  fi

  local rec
  if rec="$(cf_result "zones/${zone_id}/dns_records?name=${FALLBACK}" 2>/dev/null)"; then
    verdict "fallback origin" "$(python3 -c "
import json,sys
r=json.load(sys.stdin)
if not r:
    print('ONTBREEKT: ${FALLBACK} bestaat niet'); raise SystemExit
x=r[0]
state='geproxied' if x.get('proxied') else 'NIET GEPROXIED — zo werkt het niet'
print(f\"{x['type']} {x['content']}, {state}\")
" <<<"$rec")"
  else
    verdict "fallback origin" "NIET OP TE HALEN (recht: DNS: Read)"
  fi

  local hosts
  if hosts="$(cf_result "zones/${zone_id}/custom_hostnames?per_page=50" 2>/dev/null)"; then
    python3 -c "
import json,sys
h=json.load(sys.stdin)
if not h:
    print('custom hostnames    GEEN')
for x in h:
    ssl=x.get('ssl') or {}
    print(f\"  {x['hostname']:34s} {x.get('status','?'):22s} cert={ssl.get('status','?')} via={ssl.get('validation_method','?')}\")
" <<<"$hosts"
  else
    verdict "custom hostnames" "NIET OP TE HALEN (recht: SSL and Certificates: Read)"
  fi

  local rules
  if rules="$(cf_result "zones/${zone_id}/rulesets/phases/http_config_settings/entrypoint" 2>/dev/null)"; then
    python3 -c "
import json,sys
r=json.load(sys.stdin)
rs=r.get('rules') or []
if not rs:
    print('config-rules        GEEN — dan valt alles terug op de zone-modus')
for x in rs:
    ssl=(x.get('action_parameters') or {}).get('ssl','(geen ssl-actie)')
    on='actief' if x.get('enabled') else 'UIT'
    print(f\"config-rule         {on}, ssl={ssl}\")
    print(f\"  expressie: {x.get('expression')}\")
" <<<"$rules"
  else
    verdict "config-rules" "NIET OP TE HALEN (recht: Config Rules: Read)"
  fi
}

main "$@"
