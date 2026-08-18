#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/adopt-dns-records.sh — laat external-dns bestaande DNS-records adopteren
# door het ontbrekende TXT-eigendom bij te zetten.
#
# external-dns werkt met een TXT-registry: hij wijzigt alleen records waar zijn
# eigen eigendomsrecord bij staat. Records die met de hand zijn gemaakt — of die
# verweesd zijn geraakt door een wijziging van `txtOwnerId` — laat hij met rust.
# Gevolg: een nieuwe Ingress-annotatie (bijvoorbeeld `cloudflare-proxied`) heeft
# op die hosts geen effect. Gemeten 2026-08-18: 90 TXT-eigendomsrecords op ~160
# hosts.
#
# Dit script zet per host twee TXT-records bij (`<host>` en `a-<host>`) met exact
# het formaat dat external-dns verwacht. Daarna beschouwt hij zich eigenaar en
# reconcilieert hij het record bij de volgende ronde.
#
# VEILIGHEID: adoptie betekent dat external-dns het record voortaan naar de
# Ingress toe schrijft. Wijst een record nu ergens ánders naartoe dan onze
# loadbalancer, dan zou adoptie verkeer verplaatsen. Zulke hosts slaat dit script
# over en meldt ze; die horen met de hand bekeken te worden.
#
# Writes: met --apply twee TXT-records per host in de Cloudflare-zone
# Idempotent: yes (bestaand TXT-eigendom → overslaan)
# Requires: kubectl (lezen), curl, python3, CF_API_TOKEN met Zone:Read + DNS:Edit
#
# Usage:
#   CF_API_TOKEN=... ./scripts/adopt-dns-records.sh                       # dry-run, alle hosts
#   CF_API_TOKEN=... ./scripts/adopt-dns-records.sh --host almere.accept.openwoo.app
#   CF_API_TOKEN=... ./scripts/adopt-dns-records.sh --host almere.accept.openwoo.app --apply
#   CF_API_TOKEN=... ./scripts/adopt-dns-records.sh --apply               # alle kandidaten
#   CF_API_TOKEN=... ./scripts/adopt-dns-records.sh --only-annotated --apply

set -euo pipefail

readonly CF_ZONE="${CF_ZONE:-openwoo.app}"
readonly OWNER_ID="${OWNER_ID:-conduction-cluster}"
readonly LB_IP="${LB_IP:-81.24.6.82}"
# Globaal, niet local: de EXIT-trap loopt ná main en ziet een function-local niet.
INGFILE=""

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  local apply=0 only="" annotated=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply) apply=1; shift ;;
      --host) only="${2:?--host vereist een hostnaam}"; shift 2 ;;
      --only-annotated) annotated=1; shift ;;
      --dry-run) shift ;;
      -h|--help) usage; exit 2 ;;
      *) echo "onbekend argument: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
  [[ -n "${CF_API_TOKEN:-}" ]] || { echo "fout: zet CF_API_TOKEN" >&2; exit 1; }
  command -v kubectl >/dev/null || { echo "fout: kubectl niet gevonden" >&2; exit 1; }

  # De Ingress is de bron voor het resource-veld in het TXT-record. Via een
  # bestand, want de JSON van de hele vloot past niet in een argumentenlijst.
  INGFILE="$(mktemp)"
  trap 'rm -f "${INGFILE}"' EXIT
  kubectl get ingress -A -o json >"$INGFILE"

  APPLY="$apply" ONLY="$only" ANNOTATED="$annotated" ZONE="$CF_ZONE" OWNER="$OWNER_ID" LBIP="$LB_IP" \
    python3 - "$INGFILE" <<'PY'
import json, os, sys, urllib.parse, urllib.request, urllib.error

tok = os.environ['CF_API_TOKEN']
zone, owner, lbip = os.environ['ZONE'], os.environ['OWNER'], os.environ['LBIP']
apply_changes = os.environ['APPLY'] == '1'
only = os.environ['ONLY']
only_annotated = os.environ.get('ANNOTATED') == '1'
PROXY_ANN = 'external-dns.alpha.kubernetes.io/cloudflare-proxied'


