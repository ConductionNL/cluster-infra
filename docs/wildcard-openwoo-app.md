---
last_reviewed: 2026-08-19
owner: info@conduction.nl
---

# Bevinding (opgelost) — de wildcard `*.openwoo.app` ving elke typefout

**Status:** opgelost 2026-08-19 — wildcard verwijderd, nagemeten.
**Eigenaar:** platformbeheer cluster-infra (`info@conduction.nl`, CODEOWNERS `docs/`).
**Gemeten:** 2026-08-19, 12:37 CEST (bevinding) en 12:45 CEST (na het weghalen).
**Herkomst:** losgetrokken uit het IPv6-dossier; dit staat op zichzelf en heeft
een burgerzichtbaar effect, terwijl de IPv6-route dat niet heeft.

## Wat er stond

In de zone `openwoo.app` stond een wildcard:

    *.openwoo.app.  A  81.24.6.45

Dat adres is geen service in dit cluster — hier draaien `81.24.6.82` (nginx) en
`81.24.11.239` (Envoy). Elke naam onder `openwoo.app` zonder eigen DNS-record
valt dus door naar een host die wij niet beheren. In geen enkele repo onder
`~/CONDUCTION` staat een verwijzing naar `81.24.6.45`; het adres zit wel in
hetzelfde netblok als onze loadbalancer (`81.24.4.0/22`, `netname: FUGA_AMS`,
NL), dus het staat vermoedelijk bij dezelfde hostingleverancier.

## Wat een bezoeker kreeg

Gemeten om 12:37 CEST, vóór het weghalen, met een verzonnen naam en met een
realistische typefout:

    dig +short A nietbestaand-test.openwoo.app     # 81.24.6.45
    dig +short A dinkeland.openwoo.app             # 81.24.6.45 (typefout)
    dig +short A dinkelland.openwoo.app            # 81.24.6.45 (bestaat óók niet als record)

    openssl s_client -connect 81.24.6.45:443 -servername nietbestaand-test.openwoo.app
    subject=O=Acme Co, CN=Kubernetes Ingress Controller Fake Certificate
    Verify return code: 18 (self-signed certificate)

    curl -skI --resolve nietbestaand-test.openwoo.app:443:81.24.6.45 https://nietbestaand-test.openwoo.app/
    HTTP/2 200
    content-length: 3200785

Twee dingen die dit erger maakten dan "een dood record":

1. **De browser geeft een certificaatfout** op een naam die op een
   gemeentelijke WOO-site lijkt. Dat is het scherm waar we burgers juist leren
   níét door te klikken.
2. **Klikt iemand er wel door, dan komt er een 200** met een pagina van 3,2 MB:
   een generieke OpenCatalogi-frontend (`<title>Woo Website`, 339 verwijzingen
   naar `opencatalogi`). Geen 404, geen foutpagina — een site die eruitziet als
   een echte WOO-site maar niet die van de gemeente is, op een host die wij niet
   beheren en waarvan we de inhoud niet kunnen garanderen.

## Wat het raakte

Niets, zo blijkt bij nameten. De Configuration Rule zondert `openwoo.app`,
`www.openwoo.app` en `conduction.openwoo.app` uit van Full (strict), en
`cloudflare-ipv6.md` gaf daarvoor als reden dat die drie op `81.24.6.45`
uitkwamen. Dat is onjuist: het zijn CNAME's naar `conductionnl.github.io`
respectievelijk de vier GitHub-Pages-A-records `185.199.108-111.153`, met
`CN=*.github.io` op de origin (geldige Let's Encrypt-keten, verkeerde naam).
Gemeten 2026-08-19 13:00 CEST. Die uitzondering staat dus volledig los van de
wildcard en van dit dossier; gecorrigeerd in
[cloudflare-ipv6.md](cloudflare-ipv6.md).

## Wat er is gedaan

De wildcard is op 2026-08-19 door de zone-beheerder verwijderd; de host achter
`81.24.6.45` bleek een gedeprecieerd legacy-cluster. Dat is optie 1 uit de
oorspronkelijke afweging (de andere twee waren: wildcard naar een beheerde host
met een schone 404, of niets doen).

Nagemeten om 12:45 CEST, autoritatief tegen `bailey.ns.cloudflare.com` om
resolver-cache uit te sluiten:

| Meting | Uitkomst |
|---|---|
| verzonnen naam, typefout, en `dinkelland.openwoo.app` | **NXDOMAIN** — geen certfout, geen vreemde site |
| `openwoo.app`, `www`, `conduction`, `canary` | eigen geproxiede records, ongewijzigd |
| alle 67 hosts met een Ingress onder `openwoo.app` | 67 × NOERROR, **0 kapot** |
| 34 namen uit Certificate Transparency (certspotter) | 29 resolven; 5 NXDOMAIN |

Die vijf zijn geen collateral damage: `conduction-straattest`, `gooisemeren`,
`hofvantwente`, `zuiddrecht-react` en `zutphen` — alle onder
`accept.openwoo.app`, en geen van de vijf heeft een Ingress in het cluster (234
Ingress-hosts gecontroleerd). Het zijn historische certificaten van tenants die
niet meer bestaan. Een wildcard op één label (`*.openwoo.app`) dekte die namen
met twee labels ook nooit.

De Configuration Rule houdt zijn uitzonderingen voor `openwoo.app`,
`www.openwoo.app` en `conduction.openwoo.app`, maar om een andere reden dan tot
nu toe gedocumenteerd stond: die drie staan op GitHub Pages, niet op
`81.24.6.45`. Zie de sectie hierboven.

## Meten

    dig +short A nietbestaand-$(date +%s).openwoo.app
    openssl s_client -connect 81.24.6.45:443 -servername test.openwoo.app </dev/null 2>&1 | grep subject=

De bevinding is opgelost wanneer een niet-bestaande naam onder `openwoo.app`
óf `NXDOMAIN` geeft, óf een geldig certificaat met een 404. Sinds 2026-08-19 is
dat het eerste. Deze pagina blijft staan als audit-spoor; komt de wildcard ooit
terug, dan is dit de meting waar hij tegen afgezet wordt.
