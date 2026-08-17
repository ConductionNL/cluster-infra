# gateway-api/crds — gevendorde CRD's voor Envoy Gateway

Deze map bevat één bestand: alle CustomResourceDefinitions die Envoy Gateway
nodig heeft, gevendord uit de gepinde Helm-chart. De chart draait daarom met
`crds.enabled: false` (zie `../envoy-gateway/values.yaml`) — anders zouden
chart en Application dezelfde CRD's beheren.

| | |
|---|---|
| Bestand | `crds/envoy-gateway-crds-1.8.3.yaml` |
| Chart | `oci://docker.io/envoyproxy/gateway-helm` versie `1.8.3` |
| Chart-digest | `sha256:74551245ad0b0608f207e52c9ec3ce96ddd14e7655d12d5005c1c1d03b9d422a` |
| Gateway API bundle | `v1.5.1` (uit de annotatie `gateway.networking.k8s.io/bundle-version`) |
| sha256 van het bestand | `c8aadb8873ef55094628a5b986c5301df6696e178261ca63ab9d7b6f117bef72` |
| Inhoud | 20 CRD's (12 × `gateway.networking*`, 8 × `gateway.envoyproxy.io`) + 1 ValidatingAdmissionPolicy + binding |
| Opgehaald | 2026-08-17 |

## Waarom vendoren, en niet het standard-channel-asset

Het upstream release-asset `standard-install.yaml` van Gateway API v1.5.1 bevat
**8** CRD's. De chart installeert er **12**: daarbovenop `tcproutes`,
`udproutes` en de twee experimentele `gateway.networking.x-k8s.io`-types.
Envoy Gateway's eigen ClusterRole watcht `tcproutes`, `udproutes`,
`tlsroutes`, `grpcroutes`, `listenersets` en `backendtlspolicies`
(`charts/crds` → `templates/_rbac.tpl`), dus met alleen het standard-channel-
bestand start de controller zijn informers niet.

Vendoren volgt de lijn van `argocd/` in deze repo (hermetische upstream) en de
regel na het OLM-incident van 2026-08-10: neem het release-artefact, niet een
live verwijzing naar een branch.

## Bumpen naar een nieuwe chartversie

Eén commando, reproduceerbaar. Vervang `1.8.3` door de doelversie:

    helm pull oci://docker.io/envoyproxy/gateway-helm --version 1.8.3 \
      --untar --untardir /tmp/eg
    helm template crds /tmp/eg/gateway-helm/charts/crds --include-crds \
      > gateway-api/crds/envoy-gateway-crds-1.8.3.yaml

Verifiëren dat het gevendorde bestand ongewijzigd overeenkomt met de chart:
draai dezelfde twee commando's naar een tijdelijk bestand en `diff` het tegen
wat in git staat. Leeg verschil = het bestand is precies wat de chart zou
installeren.

Bij een bump horen in dezelfde wijziging mee:
- `../envoy-gateway/values.yaml` en `../argo/applications/envoy-gateway.yaml`
  (`targetRevision`) naar dezelfde versie;
- de bestandsnaam en de tabel hierboven;
- controleren of de Gateway API-bundleversie mee opschuift (breaking changes
  in `v1`-types raken elke HTTPRoute op het cluster).

## Waarom `prune: false`

De Application `gateway-api-crds` staat op `prune: false`. Een CRD weghalen
verwijdert in één klap élk object van dat type — alle Gateways en HTTPRoutes
tegelijk. Dat moet een aparte, bewuste handeling van een mens zijn, geen
neveneffect van een sync.
