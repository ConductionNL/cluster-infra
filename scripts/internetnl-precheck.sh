#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/internetnl-precheck.sh — meet per host de internet.nl-subtests die
# meetellen voor de score.
#
# Alleen de subtests met worst_status FAIL wegen mee (bron: internet.nl
# checks/categories.py + checks/scoring.py, gelezen 2026-08-18). Dat zijn:
# IPv6 (nameservers én webserver), DNSSEC, RPKI, en het TLS-blok. Security
# headers, security.txt, CAA, DANE en OCSP-stapling staan op NOTICE of INFO en
# wegen dus NIET mee — goed om te doen, maar geen procenten.
#
# Read-only. Gebruikt publieke bronnen: DNS, TLS-handshakes, RIPEstat voor RPKI.
#
# Writes: read-only
# Idempotent: yes
# Requires: dig, curl, openssl, python3
#
# Usage:
#   ./scripts/internetnl-precheck.sh open.dinkelland.nl
#   ./scripts/internetnl-precheck.sh open.dinkelland.nl open.tubbergen.nl
#   ./scripts/internetnl-precheck.sh --file hosts.txt
#   SKIP_RPKI=1 ./scripts/internetnl-precheck.sh open.epe.nl     # sneller
#   ./scripts/internetnl-precheck.sh --file hosts/internetnl.txt \
#     --allow hosts/internetnl-allow.txt --strict   # exit 1 bij nieuwe FAIL

set -euo pipefail

readonly TIMEOUT="${TIMEOUT:-15}"
readonly HSTS_MIN="${HSTS_MIN:-31536000}"
readonly SKIP_RPKI="${SKIP_RPKI:-0}"
readonly RIPESTAT="${RIPESTAT:-https://stat.ripe.net/data}"
STRICT=0
ALLOW=""
FAILURES=0
CACHE=""

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

# Registreerbaar domein: laatste twee labels. Voldoende voor .nl/.nu/.app.
zone_of() {
  awk -F. '{print $(NF-1)"."$NF}' <<<"$1"
}

ns_ipv6() {
  local zone="$1" ns total=0 with6=0
  while read -r ns; do
    [[ -z "$ns" ]] && continue
    total=$((total + 1))
    [[ -n "$(dig +short "$ns" AAAA)" ]] && with6=$((with6 + 1))
  done < <(dig +short "$zone" NS)
  if (( total == 0 )); then
    echo "geen-ns"
  elif (( with6 == total )); then
    echo "OK(${with6}/${total})"
  else
    echo "FAIL(${with6}/${total})"
  fi
}

rpki_of() {
  local ip="$1"
  local cached="${CACHE}/rpki-${ip}"
  [[ "$SKIP_RPKI" == "1" ]] && { echo "overgeslagen"; return; }
  [[ -f "$cached" ]] && { cat "$cached"; return; }

  local overview asn prefix status
  overview="$(curl -sS --max-time "$TIMEOUT" "${RIPESTAT}/prefix-overview/data.json?resource=${ip}" || true)"
  read -r asn prefix <<<"$(python3 -c "
import json,sys
try: d=json.loads(sys.argv[1])['data']
except Exception: print('- -'); raise SystemExit
asns=d.get('asns') or [{}]
print(asns[0].get('asn','-'), d.get('resource','-'))
" "$overview")"
  if [[ "$asn" == "-" || "$prefix" == "-" ]]; then
    echo "onbekend" | tee "$cached"
    return
  fi
  status="$(curl -sS --max-time "$TIMEOUT" \
    "${RIPESTAT}/rpki-validation/data.json?resource=${asn}&prefix=${prefix}" |
    python3 -c "
import json,sys
print(json.load(sys.stdin)['data'].get('status','onbekend'))
" || echo onbekend)"
  echo "${status}(AS${asn})" | tee "$cached"
}

tls_probe() {
  local host="$1" version="$2"
  echo | timeout "$TIMEOUT" openssl s_client -connect "${host}:443" \
    -servername "$host" "$version" >/dev/null 2>&1
}

