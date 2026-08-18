#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/tls-sigalgs-apply.sh — zet SHA-224 uit op de ingress-nginx-controller,
# met back-up, verificatie en automatische rollback.
#
# De audit op open.dinkelland.nl noemt SHA-224 bij TLS 1.2. De omzetting naar een
# ECDSA-sleutel loste dat NIET op: `RSA+SHA224` wordt sindsdien geweigerd, maar
# `ECDSA+SHA224` levert nog een signatuur. De fix is een `http-snippet` met
# `ssl_conf_command SignatureAlgorithms` op de globale controller-ConfigMap.
#
# Waarom deze wrapper en niet één `kubectl patch`:
#
#   * De ConfigMap staat in GEEN repo (Helm-release `nginx`, geen Argo-app). Een
#     patch is dus drift zonder spoor. Dit script legt eerst een back-up neer;
#     dat bestand is het enige bewijs van de staat van vóór.
#   * De wijziging is fleet-breed: elke tenant plus Nextcloud. Een ongeldige
#     config laat ingress-nginx de oude config houden, maar dan is de wijziging
#     stil niet toegepast. Daarom verifieert dit script dat SHA-224 daadwerkelijk
#     geweigerd wordt EN dat de hosts nog antwoorden — en draait het anders zelf
#     terug.
#
# Standaard doet het script niets: zonder --apply is het een dry-run.
#
# Writes: back-up in BACKUP_DIR; met --apply de ConfigMap in het cluster
# Idempotent: yes (weigert als http-snippet al gezet is)
# Requires: kubectl (schrijfrechten op de ingress-nginx-namespace), curl, openssl
#
# Usage:
#   ./scripts/tls-sigalgs-apply.sh                      # dry-run: toon wat er zou gebeuren
#   ./scripts/tls-sigalgs-apply.sh --apply              # back-up, patch, verifieer, evt. terugdraaien
#   ./scripts/tls-sigalgs-apply.sh --rollback           # http-snippet weghalen
#   SMOKE_HOSTS=open.epe.nl ./scripts/tls-sigalgs-apply.sh --apply
#   BACKUP_DIR=~/backups ./scripts/tls-sigalgs-apply.sh --apply

set -euo pipefail

readonly NS="${NS:-ingress-nginx}"
readonly CONFIGMAP="${CONFIGMAP:-nginx-ingress-nginx-controller}"
readonly BACKUP_DIR="${BACKUP_DIR:-./backup}"
readonly WAIT_SECONDS="${WAIT_SECONDS:-90}"
readonly SMOKE_HOSTS="${SMOKE_HOSTS:-open.dinkelland.nl,open.tubbergen.nl,dinkelland.commonground.nu}"
readonly SIGALGS="${SIGALGS:-ECDSA+SHA256:ECDSA+SHA384:ECDSA+SHA512:rsa_pss_rsae_sha256:rsa_pss_rsae_sha384:rsa_pss_rsae_sha512:RSA+SHA256:RSA+SHA384:RSA+SHA512}"
readonly SNIPPET="ssl_conf_command SignatureAlgorithms ${SIGALGS};"

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "fout: $*" >&2; exit 1; }

current_snippet() {
  kubectl -n "$NS" get cm "$CONFIGMAP" -o jsonpath='{.data.http-snippet}' 2>/dev/null || true
}

backup() {
  mkdir -p "$BACKUP_DIR"
  local file
  file="${BACKUP_DIR}/${CONFIGMAP}-$(date +%Y%m%dT%H%M%S).yaml"
  kubectl -n "$NS" get cm "$CONFIGMAP" -o yaml >"$file"
  echo "$file"
}

# Weigert SHA-224? Dat is de bedoeling ná de wijziging.
sha224_refused() {
  local host="$1"
  ! echo | timeout 15 openssl s_client -connect "${host}:443" -servername "$host" \
    -tls1_2 -sigalgs ECDSA+SHA224 2>&1 | grep -q 'Peer signature type'
}

reachable() {
  local host="$1" code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://${host}/" || echo 000)"
  [[ "$code" != "000" ]]
}

smoke() {
  local host ok=1
  local IFS=,
  for host in $SMOKE_HOSTS; do
    if ! reachable "$host"; then
      log "  ${host}: GEEN ANTWOORD"
      ok=0
      continue
    fi
    if sha224_refused "$host"; then
      log "  ${host}: bereikbaar, SHA-224 geweigerd"
    else
      log "  ${host}: bereikbaar, SHA-224 nog geaccepteerd"
      ok=0
    fi
  done
  (( ok == 1 ))
}

do_apply() {
  local existing
  existing="$(current_snippet)"
  [[ -n "$existing" ]] && die "http-snippet is al gezet:
${existing}
Verwijder of pas hem met de hand aan; dit script overschrijft niets."

  log "back-up maken"
  local file
  file="$(backup)"
  log "back-up: ${file}"

  log "controle vóór de wijziging"
  smoke || log "let op: de nulmeting was al niet schoon (zie hierboven)"

  log "patchen"
  kubectl -n "$NS" patch cm "$CONFIGMAP" --type merge \
    -p "{\"data\":{\"http-snippet\":\"${SNIPPET}\"}}" >/dev/null

  log "wachten tot de reload doorwerkt (max ${WAIT_SECONDS}s)"
  local deadline=$((SECONDS + WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    if smoke; then
      log "OK — wijziging is doorgevoerd en de hosts antwoorden"
      log "terugdraaien kan met: $0 --rollback"
      return 0
    fi
    sleep 10
  done

  log "verificatie FAALT — automatisch terugdraaien"
  do_rollback
  die "de wijziging is teruggedraaid; back-up staat in ${file}"
}

do_rollback() {
  log "http-snippet weghalen"
  kubectl -n "$NS" patch cm "$CONFIGMAP" --type merge \
    -p '{"data":{"http-snippet":null}}' >/dev/null
  log "wachten op de reload"
  local deadline=$((SECONDS + WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    local host
    local IFS=,
    for host in $SMOKE_HOSTS; do
      reachable "$host" && { log "OK — ${host} antwoordt weer"; return 0; }
    done
    sleep 10
  done
  die "na terugdraaien antwoordt geen enkele smoke-host; kijk naar de controller-pods"
}

do_dryrun() {
  cat <<EOF
dry-run — er wordt niets gewijzigd.

  namespace   ${NS}
  configmap   ${CONFIGMAP}
  smoke-hosts ${SMOKE_HOSTS}
  back-up in  ${BACKUP_DIR}

toe te voegen sleutel http-snippet:
  ${SNIPPET}

huidige waarde: $(current_snippet || true)

Blast radius: de hele vloot plus Nextcloud — dit is een globale nginx-instelling.
Een ongeldige config laat ingress-nginx de oude config houden; dit script merkt
dat doordat SHA-224 dan nog geaccepteerd wordt, en draait zelf terug.

Draai met --apply om het te doen.
EOF
}

main() {
  command -v kubectl >/dev/null || die "kubectl niet gevonden"
  case "${1:-}" in
    ""|--dry-run) do_dryrun ;;
    --apply) do_apply ;;
    --rollback) do_rollback ;;
    -h|--help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
