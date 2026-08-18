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

Let op wat de klant terugmeldt: het A-record moet **vervangen** worden door de
CNAME. Vraagt iemand om "het IPv4-adres van jullie cluster" of om een AAAA van
ons, dan gaat het mis — ons platform is IPv4-only en de IPv6-bereikbaarheid komt
van het CDN. Naast een CNAME mag geen A of AAAA staan.

## 3. Acceptatie-omgeving (`*.accept.openwoo.app`) — ook geregeld

Sinds 2026-08-18 doen de acceptatie-omgevingen mee. Er staat een apart
certificaat op `accept.openwoo.app` + `*.accept.openwoo.app`, waardoor die
hostnamen ook via het CDN kunnen. Antwoord dus hetzelfde als bij situatie 1:
geregeld, klant hoeft niets.

Controleer het wel per host, want de uitrol loopt per tenant:

    cluster-infra/scripts/check-cloudflare-proxy.sh <host>

Staat er `CN=accept.openwoo.app` in de certificaatregel, dan loopt die host via
het CDN. Staat er `CN=*.openwoo.app`, dan is die tenant nog niet omgezet; dat komt
goed zodra external-dns het record bijwerkt. Blijft het hangen, meld het bij de
beheerder — een handvol Applications volgt de huidige uitrol niet.

## Wat je nooit belooft

- **Geen DANE/TLSA.** Kan niet via deze route en levert geen score op.
- **Geen CAA-verzoek.** Zonder CAA is er geen beperking. Zetten ze er toch een,
  dan moeten `letsencrypt.org`, `pki.goog` én `ssl.com` erin — de
  certificaatautoriteit wordt door het platform gekozen en kan wisselen.
- **Geen IPv6 op Nextcloud** (`*.commonground.nu`). Dat kan niet via het CDN: de
  uploadlimiet daar is 100 MB en Nextcloud staat op 16 GB.
