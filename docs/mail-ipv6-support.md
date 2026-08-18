---
last_reviewed: 2026-08-18
owner: info@conduction.nl
---

# Standaardantwoorden IPv6 — voor support

Drie situaties, drie antwoorden. Kijk eerst naar de hostnaam, want dat bepaalt
alles. Twijfel je? Meet het:

    cluster-infra/scripts/check-cloudflare-proxy.sh <host>

Staat er een AAAA en `server: cloudflare`, dan is IPv6 geregeld.

## 1. Host onder `*.openwoo.app` (live) — al geregeld, klant hoeft niets

> Beste [naam],
>
> IPv6 is voor [hostnaam] geregeld. De site is via ons CDN bereikbaar over zowel
> IPv4 als IPv6; aan jullie kant is daar niets voor nodig, want deze hostnaam
> staat in een domein dat wij zelf beheren.
>
> Wil je het zelf controleren: internet.nl geeft voor deze site een positief
> resultaat op de IPv6-test.

## 2. Host op een eigen domein van de klant — twee DNS-records nodig

Gebruik de template in `mail-ipv6-klant.md`. Kort: eerst één CNAME voor de
certificaatvalidatie (er verschuift dan nog niets), later het A-record naar een
CNAME. Vraag de DCV-hostnaam op bij de beheerder; die staat in Cloudflare onder
SSL/TLS → Custom Hostnames.

Zet stap 2 pas in de mail nadat de edge gemeten is met
`check-saas-hostname.sh`.

## 3. Acceptatie-omgeving (`*.accept.openwoo.app`) — nog niet, en dat is bewust

> Beste [naam],
>
> IPv6 staat aan op de live-omgeving. Op de acceptatie-omgeving nog niet: die
> hostnaam ligt een niveau dieper en valt buiten het certificaat dat ons CDN
> daarvoor standaard uitgeeft. We kunnen dat aanzetten, maar dat vraagt een
> uitbreiding aan onze kant en die staat op de planning.
>
> Voor de audit maakt dat geen verschil: die kijkt naar de live-omgeving.

Zet dit **niet** zelf aan door de proxy-vlag op een accept-host te zetten. Dat
geeft een TLS-handshakefout — gemeten op `canary.accept.openwoo.app`
(2026-08-18). Er is Advanced Certificate Manager voor nodig; zie
`cloudflare-ipv6.md`.

## Wat je nooit belooft

- **Geen DANE/TLSA.** Kan niet via deze route en levert geen score op.
- **Geen CAA-verzoek.** Zonder CAA is er geen beperking. Zetten ze er toch een,
  dan moeten `letsencrypt.org`, `pki.goog` én `ssl.com` erin — de
  certificaatautoriteit wordt door het platform gekozen en kan wisselen.
- **Geen IPv6 op Nextcloud** (`*.commonground.nu`). Dat kan niet via het CDN: de
  uploadlimiet daar is 100 MB en Nextcloud staat op 16 GB.
