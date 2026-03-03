# Cloudflare API Token

External DNS uses a Cloudflare API Token to create, update and delete DNS records in the `commonground.nu` zone. This document explains how to create the token and load it into the cluster.

## Token permissions

Use an **API Token** (not the Global API Key — that has full account access and is unnecessarily broad).

Required permissions:

| Category | Item | Permission |
|----------|------|------------|
| Zone | DNS | Edit |

Zone Resources: `Include` → `Specific zone` → `commonground.nu`

No other permissions are needed. Do not enable Cloudflare proxy permissions.

## Creating the token

1. Log in to [Cloudflare dashboard](https://dash.cloudflare.com)
2. Go to **My Profile** → **API Tokens** → **Create Token**
3. Choose **Create Custom Token**
4. Set:
   - Token name: `external-dns-conduction-cluster`
   - Permissions: `Zone` → `DNS` → `Edit`
   - Zone Resources: `Include` → `Specific zone` → `commonground.nu`
   - (Optional) Client IP filtering: restrict to your cluster's egress IP for extra security
   - TTL: set an expiry if your policy requires it
5. Click **Continue to summary** → **Create Token**
6. **Copy the token immediately** — Cloudflare only shows it once

## Loading the token into the cluster

```bash
kubectl create namespace external-dns

kubectl create secret generic cloudflare-credentials \
  -n external-dns \
  --from-literal=api-token=<paste-token-here>
```

Verify:
```bash
kubectl get secret cloudflare-credentials -n external-dns
```

The secret is referenced in `external-dns/values.yaml` as:
```yaml
env:
  - name: CF_API_TOKEN
    valueFrom:
      secretKeyRef:
        name: cloudflare-credentials
        key: api-token
```

## Token rotation

When rotating the token:
1. Create the new token in Cloudflare first
2. Update the secret: `kubectl create secret generic cloudflare-credentials -n external-dns --from-literal=api-token=<new-token> --dry-run=client -o yaml | kubectl apply -f -`
3. Restart External DNS to pick up the new token: `kubectl rollout restart deployment external-dns -n external-dns`
4. Verify DNS records are still being managed: check External DNS logs
5. Revoke the old token in Cloudflare

## Verifying External DNS works

After bootstrap, check the logs:
```bash
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns -f
```

Expected output when a record is created:
```
time="..." level=info msg="Desired change: CREATE roosendaal.migrate.commonground.nu A ..."
time="..." level=info msg="Desired change: CREATE roosendaal.migrate.commonground.nu TXT ..."
time="..." level=info msg="2 record(s) in zone commonground.nu were successfully updated"
```

The TXT record (`conduction-cluster-...`) is External DNS's ownership marker — do not delete it manually.

## What External DNS manages

- Creates an `A` (or `CNAME`) record for every hostname in an Ingress resource
- Creates a `TXT` ownership record alongside each DNS record
- Deletes both records automatically when the Ingress is removed
- Only touches records it owns (identified by `txtOwnerId: conduction-cluster`)
- Only operates within the `commonground.nu` zone — all other zones are ignored
