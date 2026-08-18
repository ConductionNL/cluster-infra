#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/cf-configrule-apply.sh — zet de Configuration Rule die SSL op
# Full (strict) zet voor alles behalve de uitzonderingen.
#
# De zone staat op `flexible` en kan niet zone-breed om: de apex en
# `conduction.openwoo.app` komen uit op een ingress met alleen het fake
# default-certificaat. Deze regel doet het per hostnaam, met een negatieve match
# zodat elke nieuwe klanthostnaam er automatisch onder valt.
#
# Zonder --apply is het een dry-run: hij toont de huidige en de gewenste regel.
# Bestaat er al een regel in de config-fase, dan wordt die bijgewerkt in plaats
# van een tweede ernaast gezet.
#
# Writes: met --apply de ruleset van de zone bij Cloudflare
# Idempotent: yes (gelijke expressie en actie → geen call)
# Requires: curl, python3, CF_API_TOKEN met Zone:Read + Config Rules:Edit
#
# Usage:
#   CF_API_TOKEN=... ./scripts/cf-configrule-apply.sh
#   CF_API_TOKEN=... ./scripts/cf-configrule-apply.sh --apply
#   CF_API_TOKEN=... EXCEPTIONS='openwoo.app www.openwoo.app' ./scripts/cf-configrule-apply.sh --apply

set -euo pipefail

readonly API="${API:-https://api.cloudflare.com/client/v4}"
readonly CF_ZONE="${CF_ZONE:-openwoo.app}"
readonly EXCEPTIONS="${EXCEPTIONS:-openwoo.app www.openwoo.app conduction.openwoo.app}"
readonly SSL_MODE="${SSL_MODE:-strict}"
readonly RULE_NAME="${RULE_NAME:-Full strict, behalve redirect-hosts en conduction}"
readonly TIMEOUT="${TIMEOUT:-20}"

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

die() { echo "fout: $*" >&2; exit 1; }

cf() {
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -sS --max-time "$TIMEOUT" -X "$method" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
      --data "$data" "${API}/${path}"
  else
    curl -sS --max-time "$TIMEOUT" -X "$method" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
      "${API}/${path}"
  fi
}

result() {
  python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
if not d.get('success'):
    print('; '.join(f\"{e.get('code')}: {e.get('message')}\" for e in d.get('errors') or []) or 'onbekende fout',
          file=sys.stderr)
    sys.exit(1)
print(json.dumps(d['result']))
"
}

build_expression() {
  local host first=1 expr=""
  for host in $EXCEPTIONS; do
    if (( first )); then
      expr="(http.host ne \"${host}\")"
      first=0
    else
      expr="${expr} and (http.host ne \"${host}\")"
    fi
  done
  echo "$expr"
}

main() {
  local apply=0
  case "${1:-}" in
    ""|--dry-run) ;;
    --apply) apply=1 ;;
    -h|--help) usage; exit 2 ;;
    *) usage >&2; exit 2 ;;
  esac
  [[ -n "${CF_API_TOKEN:-}" ]] || die "zet CF_API_TOKEN in de omgeving"

  local zone_id
  zone_id="$(cf GET "zones?name=${CF_ZONE}" | result | python3 -c "
import json,sys
z=json.load(sys.stdin)
print(z[0]['id'] if z else '')
")" || die "zone niet op te halen (recht: Zone → Zone: Read)"
  [[ -n "$zone_id" ]] || die "zone ${CF_ZONE} niet gevonden op dit token"

  local want_expr
  want_expr="$(build_expression)"

  local entry
  entry="$(cf GET "zones/${zone_id}/rulesets/phases/http_config_settings/entrypoint" | result)" ||
    die "ruleset niet op te halen (recht: Zone → Config Rules)"

  local ruleset_id rule_id cur_expr cur_ssl
  read -r ruleset_id rule_id cur_ssl <<<"$(python3 -c "
import json,sys
r=json.load(sys.stdin)
rules=r.get('rules') or []
first=rules[0] if rules else {}
print(r.get('id','-'), first.get('id','-'), (first.get('action_parameters') or {}).get('ssl','-'))
" <<<"$entry")"
  cur_expr="$(python3 -c "
import json,sys
r=json.load(sys.stdin)
rules=r.get('rules') or []
print(rules[0].get('expression','') if rules else '')
" <<<"$entry")"

  echo "zone            ${CF_ZONE} (${zone_id})"
  echo "huidige ssl     ${cur_ssl}"
  echo "huidige expr    ${cur_expr:-<geen regel>}"
  echo "gewenste ssl    ${SSL_MODE}"
  echo "gewenste expr   ${want_expr}"

  if [[ "$cur_ssl" == "$SSL_MODE" && "$cur_expr" == "$want_expr" ]]; then
    echo "niets te doen — staat al goed."
    return 0
  fi

  if (( apply == 0 )); then
    echo
    echo "dry-run: niets gewijzigd. Draai met --apply."
    return 0
  fi

  local payload
  payload="$(python3 -c "
import json,sys
print(json.dumps({
  'action': 'set_config',
  'action_parameters': {'ssl': sys.argv[1]},
  'expression': sys.argv[2],
  'description': sys.argv[3],
  'enabled': True,
}))
" "$SSL_MODE" "$want_expr" "$RULE_NAME")"

  if [[ "$rule_id" == "-" ]]; then
    echo "regel aanmaken"
    cf POST "zones/${zone_id}/rulesets/phases/http_config_settings/entrypoint/rules" "$payload" |
      result >/dev/null || die "aanmaken faalde (recht: Config Rules: Edit)"
  else
    echo "regel ${rule_id} bijwerken"
    cf PATCH "zones/${zone_id}/rulesets/${ruleset_id}/rules/${rule_id}" "$payload" |
      result >/dev/null || die "bijwerken faalde (recht: Config Rules: Edit)"
  fi

  echo "klaar — nalezen met: ./scripts/cf-verify.sh"
}

main "$@"
