#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/cf-revalidate.sh — tik een Cloudflare custom hostname aan zodat de
# eigendomsvalidatie opnieuw wordt beoordeeld.
#
# Een custom hostname die op `moved` (of `pending`) blijft staan terwijl alle
# records bij de klant kloppen, wordt door Cloudflare niet vanzelf opnieuw
# gevalideerd. De edge geeft dan HTTP 409 en de site ligt eruit, ook al staat het
# certificaat op `active`. Zie docs/cloudflare-ipv6.md § Hostname-activatie.
#
# Dit script leest de bestaande ssl-config van de hostname en stuurt precies die
# terug. Dat is de hele truc: de PATCH zelf is de trigger, de inhoud verandert
# niets. Het script verzint dus nooit een `method` — een andere DCV-methode zou
# de certificaatroute van een werkend certificaat verleggen.
#
# Weigert te werken als de hostname al `active` is (dan is er niets te
# hervalideren) en als de records bij de klant nog niet staan (dan is de PATCH
# zinloos en hoort de klantmail eerst af — docs/mail-ipv6-klant.md).
#
# Writes: één PATCH op de custom hostname. Geen DNS, geen certificaataanvraag,
#         geen verkeersverschuiving.
# Idempotent: yes (zelfde body, zelfde eindtoestand)
# Requires: curl, python3, dig, CF_API_TOKEN met Zone -> SSL and Certificates: Edit
#
# Usage:
#   CF_API_TOKEN=... ./scripts/cf-revalidate.sh open.dinkelland.nl
#   CF_API_TOKEN=... ./scripts/cf-revalidate.sh open.tubbergen.nl --force
#   CF_API_TOKEN=... CF_ZONE=openwoo.app ./scripts/cf-revalidate.sh <hostnaam>
#   CF_API_TOKEN=... ./scripts/cf-revalidate.sh <hostnaam> --dry-run
#
# --force  ook aantikken als de site-CNAME nog niet staat (pre-validatie vóór de
#          cut-over). Ongemeten pad: zie de note-block in cloudflare-ipv6.md.
# --dry-run  lees alleen uit en druk af wat er gestuurd zou worden.

set -euo pipefail

readonly API="${API:-https://api.cloudflare.com/client/v4}"
readonly CF_ZONE="${CF_ZONE:-openwoo.app}"
readonly FALLBACK="${FALLBACK:-saas.openwoo.app}"
readonly TIMEOUT="${TIMEOUT:-20}"

die() { echo "fout: $*" >&2; exit 1; }

cf() {
  curl -sS --max-time "$TIMEOUT" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" "$@"
}

# Geeft het data-veld terug, of faalt met de fout van Cloudflare zelf.
cf_result() {
  local body
  body="$(cf "$@")" || die "call faalde"
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
if not d.get("success"):
    errs = "; ".join("%s: %s" % (e.get("code"), e.get("message")) for e in d.get("errors") or [])
    print("APIFOUT " + (errs or "onbekend"), file=sys.stderr)
    raise SystemExit(1)
print(json.dumps(d["result"]))
' "$body"
}

main() {
  local host="" force=0 dry=0
  while (( $# )); do
    case "$1" in
      --force) force=1 ;;
      --dry-run) dry=1 ;;
      -h|--help) sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      -*) die "onbekende optie: $1" ;;
      *) host="$1" ;;
    esac
    shift
  done

  [[ -n "$host" ]] || die "geef een hostnaam op; zie --help"
  : "${CF_API_TOKEN:?zet CF_API_TOKEN in de omgeving (SSL and Certificates: Edit)}"

  local zone_id
  zone_id="$(cf_result "${API}/zones?name=${CF_ZONE}" |
    python3 -c 'import json,sys; z=json.load(sys.stdin); print(z[0]["id"] if z else "")')"
  [[ -n "$zone_id" ]] || die "zone ${CF_ZONE} niet gevonden (recht: Zone: Read)"

  local hosts
  hosts="$(cf_result "${API}/zones/${zone_id}/custom_hostnames?per_page=50")" ||
    die "custom hostnames niet op te halen (recht: SSL and Certificates: Read)"

  # Haal id en de bestaande ssl-config op; die sturen we straks terug.
  local found
  found="$(python3 -c '
import json, sys
host = sys.argv[1]
for x in json.load(sys.stdin):
    if x["hostname"] == host:
        s = x.get("ssl") or {}
        body = {"ssl": {"method": s.get("method"), "type": s.get("type"),
                        "wildcard": bool(s.get("wildcard"))}}
        print(json.dumps({"id": x["id"], "status": x.get("status"),
                          "cert": s.get("status"), "body": body}))
        break
else:
    raise SystemExit(1)
' "$host" <<<"$hosts")" || die "geen custom hostname ${host} in zone ${CF_ZONE}"

  local id status cert body
  id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$found")"
  status="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["status"])' "$found")"
  cert="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["cert"])' "$found")"
  body="$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["body"]))' "$found")"

  echo "hostname   ${host}"
  echo "id         ${id}"
  echo "status     ${status} (cert: ${cert})"

  [[ "$status" == "active" ]] &&
    { echo "eigendom is al bevestigd; hier is niets te hervalideren"; exit 0; }

  # Zonder eigendomsrecord bij de klant heeft aantikken geen zin.
  local txt
  txt="$(dig +short TXT "_cf-custom-hostname.${host}" | tr -d '"' | head -1)"
  [[ -n "$txt" ]] ||
    die "geen _cf-custom-hostname.${host} TXT in DNS; eerst de klantmail afmaken (docs/mail-ipv6-klant.md)"

  # De site-CNAME is de toestand waarin dit bewezen werkt (2026-08-31, dinkelland).
  local cname
  cname="$(dig +short CNAME "$host" | sed 's/\.$//' | head -1)"
  if [[ "$cname" != "$FALLBACK" && "$force" -eq 0 ]]; then
    die "site-CNAME staat niet op ${FALLBACK} (nu: ${cname:-geen}); pre-validatie vóór de cut-over is ongemeten — gebruik --force als je dat bewust test"
  fi

  echo "stuurt     ${body}"
  (( dry )) && { echo "dry-run: niets gewijzigd"; exit 0; }

  cf_result -X PATCH -d "$body" \
    "${API}/zones/${zone_id}/custom_hostnames/${id}" |
    python3 -c '
import json, sys
r = json.load(sys.stdin)
s = r.get("ssl") or {}
print("na PATCH   %s (cert: %s)" % (r.get("status"), s.get("status")))
for e in r.get("verification_errors") or []:
    print("melding    %s" % e)
'
  echo
  echo "nameten:   ./scripts/cf-verify.sh --ownership ${host}"
}

main "$@"