def cf(path, method='GET', body=None):
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(
        'https://api.cloudflare.com/client/v4/' + path, data=data, method=method,
        headers={'Authorization': f'Bearer {tok}', 'Content-Type': 'application/json'})
    try:
        return json.load(urllib.request.urlopen(req, timeout=25))
    except urllib.error.HTTPError as e:
        return {'success': False, 'errors': json.loads(e.read().decode()).get('errors', [])}


zid = cf(f'zones?name={zone}')['result'][0]['id']

# hostnaam -> ingress (namespace/naam), alleen hosts in deze zone
owners = {}
for ing in json.load(open(sys.argv[1]))['items']:
    for rule in ing['spec'].get('rules', []):
        host = rule.get('host')
        if host and host.endswith('.' + zone):
            ann = (ing['metadata'].get('annotations') or {}).get(PROXY_ANN) == 'true'
            owners[host] = (ing['metadata']['namespace'], ing['metadata']['name'], ann)

# bestaande records ophalen (één keer, gepagineerd)
records, page = [], 1
while True:
    res = cf(f'zones/{zid}/dns_records?per_page=100&page={page}')
    records += res['result']
    info = res.get('result_info') or {}
    if page >= (info.get('total_pages') or 1):
        break
    page += 1

by_name = {}
for r in records:
    by_name.setdefault(r['name'], []).append(r)


def txt_content(ns, name):
    return f'"heritage=external-dns,external-dns/owner={owner},external-dns/resource=ingress/{ns}/{name}"'


todo, skipped, already = [], [], []
for host, (ns, name, ann) in sorted(owners.items()):
    if only and host != only:
        continue
    recs = by_name.get(host, [])
    a = [r for r in recs if r['type'] == 'A']
    txt = [r for r in recs if r['type'] == 'TXT' and 'heritage=external-dns' in r['content']]
    if not a:
        skipped.append((host, 'geen A-record'))
        continue
    if txt:
        already.append(host)
        continue
    if a[0]['content'] != lbip:
        skipped.append((host, f"A wijst naar {a[0]['content']}, niet naar {lbip}"))
        continue
    if only_annotated and not ann:
        skipped.append((host, 'Ingress heeft geen proxy-annotatie — adoptie levert hier niets op'))
        continue
    todo.append((host, ns, name, ann))

print(f'zone {zone} — {len(owners)} hosts uit Ingresses')
print(f'  al eigendom van external-dns : {len(already)}')
print(f'  te adopteren                 : {len(todo)}')
print(f'  overgeslagen                 : {len(skipped)}')
for host, reden in skipped:
    print(f'    ! {host}: {reden}')
for host, ns, name, ann in todo:
    winst = 'krijgt proxy' if ann else 'GEEN winst: Ingress zonder proxy-annotatie'
    print(f'    + {host} (ingress {ns}/{name}) — {winst}')

if not apply_changes:
    print('\ndry-run: niets gewijzigd. Draai met --apply.')
    raise SystemExit(0)

fails = 0
for host, ns, name, _ in todo:
    content = txt_content(ns, name)
    for rec_name in (host, f'a-{host}'):
        out = cf(f'zones/{zid}/dns_records', 'POST',
                 {'type': 'TXT', 'name': rec_name, 'content': content, 'ttl': 1})
        if not out.get('success'):
            errs = '; '.join(str(e.get('message')) for e in out.get('errors') or [])
            # 81058 = record bestaat al; dat is geen fout voor dit doel
            if '81058' in errs or 'already exists' in errs.lower():
                continue
            print(f'  FOUT bij {rec_name}: {errs}')
            fails += 1
    print(f'  geadopteerd: {host}')

print(f'\nklaar. Fouten: {fails}. external-dns pakt het op bij de volgende ronde;')
print('controleer met ./scripts/check-cloudflare-proxy.sh <host>')
raise SystemExit(1 if fails else 0)
PY
}

main "$@"
