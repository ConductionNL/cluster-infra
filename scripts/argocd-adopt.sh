#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: tool
#
# scripts/argocd-adopt.sh — begeleide adoptie van Argo CD onder eigen beheer
# (change add-argocd-selfmanaged, fase 3; zie docs/argocd.md).
#
# Voert de adoptie stap voor stap uit, met controles vóór en ná elke stap;
# stopt hard bij alles wat onverwacht is. Het OIDC-secret wordt in-cluster
# gekopieerd (argocd-cm -> Secret) en komt nooit in argv, logs of terminal.
# Bedoeld om door een MENS gedraaid te worden (agent-cataloog: apply/sync is
# mens-vereist); elke muterende stap vraagt bevestiging.
#
# Writes: cluster (namespace argocd): Secret argocd-oidc-keycloak (stap 1),
#   bootstrap-apply van argocd/ (stap 2), Application argocd (stap 3).
# Idempotent: ja — elke stap detecteert "al gedaan" en slaat over.
# Requires: kubectl (context naar het prod-cluster), python3, repo-checkout.
#
# Usage:
#   ./scripts/argocd-adopt.sh status    # waar staan we? (read-only)
#   ./scripts/argocd-adopt.sh stap1     # bootstrap-secret argocd-oidc-keycloak
#   ./scripts/argocd-adopt.sh stap2     # bootstrap-apply + SSO-check
#   ./scripts/argocd-adopt.sh stap3     # Application aanmaken; no-op aantonen
#   ./scripts/argocd-adopt.sh stap4     # na Keycloak-rotatie: secret bijwerken

set -euo pipefail

cd "$(dirname "$0")/.."
readonly NS="argocd"
readonly SECRET="argocd-oidc-keycloak"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  OK: $*"; }

confirm() {
  local antwoord
  read -r -p "$1 [ja/nee] " antwoord
  [[ "$antwoord" == "ja" ]] || fail "afgebroken door gebruiker"
}

preflight() {
  command -v kubectl >/dev/null || fail "kubectl ontbreekt"
  command -v python3 >/dev/null || fail "python3 ontbreekt"
  [[ -f argocd/kustomization.yaml ]] || fail "draai vanuit de cluster-infra-checkout"
  echo "kubectl-context: $(kubectl config current-context)"
  kubectl get ns "$NS" >/dev/null || fail "namespace ${NS} onbereikbaar"
}

# Diff-analyse: schrijft de kubectl-diff naar een tmpbestand en telt welke
# objecten afwijken. Print NOOIT diff-inhoud (kan secret-materiaal bevatten).
diff_objects() {
  local tmp
  tmp="$(mktemp)"
  kubectl diff -k argocd > "$tmp" 2>/dev/null || true  # exit 1 = er is diff
  grep '^diff -u -N' "$tmp" | sed 's|.*/LIVE-[0-9]*/||;s| .*||' | sort
  rm -f "$tmp"
}

secret_in_sync() {
  # Vergelijk de clientSecret uit de live argocd-cm met het Secret, in-proces;
  # niets wordt geprint. Exit 0 = gelijk.
  python3 - <<'PYEOF'
import base64, json, re, subprocess, sys

def get(kind, name, path):
    out = subprocess.run(["kubectl", "get", kind, name, "-n", "argocd",
                          "-o", f"jsonpath={path}"],
                         capture_output=True, text=True)
    return out.stdout if out.returncode == 0 else None

oidc = get("configmap", "argocd-cm", "{.data.oidc\\.config}") or ""
m = re.search(r"clientSecret:\s*(\S+)", oidc)
cm_val = m.group(1) if m else None
raw = get("secret", "argocd-oidc-keycloak", "{.data.clientSecret}")
sec_val = base64.b64decode(raw).decode() if raw else None
if sec_val is None:
    sys.exit(2)      # secret bestaat niet
if cm_val is None or cm_val.startswith("$"):
    sys.exit(0)      # cm verwijst al; secret bestaat -> in orde
sys.exit(0 if cm_val == sec_val else 3)
PYEOF
}

