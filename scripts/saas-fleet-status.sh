#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/saas-fleet-status.sh — één tabel met de SaaS-stand van alle
# klantdomein-hosts die dit cluster serveert.
#
# check-saas-hostname.sh geeft één host diepgaand weer; dit script geeft de hele
# set in één oogopslag, zodat je ziet wie waar in de tweetrapsuitrol staat zonder
# per host af te tikken. Read-only, geen Cloudflare-token nodig: alles komt uit
# DNS, TLS en HTTP. De hostenlijst komt uit de Ingressen van het cluster, met de
# eigen zones eruit gefilterd — een klantdomein is per definitie een naam die wij
# niet in Cloudflare beheren.
#
# De oordeelkolom kent zes standen:
#   klaar         CNAME naar de fallback origin en een AAAA — de uitrol is af
#   stap2-open    DCV én eigendom staan; alleen het verkeer moet nog om
#   stap1-half    DCV staat, eigendoms-TXT mist — de hostname blijft `pending`
#   niet-begonnen geen van beide records; hier is nog geen mail uit
#   elders        staat niet op onze loadbalancer; een ander platform serveert dit
#   kapot-<code>  foutstatus aan de edge (409 = hostname nog niet actief)
#
# Een host in een eigen zone loopt niet via Cloudflare for SaaS en krijgt daarom
# `eigen-zone`: die heeft alleen de proxy-vlag nodig, geen records bij een klant.
# Dat kan alleen bij --host of --file, want de standaardlijst filtert ze eruit.
#
# Writes: read-only
# Idempotent: yes
# Requires: dig, curl, openssl, kubectl (voor de standaard hostenlijst)
#
# Usage:
#   ./scripts/saas-fleet-status.sh                             # alle klantdomeinen uit het cluster
#   ./scripts/saas-fleet-status.sh --host open.dinkelland.nl   # één host
#   ./scripts/saas-fleet-status.sh --file /tmp/hosts.txt       # lijst uit een bestand
#   EDGE_IP=104.21.60.114 ./scripts/saas-fleet-status.sh       # meet tegen de edge i.p.v. via DNS
#   TIMEOUT=5 ./scripts/saas-fleet-status.sh                   # korter geduld per host
#   NS=1.1.1.1 ./scripts/saas-fleet-status.sh                   # andere resolver, eigen cache
#
# Zonder NS leest het script via de systeemresolver, en die kan direct na een
# DNS-wijziging nog het oude antwoord geven — gezien op 2026-08-19: één minuut na
# een omzetting stond het A-record nog in de cache en luidde het oordeel
# `niet-begonnen` terwijl de host al klaar was. Meet je vlak na een wijziging,
# zet dan NS op een andere resolver.
#
# NS moet een **recursieve** resolver zijn, niet de autoritatieve server van de
# zone. Een autoritatieve server volgt geen CNAME naar een andere zone en geeft
# dus alleen de CNAME terug, geen adres — dan lijkt elke omgezette host adresloos.

set -euo pipefail

readonly TARGET="${TARGET:-saas.openwoo.app}"
readonly LB_IP="${LB_IP:-81.24.6.82}"
readonly EDGE_IP="${EDGE_IP:-}"
readonly TIMEOUT="${TIMEOUT:-8}"
readonly OWN_ZONES="${OWN_ZONES:-openwoo.app commonground.nu opencatalogi.nl}"
readonly NS="${NS:-}"

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

die() { echo "fout: $*" >&2; exit 1; }

# Eén plek voor alle DNS-vragen, zodat NS overal geldt.
dig_rr() {
  local host="$1" type="$2"
  if [[ -n "$NS" ]]; then
    dig "@${NS}" +short "$host" "$type" 2>/dev/null
  else
    dig +short "$host" "$type" 2>/dev/null
  fi
}

# Alleen adressen: een CNAME-keten zet de doelnaam als eerste regel in +short,
# en die mag niet als "adres" doorgaan.
only_v4() { grep -E '^[0-9]+(\.[0-9]+){3}$' || true; }
only_v6() { grep -E '^[0-9a-fA-F:]+$' || true; }

is_own_zone() {
  local host="$1" zone
  for zone in $OWN_ZONES; do
    [[ "$host" == *".${zone}" || "$host" == "$zone" ]] && return 0
  done
  return 1
}

# Klantdomeinen uit de Ingressen van het cluster; eigen zones eruit.
hosts_from_cluster() {
  command -v kubectl >/dev/null || die "kubectl ontbreekt; gebruik --file of --host"
  kubectl get ingress -A \
    -o jsonpath='{range .items[*]}{.spec.rules[*].host}{"\n"}{end}' 2>/dev/null |
    tr ' ' '\n' | sed '/^$/d' | sort -u |
    while read -r host; do
      is_own_zone "$host" || echo "$host"
    done
}

# Het adres waarmee we verbinden. EDGE_IP wint; anders het opgeloste A-record,
# zodat curl en openssl niet afhankelijk zijn van de resolver van de machine —
# gezien op 2026-08-22: een kapotte ISP-resolver liet elke host als onbereikbaar
# ogen terwijl ze 200 gaven.
connect_ip() {
  local host="$1"
  if [[ -n "$EDGE_IP" ]]; then
    echo "$EDGE_IP"
  else
    dig_rr "$host" A | only_v4 | head -1
  fi
}

