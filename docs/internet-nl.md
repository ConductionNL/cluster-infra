---
last_reviewed: 2026-08-18
owner: info@conduction.nl
---

# internet.nl — wat er meetelt voor 100%

Klantomgevingen moeten naar 100% op de internet.nl-websitetest. Dan moet je
weten welke subtests meewegen, want dat is niet wat je zou denken.

Bron: `checks/categories.py` en `checks/scoring.py` van
[internetstandards/Internet.nl](https://github.com/internetstandards/Internet.nl),
gelezen 2026-08-18. Een subtest telt mee als zijn slechtste status **FAIL** is;
staat die op NOTICE of INFO, dan wordt hij genegeerd in de score.

## Telt mee

| Categorie | Subtests |
|---|---|
| IPv6 | AAAA + bereikbaarheid van de **nameservers**, AAAA + bereikbaarheid + gelijke inhoud van de **webserver** |
| DNSSEC | bestaat, geldig |
| RPKI | ROA bestaat, ROA geldig (webserver-IP's én nameserver-IP's) |
| TLS | HTTPS beschikbaar, HTTPS geforceerd, HSTS, forward secrecy, ciphers, cipher-volgorde, TLS-versies, compressie uit, veilige renegotiation, cert vertrouwd, cert-sleutel, cert-signatuur, hostnaam-match, 0-RTT uit |

## Telt NIET mee

`Content-Security-Policy`, `X-Frame-Options`, `X-Content-Type-Options`,
`Referrer-Policy`, `security.txt`, **CAA**, **DANE** (bestaat/geldig),
OCSP-stapling, HTTP-compressie, client-renegotiation, Extended Master Secret en
— let op — de **hashfunctie bij key exchange**, oftewel het SHA-224-punt uit de
audit. Dat staat op `STATUS_INFO`.

Dat is geen vrijbrief om ze te laten liggen: een auditor noemt ze wél, en
`security.txt` en CSP zijn gewoon goed werk. Maar ze leveren geen procent op.

## Verantwoordelijkheid per categorie

| Categorie | Bij ons | Bij de klant |
|---|---|---|
| IPv6 webserver | ja — de LB is IPv4-only, zie `cloudflare-ipv6.md` | — |
| IPv6 nameservers | alleen voor `commonground.nu` (Cloudflare, heeft IPv6) | eigen domein: hun DNS-leverancier |
| DNSSEC | `commonground.nu` staat bij Cloudflare | eigen domein: hun zone |
| RPKI | ja, ons prefix | hun nameserver-prefixen |
| TLS | ja, volledig | — |

## Gemeten stand

Meten: `./scripts/internetnl-precheck.sh --file <hostlijst>`. Het script dekt de
meetellende subtests die van buiten te zien zijn; het meet **niet** de
RPKI-status van de nameserver-IP's, de cipher-volgorde en 0-RTT — die drie
blijven werk voor de echte internet.nl-test.

Gemeten 2026-08-18 met dat script: **33 klanthosts** (eigen domeinen) en een
steekproef van 6 van de 121 `*.commonground.nu`-hosts. De steekproef was
onderling identiek, wat logisch is: één zone, één loadbalancer, één nginx.

| Subtest | Klanthosts (33) | commonground.nu (steekproef) |
|---|---|---|
| IPv6 webserver | **30× FAIL**, 3× OK | FAIL |
| IPv6 nameservers | 33× OK | OK |
| DNSSEC | 31× OK, 2× FAIL | OK |
| RPKI webserver-IP | 29× `valid` (AS25151), rest elders | `valid` |
| HSTS ≥ 1 jaar | 31× OK, 2× FAIL | OK |
| TLS 1.3 | 32× OK, 1× FAIL | OK |
| TLS 1.0/1.1 geweigerd | 33× OK | OK |
| Certificaat vertrouwd | 31× OK, 2× FAIL | OK |
| Sleutel | 15× ECDSA, 4× RSA-4096, 13× RSA-2048 | RSA-2048 |

De drempels van internet.nl voor de sleutel staan in
`checks/tasks/tls/tls_constants.py`: **RSA is pas "goed" vanaf 3072 bit**, 2048
is *phase out*, en van de EC-curves is alleen `secp224r1` phase out. ECDSA P-256
en RSA-4096 zijn dus goed; de 13 hosts op RSA-2048 halen geen 100%.

RPKI van ons prefix is in orde: AS25151, ROA voor `81.24.0.0/20`, status
`valid`. Daar is geen werk aan.

Drie klanthosts hebben al IPv6 en staan dus niet meer achter onze LB:
`open.ede.nl` (AS60781), `open.lansingerland.nl` (AS20847) en `opencatalogi.nl`
(AS13335, onze eigen Cloudflare-proxy). De eerste twee hebben hier nog wel een
Ingress staan — die is stale.

Twee echte defecten, los van IPv6:

- `open.noorderzijlvest.nl` serveert **alleen het leaf-certificaat**, zonder
  intermediate (`unable to get local issuer certificate`). Het is een
  Sectigo-cert, geldig tot 27 november 2026, handmatig gezaaid (`issuer: none`).
  Dat faalt de subtest "certificaat vertrouwd" en dat weegt mee.
- `open-oud.noaberkracht.nl` heeft geen A-record en antwoordt niet. Dode Ingress.

## SHA-224 uitzetten

Weegt niet mee in de score (`kex_hash_func` staat op INFO) maar staat wel in de
audit. De ECDSA-omzetting loste het **niet** op: `RSA+SHA224` wordt sindsdien
geweigerd omdat de sleutel geen RSA meer is, maar `ECDSA+SHA224` levert nog een
signatuur op. Gemeten 2026-08-18 op beide Noaberkracht-hosts.

De fix is een globale `http-snippet` op de controller-ConfigMap, en die ConfigMap
staat in geen enkele repo. Daarom niet met de hand patchen maar via
`./scripts/tls-sigalgs-apply.sh`: die maakt eerst een back-up, patcht, verifieert
dat SHA-224 écht geweigerd wordt én dat de hosts nog antwoorden, en draait zelf
terug als dat niet klopt. Zonder `--apply` is het een dry-run.

## Toezicht

| Wat | Waar | Wanneer |
|---|---|---|
| render/lint/secrets | pre-push-hooks + `ci.yml` | elke push |
| buitenkant-meting van de klanthosts | `.github/workflows/internetnl.yml` | maandag 06:00 UTC, en handmatig |
| certificaat verloopt binnen 14 dagen | `monitoring` → `CertificateExpiringSoon` | continu |

De periodieke meting draait op GitHub-runners en niet in de monitoring-stack:
deze check mag niet afhangen van één cluster. Hij draait `internetnl-precheck.sh`
met `--strict` tegen `hosts/internetnl.txt` en faalt alleen op gaten die niet in
`hosts/internetnl-allow.txt` staan. Die allowlist is een werkvoorraad, geen
vrijbrief — hij hoort te krimpen.

Een live meting hoort **niet** in een pre-push-hook. Vóór de deploy bestaat de
stand die je wil meten nog niet, en een netwerkafhankelijke gate maakt de gate
onbetrouwbaar in plaats van strenger.

Twee gaten in het toezicht zoals het nu staat:

- `CertificateExpiringSoon` leest `certmanager_certificate_expiration_timestamp_seconds`
  en ziet dus **alleen certificaten die cert-manager beheert**. Het handmatig
  gezaaide Sectigo-certificaat van `open.noorderzijlvest.nl` (tot 27 november
  2026) wordt door niets bewaakt. Een blackbox-exporter met
  `probe_ssl_earliest_cert_expiry` zou dat wel zien, plus een kapotte chain en
  een host die niet over IPv6 te bereiken is. Nog niet ingericht.
- De wekelijkse meting dekt de 33 klanthosts, niet de 121
  `*.commonground.nu`-hosts. Die staan op dezelfde LB en dezelfde nginx, dus de
  uitkomst is voorspelbaar — maar voorspeld is niet gemeten.

## Wat er voor 100% moet gebeuren

Op volgorde van gewicht:

1. **IPv6** — 30 van de 33 klanthosts en alle 121 commonground-hosts. Dit is het
   enige punt dat álle hosts tegelijk raakt. Route: `cloudflare-ipv6.md`, of
   wachten op IPv6 bij de hostingleverancier.
2. **Sleutel naar ECDSA of RSA-3072+** — 13 hosts staan nog op RSA-2048. De
   ApplicationSet zet ECDSA inmiddels bij de issuer-tak; wat overblijft zijn de
   `issuer: none`-tenants met een handmatig gezaaid certificaat. Die moeten per
   tenant, met de klant.
3. **`open.noorderzijlvest.nl` chain repareren** — het secret opnieuw zaaien met
   fullchain in plaats van alleen het leaf.
4. **`open-oud.noaberkracht.nl` opruimen** en de stale Ingresses van
   `open.ede.nl` en `open.lansingerland.nl` nalopen.
5. **DNSSEC op `conduction.nl`** — onze eigen zone, twee hosts (`demo.`, `test.`).

Wat níét op deze lijst hoort en toch vaak genoemd wordt: CAA, DANE, de
security-headers, `security.txt` en de SHA-224-hashfunctie. Goed werk, nul
procent.