status() {
  preflight
  echo "== status =="
  if secret_in_sync; then ok "stap 1: secret ${SECRET} aanwezig en consistent"
  else echo "  te doen: stap 1 (secret; code $?)"; fi
  local afwijkend
  afwijkend="$(diff_objects)"
  if [[ -z "$afwijkend" ]]; then ok "stap 2: kubectl diff is leeg (bootstrap-apply gedaan)"
  else echo "  te doen: stap 2 — afwijkende objecten:"; echo "$afwijkend" | sed 's/^/    /'; fi
  if kubectl get application argocd -n "$NS" >/dev/null 2>&1; then
    echo "  stap 3: Application bestaat — sync=$(kubectl get application argocd -n "$NS" -o jsonpath='{.status.sync.status}') health=$(kubectl get application argocd -n "$NS" -o jsonpath='{.status.health.status}')"
  else echo "  te doen: stap 3 (Application argocd)"; fi
}

stap1() {
  preflight
  echo "== stap 1: bootstrap-secret ${SECRET} =="
  if secret_in_sync; then ok "secret bestaat al en is consistent met argocd-cm"; return; fi
  local rc=0; secret_in_sync || rc=$?
  [[ $rc -eq 3 ]] && confirm "secret bestaat maar wijkt af van argocd-cm; overschrijven?"
  confirm "secret ${SECRET} aanmaken in ${NS} (waarde in-cluster gekopieerd uit argocd-cm)?"
  # Kopieer in-proces: cm -> manifest -> apply via stdin (nooit in argv/ps).
  python3 - <<'PYEOF' | kubectl apply -f -
import json, re, subprocess, sys
oidc = subprocess.run(["kubectl", "get", "configmap", "argocd-cm", "-n",
                       "argocd", "-o", "jsonpath={.data.oidc\\.config}"],
                      capture_output=True, text=True, check=True).stdout
m = re.search(r"clientSecret:\s*(\S+)", oidc)
if not m or m.group(1).startswith("$"):
    sys.exit("clientSecret niet (meer) inline in argocd-cm — kopieerbron weg; "
             "vul het secret handmatig (stap 4-flow)")
print(json.dumps({
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "argocd-oidc-keycloak", "namespace": "argocd",
                 "labels": {"app.kubernetes.io/part-of": "argocd"}},
    "type": "Opaque", "stringData": {"clientSecret": m.group(1)},
}))
PYEOF
  secret_in_sync || fail "controle na aanmaken faalde"
  kubectl get secret "$SECRET" -n "$NS" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' \
    | grep -qx argocd || fail "part-of-label ontbreekt (vereist voor \$-verwijzing)"
  ok "secret aanwezig, consistent en correct gelabeld"
}

