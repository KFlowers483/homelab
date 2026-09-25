# Planka

Self-hosted kanban board at `planka.home`. I'm using it to track WGU
coursework, Python practice, the RAG project and career prep in one
place instead of across notes apps and browser tabs. Three boards (WGU,
Projects, Career), same columns on each: Backlog, This Week, In Progress,
Blocked, Done.

It's also the first app I've added since Longhorn went in where the
storage was Longhorn from day one, not migrated over after.

## Why not the Helm chart

Planka has an official chart, but I skipped it for two reasons:

1. The chart repo is served from GitHub Pages and `index.yaml` has gone
   missing more than once (upstream issue #917). I don't want an ArgoCD
   sync depending on that.
2. It pulls in Postgres as a Bitnami subchart. I only need one small
   Postgres for one user, and I'd rather see exactly what's running.

So it's plain manifests, same layout as Vaultwarden and Uptime Kuma.

## What's in `k3s/planka/`

| File | What it is |
|------|------------|
| `postgres-pvc.yaml` | 2Gi Longhorn volume for the database |
| `postgres-deployment.yaml` | `postgres:16-alpine`, 1 replica |
| `postgres-service.yaml` | ClusterIP on 5432, only Planka talks to it |
| `pvc.yaml` | 2Gi Longhorn volume for `/app/data` (avatars, backgrounds, attachments) |
| `deployment.yaml` | `ghcr.io/plankanban/planka:2.2.1`, 1 replica |
| `service.yaml` | ClusterIP on 1337 |
| `certificate.yaml` | cert from `homelab-ca-issuer` |
| `ingressroute.yaml` | HTTPS route plus HTTP to HTTPS redirect |
| `networkpolicy.yaml` | default-deny, Traefik to Planka, Planka to Postgres |

Both Deployments use `Recreate` and stay at 1 replica. The volumes are
ReadWriteOnce, and Planka doesn't have a shared session store anyway.

## Secrets

Created by hand, not in Git. ArgoCD creates the namespace on the first
sync, and the pods sit in `CreateContainerConfigError` until these exist.

```bash
PGPASS=$(openssl rand -hex 24)

kubectl -n planka create secret generic planka-postgres \
  --from-literal=POSTGRES_PASSWORD="$PGPASS"

kubectl -n planka create secret generic planka-secrets \
  --from-literal=DATABASE_URL="postgresql://planka:${PGPASS}@planka-postgres:5432/planka" \
  --from-literal=SECRET_KEY="$(openssl rand -hex 32)" \
  --from-literal=DEFAULT_ADMIN_EMAIL="<email>" \
  --from-literal=DEFAULT_ADMIN_PASSWORD="<password>" \
  --from-literal=DEFAULT_ADMIN_NAME="<name>" \
  --from-literal=DEFAULT_ADMIN_USERNAME="<username>"
```

`PGPASS` has to be the same value in both secrets. That's why it goes
into a variable first instead of running `openssl` twice.

Leave `DEFAULT_ADMIN_EMAIL` set after first login. Planka uses it to stop
that account from being edited or deleted in the UI.

## Things that would have broken

- **Postgres on a fresh Longhorn volume.** The volume root has
  `lost+found` in it and `initdb` won't init into a non-empty directory.
  `PGDATA` points at a `pgdata/` subfolder to get around it.
- **Upload permissions.** The Planka image runs as the `node` user (uid
  1000) and the new volume is owned by root. `fsGroup: 1000` fixes the
  ownership on mount.
- **First boot race.** Planka runs its DB migrations on startup. If
  Postgres isn't up yet it just crashes and restarts until it is. An init
  container waits on `pg_isready` so the first boot is clean.
- **Trust auth.** Upstream's docker-compose runs Postgres with
  `POSTGRES_HOST_AUTH_METHOD=trust`, meaning no password. Fine on a laptop,
  not on a cluster network. I left it out, so the image falls back to
  password auth.

## Verify

```bash
kubectl -n argocd get applications.argoproj.io planka
kubectl -n planka get pods,pvc
kubectl -n planka logs deploy/planka
kubectl -n longhorn-system get volumes.longhorn.io
```

Both PVCs `Bound` on `longhorn`, both volumes `healthy` with 2 replicas,
then log in at `https://planka.home`.

## Not done yet

No backups. Same as everything else on Longhorn right now, the data only
exists as two replicas inside the cluster until the VLAN 40 backup target
is set up.