check_host() {
  local host="$1"
  local zone aaaa a hsts key trust tls13 old rpki
  zone="$(zone_of "$host")"

  a="$(dig +short "$host" A | head -1)"
  aaaa="$(dig +short "$host" AAAA | head -1)"

  # `|| true` is hier geen luiheid: met set -e en pipefail stopt het hele script
  # op de eerste host zonder HSTS of zonder TLS — precies de hosts die je wilt
  # zien. Een lege waarde is de meting, geen fout.
  hsts="$(curl -sSI --max-time "$TIMEOUT" "https://${host}/" 2>/dev/null |
    tr -d '\r' | awk 'tolower($1)=="strict-transport-security:"{print}' |
    grep -oE 'max-age=[0-9]+' | cut -d= -f2 | head -1 || true)"

  local cert
  cert="$(echo | timeout "$TIMEOUT" openssl s_client -connect "${host}:443" \
    -servername "$host" 2>/dev/null || true)"
  if grep -q 'Verify return code: 0' <<<"$cert"; then trust="OK"; else trust="FAIL"; fi
  key="$(printf '%s' "$cert" | openssl x509 -noout -text 2>/dev/null |
    grep -m1 -E 'Public Key Algorithm' | awk '{print $NF}' || true)"
  case "$key" in
    id-ecPublicKey) key="ECDSA" ;;
    rsaEncryption) key="RSA-$(printf '%s' "$cert" | openssl x509 -noout -text 2>/dev/null |
      grep -m1 -oE '\([0-9]+ bit\)' | tr -dc '0-9' || true)" ;;
    "") key="?" ;;
  esac

  tls13=FAIL; tls_probe "$host" -tls1_3 && tls13=OK
  old=OK
  tls_probe "$host" -tls1 && old="FAIL(1.0)"
  tls_probe "$host" -tls1_1 && old="FAIL(1.1)"

  rpki="$(rpki_of "${a:-0.0.0.0}")"

  printf '%-42s ' "$host"
  printf 'IPv6=%-4s ' "$([[ -n "$aaaa" ]] && echo OK || echo FAIL)"
  printf 'NS6=%-12s ' "$(ns_ipv6 "$zone")"
  printf 'DNSSEC=%-4s ' "$([[ -n "$(dig +short "$zone" DS)" ]] && echo OK || echo FAIL)"
  printf 'RPKI=%-18s ' "$rpki"
  printf 'HSTS=%-4s ' "$( (( ${hsts:-0} >= HSTS_MIN )) && echo OK || echo FAIL)"
  printf 'TLS1.3=%-4s ' "$tls13"
  printf 'oud=%-9s ' "$old"
  printf 'cert=%-4s ' "$trust"
  printf 'sleutel=%s\n' "$key"

  # In strict-modus tellen we alleen wat níét in de allowlist staat. Zo blijft
  # een bekend, geaccepteerd gat (vandaag: IPv6) zichtbaar in de uitvoer zonder
  # de gate elke week rood te maken — en valt een NIEUW gat wel op.
  if (( STRICT == 1 )); then
    local subtest
    for subtest in $(host_failures "$host" "$aaaa" "$hsts" "$trust" "$tls13" "$old" "$key"); do
      if [[ -n "$ALLOW" ]] && grep -qxF "${host} ${subtest}" "$ALLOW"; then
        continue
      fi
      echo "  NIEUW GAT: ${host} ${subtest}" >&2
      FAILURES=$((FAILURES + 1))
    done
  fi
}

# Namen van de meetellende subtests die falen. Eén regel per subtest, zodat de
# allowlist per host én per subtest kan zijn.
host_failures() {
  local host="$1" aaaa="$2" hsts="$3" trust="$4" tls13="$5" old="$6" key="$7"
  local zone
  zone="$(zone_of "$host")"
  [[ -z "$aaaa" ]] && echo IPv6
  [[ -z "$(dig +short "$zone" DS)" ]] && echo DNSSEC
  (( ${hsts:-0} >= HSTS_MIN )) || echo HSTS
  [[ "$trust" == OK ]] || echo cert
  [[ "$tls13" == OK ]] || echo TLS1.3
  [[ "$old" == OK ]] || echo oude-TLS
  case "$key" in
    ECDSA) ;;
    RSA-*) (( ${key#RSA-} >= 3072 )) || echo sleutel ;;
    *) echo sleutel ;;
  esac
  [[ "$(ns_ipv6 "$zone")" == OK* ]] || echo NS-IPv6
  return 0
}

main() {
  local hosts=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 2 ;;
      --file) mapfile -t hosts <"${2:?--file vereist een pad}"; shift 2 ;;
      --allow) ALLOW="${2:?--allow vereist een pad}"; shift 2 ;;
      --strict) STRICT=1; shift ;;
      -*) echo "onbekend argument: $1" >&2; usage >&2; exit 2 ;;
      *) hosts+=("$1"); shift ;;
    esac
  done
  [[ ${#hosts[@]} -eq 0 ]] && { usage; exit 2; }

  CACHE="$(mktemp -d)"
  trap 'rm -rf "${CACHE}"' EXIT

  echo "meetellend voor de internet.nl-score: IPv6, DNSSEC, RPKI, TLS."
  echo "headers/security.txt/CAA/DANE wegen NIET mee (NOTICE of INFO)."
  echo
  local host
  for host in "${hosts[@]}"; do
    [[ -z "$host" || "$host" == \#* ]] && continue
    check_host "$host"
  done

  if (( STRICT == 1 )); then
    if (( FAILURES > 0 )); then
      echo >&2
      echo "FAAL: ${FAILURES} gat(en) die niet in de allowlist staan." >&2
      return 1
    fi
    echo
    echo "strict: geen nieuwe gaten (bekende gaten staan in ${ALLOW:-<geen allowlist>})."
  fi
}

main "$@"