stap2() {
  preflight
  secret_in_sync || fail "eerst stap 1 (secret ontbreekt of wijkt af)"
  echo "== stap 2: bootstrap-apply =="
  local afwijkend verwacht
  afwijkend="$(diff_objects)"
  if [[ -z "$afwijkend" ]]; then ok "diff al leeg — stap 2 was al gedaan"; return; fi
  # Gate: uitsluitend de 3 gedocumenteerde objectgroepen mogen afwijken.
  verwacht='^(v1\.ConfigMap\.argocd\.(argocd-cm|argocd-rbac-cm)|rbac\.authorization\.k8s\.io\.v1\.RoleBinding\.argocd\.argocd-(application-controller|applicationset-controller|dex-server|notifications-controller|redis|server))$'
  local onverwacht
  onverwacht="$(echo "$afwijkend" | grep -Ev "$verwacht" || true)"
  [[ -z "$onverwacht" ]] || { echo "$onverwacht" | sed 's/^/  ONVERWACHT: /'; \
    fail "diff bevat meer dan de gedocumenteerde afwijkingen — eerst uitzoeken (docs/argocd.md)"; }
  echo "afwijkend (alle 3 verwacht en gedocumenteerd):"; echo "$afwijkend" | sed 's/^/  /'
  local pods_voor
  pods_voor="$(kubectl get pods -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)"
  confirm "kubectl apply -k argocd uitvoeren?"
  kubectl apply -k argocd
  [[ -z "$(diff_objects)" ]] || fail "diff niet leeg na apply"
  ok "diff leeg na apply"
  sleep 5
  [[ "$(kubectl get pods -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)" == "$pods_voor" ]] \
    && ok "geen pod-restarts (workloads onaangeraakt)" \
    || echo "  LET OP: podset veranderde — onderzoek (kubectl get pods -n ${NS})"
  kubectl get configmap argocd-cm -n "$NS" -o jsonpath='{.data.oidc\.config}' \
    | grep -q 'clientSecret: \$argocd-oidc-keycloak:clientSecret' \
    || fail "argocd-cm bevat de \$-verwijzing niet"
  ok "argocd-cm gebruikt nu de \$-verwijzing"
  echo
  echo ">>> Controleer NU de SSO-login op https://admin.commonground.nu (nieuw"
  echo ">>> incognitovenster). Rollback bij problemen: kubectl -n ${NS} edit cm argocd-cm"
  confirm "is de SSO-login geslaagd?"
  ok "stap 2 afgerond"
}

stap3() {
  preflight
  [[ -z "$(diff_objects)" ]] || fail "diff niet leeg — eerst stap 2"
  echo "== stap 3: Application argocd (zelfbeheer) =="
  if ! kubectl get application argocd -n "$NS" >/dev/null 2>&1; then
    confirm "Application argocd aanmaken (sync blijft handmatig)?"
    kubectl apply -f argo/applications/argocd.yaml
  else
    ok "Application bestaat al"
  fi
  echo "wachten op eerste vergelijking..."
  local sync health
  for _ in $(seq 1 24); do
    sync="$(kubectl get application argocd -n "$NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    [[ -n "$sync" && "$sync" != "Unknown" ]] && break
    sleep 5
  done
  health="$(kubectl get application argocd -n "$NS" -o jsonpath='{.status.health.status}')"
  echo "  sync=${sync:-?} health=${health:-?}"
  if [[ "$sync" == "Synced" ]]; then
    ok "Argo rapporteert Synced ZONDER ooit gesynct te hebben: de vastlegging is per definitie een no-op"
  else
    echo "  LET OP: sync=${sync}. Bekijk het verschil in de UI (app argocd) vóór je synct;"
    echo "  verwacht is Synced. Sync alleen na begrip van de diff."
  fi
  echo
  echo ">>> Volgende (stap 4): roteer de client secret van 'argocd' in Keycloak"
  echo ">>> (de oude waarde was ConfigMap-leesbaar) en draai daarna: $0 stap4"
}

stap4() {
  preflight
  echo "== stap 4: secret bijwerken na Keycloak-rotatie =="
  echo "plak de NIEUWE client secret (invoer blijft onzichtbaar):"
  local nieuw
  read -r -s nieuw
  [[ -n "$nieuw" ]] || fail "lege invoer"
  printf '%s' "$nieuw" | kubectl create secret generic "$SECRET" -n "$NS" \
    --from-file=clientSecret=/dev/stdin --dry-run=client -o yaml \
    | kubectl label --local -f - "app.kubernetes.io/part-of=argocd" -o yaml \
    | kubectl apply -f -
  unset nieuw
  ok "secret bijgewerkt"
  echo ">>> Controleer de SSO-login opnieuw (argocd-server leest het secret live)."
}

main() {
  case "${1:-status}" in
    status) status ;;
    stap1)  stap1 ;;
    stap2)  stap2 ;;
    stap3)  stap3 ;;
    stap4)  stap4 ;;
    *) grep '^#   ./scripts' "$0" | sed 's/^# *//'; exit 2 ;;
  esac
}

main "$@"