http_status() {
  local host="$1" ip
  ip="$(connect_ip "$host")"
  if [[ -n "$ip" ]]; then
    curl -sSI --max-time "$TIMEOUT" --resolve "${host}:443:${ip}" \
      "https://${host}/" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '\r'
    return 0
  fi
  if [[ -n "$EDGE_IP" ]]; then
    curl -sSI --max-time "$TIMEOUT" --resolve "${host}:443:${EDGE_IP}" \
      "https://${host}/" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '\r'
  else
    curl -sSI --max-time "$TIMEOUT" "https://${host}/" 2>/dev/null |
      head -1 | awk '{print $2}' | tr -d '\r'
  fi
}

cert_issuer() {
  local host="$1"
  local ip connect="${host}:443"
  ip="$(connect_ip "$host")"
  [[ -n "$ip" ]] && connect="${ip}:443"
  echo | timeout "$TIMEOUT" openssl s_client -connect "$connect" -servername "$host" 2>/dev/null |
    openssl x509 -noout -issuer 2>/dev/null |
    sed -n 's/.*CN *= *//p' | cut -c1-18
}

ipv6_ok() {
  local host="$1"
  [[ -n "$(dig_rr "$host" AAAA | only_v6)" ]] || { echo "-"; return; }
  if curl -6 -sS -o /dev/null --max-time "$TIMEOUT" "https://${host}/" 2>/dev/null; then
    echo "ja"
  else
    echo "FAALT"
  fi
}

verdict_for() {
  local host="$1" cname="$2" a="$3" aaaa="$4" dcv="$5" own="$6" status="$7"
  if is_own_zone "$host"; then
    [[ -n "$aaaa" ]] && echo "eigen-zone-ipv6" || echo "eigen-zone-geen-ipv6"
    return
  fi
  if [[ -n "$status" && "$status" != "200" && "$status" != "301" && "$status" != "302" ]]; then
    echo "kapot-${status}"
  elif [[ "$cname" == *"${TARGET}"* && -n "$aaaa" ]]; then
    echo "klaar"
  elif [[ "$a" != *"${LB_IP}"* ]]; then
    echo "elders"
  elif [[ -n "$dcv" && -n "$own" ]]; then
    echo "stap2-open"
  elif [[ -n "$dcv" ]]; then
    echo "stap1-half"
  else
    echo "niet-begonnen"
  fi
}

report_host() {
  local host="$1" cname a aaaa dcv own status issuer v6 verdict
  cname="$(dig_rr "$host" CNAME | tr '\n' ' ')"
  a="$(dig_rr "$host" A | only_v4 | tr '\n' ' ')"
  aaaa="$(dig_rr "$host" AAAA | only_v6 | head -1)"
  dcv="$(dig_rr "_acme-challenge.${host}" CNAME | head -1)"
  own="$(dig_rr "_cf-custom-hostname.${host}" TXT | head -1)"
  status="$(http_status "$host" || true)"
  issuer="$(cert_issuer "$host" || true)"
  v6="$(ipv6_ok "$host" || true)"
  verdict="$(verdict_for "$host" "$cname" "$a" "$aaaa" "$dcv" "$own" "$status")"

  printf '%-34s %-4s %-4s %-5s %-6s %-18s %-6s %s\n' \
    "$host" \
    "$([[ -n "$dcv" ]] && echo ok || echo '-')" \
    "$([[ -n "$own" ]] && echo ok || echo '-')" \
    "${status:--}" \
    "$v6" \
    "${issuer:--}" \
    "$([[ -n "$aaaa" ]] && echo ja || echo nee)" \
    "$verdict"
}

main() {
  local -a hosts=()
  while (($#)); do
    case "$1" in
      --host)
        [[ -n "${2:-}" ]] || die "--host vraagt een hostnaam"
        hosts+=("$2")
        shift 2
        ;;
      --file)
        [[ -r "${2:-}" ]] || die "--file vraagt een leesbaar bestand"
        mapfile -t -O "${#hosts[@]}" hosts < <(sed '/^$/d;/^#/d' "$2")
        shift 2
        ;;
      -h | --help)
        usage
        exit 2
        ;;
      *) die "onbekend argument: $1 (zie --help)" ;;
    esac
  done

  if ((${#hosts[@]} == 0)); then
    mapfile -t hosts < <(hosts_from_cluster)
  fi
  ((${#hosts[@]} > 0)) || die "geen hosts om te meten"

  echo "gemeten $(date '+%F %H:%M %Z') — doel ${TARGET}${EDGE_IP:+, tegen edge ${EDGE_IP}}"
  printf '%-34s %-4s %-4s %-5s %-6s %-18s %-6s %s\n' \
    host dcv eig http ipv6 cert-uitgever aaaa oordeel

  local host
  for host in "${hosts[@]}"; do
    report_host "$host" || printf '%-34s %s\n' "$host" "MEETFOUT — overgeslagen"
  done
}

main "$@"
