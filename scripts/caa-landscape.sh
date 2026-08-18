#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/caa-landscape.sh — bepaal welke certificaatautoriteiten er werkelijk
# certificaten uitgeven in onze zones, vóórdat we een CAA-record zetten.
#
# Een CAA-record dat een CA vergeet, stopt diens vernieuwingen — en dat merk je
# pas maanden later als een certificaat verloopt. Dit script leest daarom de
# Certificate-Transparency-logs (via de publieke CertSpotter-API) en toont per
# zone welke CA's er de afgelopen tijd hebben uitgegeven, met de hostnamen erbij
# voor elke CA die niet Let's Encrypt is. Read-only; geen sleutels nodig.
#
# Alleen niet-verlopen certificaten tellen mee: een CA die alleen historisch
# voorkomt hoeft niet in het CAA-record.
#
# Writes: read-only
# Idempotent: yes
# Requires: curl, python3
#
# Usage:
#   ./scripts/caa-landscape.sh
#   ./scripts/caa-landscape.sh openwoo.app commonground.nu
#   CS_PAGES=10 ./scripts/caa-landscape.sh opencatalogi.nl

set -euo pipefail

readonly DEFAULT_ZONES=(openwoo.app commonground.nu opencatalogi.nl conduction.nl)
readonly CS_API="${CS_API:-https://api.certspotter.com/v1/issuances}"
readonly CS_PAGES="${CS_PAGES:-6}"
readonly TIMEOUT="${TIMEOUT:-45}"
WORKDIR=""
INCOMPLETE=""

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

# CertSpotter pagineert op id; elke pagina in een eigen bestand, want
# JSON-arrays aan elkaar plakken levert geen geldige JSON op.
fetch_zone() {
  local zone="$1" dir="$2" after="" page=0
  mkdir -p "$dir"
  while (( page < CS_PAGES )); do
    local out="${dir}/page-${page}.json"
    if ! curl -sS --max-time "$TIMEOUT" \
      "${CS_API}?domain=${zone}&include_subdomains=true&expand=issuer&expand=dns_names${after}" \
      -o "$out"; then
      echo "waarschuwing: ophalen faalde voor ${zone} (pagina ${page})" >&2
      rm -f "$out"
      break
    fi
    # Een foutobject (rate limit) is GEEN lege pagina. Stil doorlopen zou een
    # onvolledige uitkomst als volledig laten lezen; dus luidruchtig stoppen.
    local last_id
    last_id="$(python3 -c "
import json,sys
try: d=json.load(open('${out}'))
except Exception as e:
    print(f'onleesbaar antwoord: {e}', file=sys.stderr); sys.exit(2)
if isinstance(d,dict):
    print('API zegt: ' + str(d.get('message') or d), file=sys.stderr); sys.exit(2)
if not isinstance(d,list) or not d: sys.exit(1)
print(d[-1]['id'])
")" || {
      local rc=$?
      rm -f "$out"
      if (( rc == 2 )); then
        echo "ONVOLLEDIG voor ${zone}: de API stopte na pagina ${page}" >&2
        INCOMPLETE+=" ${zone}"
      fi
      break
    }
    after="&after=${last_id}"
    page=$((page + 1))
  done
}

report_zone() {
  local zone="$1" dir="$2"
  python3 - "$zone" "$dir" <<'PY'
import json, sys, collections, datetime

import pathlib

zone, directory = sys.argv[1], sys.argv[2]
seen, rows = set(), []
for page in sorted(pathlib.Path(directory).glob('page-*.json')):
    for row in json.loads(page.read_text()):
        if row['id'] in seen:
            continue
        seen.add(row['id'])
        rows.append(row)

now = datetime.datetime.now(datetime.timezone.utc)
def live(row):
    try:
        return datetime.datetime.fromisoformat(row['not_after']) > now
    except Exception:
        return True

rows = [r for r in rows if live(r)]
issuers = collections.defaultdict(list)
for r in rows:
    name = (r.get('issuer') or {}).get('friendly_name') or '?'
    issuers[name].extend(r.get('dns_names') or [])

print(f"\n== {zone} — {len(rows)} geldige certificaten in CT ==")
for name, hosts in sorted(issuers.items(), key=lambda kv: -len(kv[1])):
    uniq = sorted(set(hosts))
    print(f"  {name:26s} {len(uniq):4d} hostnamen")
    if 'Let\'s Encrypt' not in name:
        for h in uniq[:12]:
            print(f"       {h}")
        if len(uniq) > 12:
            print(f"       … en {len(uniq) - 12} meer")
PY
}

main() {
  local zones=("$@")
  [[ ${#zones[@]} -eq 0 ]] && zones=("${DEFAULT_ZONES[@]}")
  [[ "${zones[0]}" == "-h" || "${zones[0]}" == "--help" ]] && { usage; exit 2; }

  WORKDIR="$(mktemp -d)"
  trap 'rm -rf "${WORKDIR}"' EXIT

  local zone
  for zone in "${zones[@]}"; do
    fetch_zone "$zone" "${WORKDIR}/${zone}"
    report_zone "$zone" "${WORKDIR}/${zone}"
  done

  if [[ -n "$INCOMPLETE" ]]; then
    echo
    echo "LET OP: onvolledige uitkomst voor:${INCOMPLETE} — opnieuw draaien," >&2
    echo "de publieke API limiteert het aantal aanvragen per periode." >&2
  fi

  cat <<'EOF'

Lees dit als: elke CA in de lijst geeft nú certificaten uit voor die zone. Een
CAA-record moet ze allemaal toestaan, of de betreffende dienst eerst verhuizen.
Waarden: letsencrypt.org / "pki.goog; cansignhttpexchanges=yes" / ssl.com /
sectigo.com / digicert.com
EOF
}

main "$@"
