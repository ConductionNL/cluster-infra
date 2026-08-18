---
last_reviewed: 2026-08-18
owner: info@conduction.nl
---

# IPv6 via Cloudflare

Onze loadbalancer is IPv4-only. Cloudflare's edge is dual-stack en genereert voor
geproxiede records automatisch AAAA. Twee routes, afhankelijk van wie de zone
bezit.

| Host | Route | Kosten |
|---|---|---|
| eigen zone (`*.openwoo.app`, `*.commonground.nu`) | proxy-vlag aanzetten | $0 |
| klantdomein (`open.dinkelland.nl`) | Cloudflare for SaaS custom hostname | $0 tot 100 hostnamen, daarna $0,10/mnd |

Zone-delegatie van één subdomein (*subdomain setup*) kan **niet**: Enterprise-only.

## Test A — proxy op een eigen host

1. Zone `openwoo.app` → SSL/TLS → Overview: modus moet **Full (strict)** zijn.
2. DNS → Records → `canary` → Proxy status op *Proxied*.
3. Meten, vóór en na: `./scripts/check-cloudflare-proxy.sh canary.openwoo.app`
4. `--watch 180` erbij om te zien of external-dns de vlag terugdraait
   (`policy: sync`, `interval: 1m`). Klapt hij terug, dan moet het via de
   `cloudflare-proxied`-annotatie in external-dns, niet via het portaal.
5. Terug: Proxy status op *DNS only*.

## Test B — Cloudflare for SaaS

Stap 1–4 zijn bij ons en veranderen niets voor de klant.

1. Zone `openwoo.app` → SSL/TLS → **Custom Hostnames** → aanzetten.
2. DNS → Records → `customers` → A `81.24.6.82` → **Proxied**. Dat wordt de
   fallback origin; instellen op de Custom-Hostnames-pagina, wachten op *Active*.
3. **Add Custom Hostname** → de klanthost. Cloudflare-managed cert, minimum
   TLS 1.2, validatie via **Delegated DCV**.
4. Noteer de DCV-hostnaam (`<uuid>.dcv.cloudflare.com`) van dezelfde pagina.
5. De klant zet:

       open.dinkelland.nl.                 CNAME  customers.openwoo.app.
       _acme-challenge.open.dinkelland.nl. CNAME  open.dinkelland.nl.<uuid>.dcv.cloudflare.com.
       open.dinkelland.nl.                 CAA    0 issue "letsencrypt.org"
       open.dinkelland.nl.                 CAA    0 issue "pki.goog; cansignhttpexchanges=yes"
       open.dinkelland.nl.                 CAA    0 issue "ssl.com"

6. Verifiëren: `./scripts/check-saas-hostname.sh open.dinkelland.nl`
   Vóór cutover kan dat al tegen de edge: `EDGE_IP=<cf-ip> ./scripts/check-saas-hostname.sh …`
7. Terugrollen is bij de klant: CNAME weer A-records.

Bij de fallback-origin-route stuurt Cloudflare SNI = klanthostnaam, dus ons
bestaande Let's Encrypt-certificaat volstaat en Full (strict) houdt. Gebruik
**geen** custom origin per hostname: dan wijkt SNI af van de Host-header en is
strict onmogelijk zonder Enterprise-entitlement.

## Wat dit raakt

- **Origin-certificaat**: met de proxy ervoor loopt HTTP-01 door de edge. Een
  Cloudflare Origin CA-certificaat haalt cert-manager voor die hosts uit de
  keten. Keuze, nog niet gemaakt.
- **Onze eigen regel** "geen proxy aanzetten, dat breekt HTTP-01" staat in
  `react-base/CLAUDE.md` en hier. Herzien op basis van test A, niet negeren.
- **Client-IP**: de origin ziet Cloudflare-adressen. Logging en rate-limiting
  gaan op `CF-Connecting-IP`; de PROXY-protocol-keten van de OpenStack-LB blijft
  eronder.
- **Edge-cert** is een bundel ECDSA P-256 + RSA-2048. Een audit kan opnieuw over
  RSA-2048 vallen; dat is dan Cloudflare's keuze.
- **Verwerkersovereenkomst**: van de klant, niet van ons.

## Bronnen

- <https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/plans/>
- <https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/start/getting-started/>
- <https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/reference/connection-details/>
- <https://developers.cloudflare.com/dns/zone-setups/subdomain-setup/>
- <https://developers.cloudflare.com/network/ipv6-compatibility/>
- <https://developers.cloudflare.com/ssl/reference/certificate-authorities/>
