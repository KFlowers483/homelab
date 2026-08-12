# Rancher

Management UI and control plane for Kubernetes clusters. I already have
ArgoCD for GitOps so Rancher isn't filling a gap — I'm running it because
it's the most common tool on the SUSE/Rancher side of the job market, and
it gives me somewhere to provision and import future clusters.

Honest note: Rancher and ArgoCD overlap. Rancher ships Fleet, its own
GitOps engine. I'm not using Fleet. ArgoCD stays the source of truth for
workloads; Rancher is for cluster lifecycle and visibility.

## Prerequisites

1. **cert-manager** — Rancher generates its own CA and needs cert-manager
   to issue the ingress cert. That's why it's the sync-wave ahead.
2. **Ingress controller with a named class** — Traefik, already here.
3. **DNS** — `rancher.home` → 192.168.30.200 in pfSense, same as
   argocd.home and whoami.home.
4. **RAM** — Rancher + webhook + Fleet is roughly 2–3GB settled, which is
   why `replicas: 1` instead of the chart default of 3.

## The Traefik gotcha

The Rancher chart does not set `ingressClassName`. Traefik ignores Ingress
objects that don't name a class it owns, so a default install gives you a
healthy pod, a healthy Service, an Ingress that exists, and a hostname
that 404s. Nothing logs an error. It just isn't routed.

```yaml
ingress:
  ingressClassName: traefik
```

Second one is the redirect loop — Rancher 302s HTTP to HTTPS, and if
Traefik isn't told to trust forwarded headers from the local subnets it
loses the original scheme and bounces forever. Hence the
`forwardedHeaders.trustedIPs` block in the Traefik values.

## Install

It's in Git, so this is a sync, not a `helm install`. The root Application
picks up `apps/rancher-app.yaml` on its own.

First sync is slow — Rancher runs post-install helm jobs and sits
Progressing for several minutes. That's what the retry backoff is for.

```bash
kubectl -n cattle-system get pods
kubectl -n cattle-system get ingress   # CLASS must be traefik, not <none>
```

## First login

The chart generates a bootstrap password rather than reading one from
values — deliberate, since values files live in Git.

```bash
kubectl -n cattle-system get secret bootstrap-secret \
  -o go-template='{{.data.bootstrapPassword|base64decode}}{{"\n"}}'
```

Browse `https://rancher.home`. Cert is from Rancher's generated CA so the
browser warns. The cluster Rancher runs on appears as `local`,
automatically — no import step.

## selfHeal is off on purpose

Rancher constantly writes back into its own resources. With selfHeal on,
ArgoCD reads those writes as drift and fights it in a loop. Off, with
prune off, until I've watched it sit clean for a week — then either
graduate it or add `ignoreDifferences` for the fields it mutates. Same
progression I used on Traefik.

## Status

- [x] cert-manager synced, ClusterIssuer Ready
- [x] pfSense host override for rancher.home
- [x] Rancher Application synced
- [x] Bootstrap password retrieved, first login done
- [ ] Decide whether to keep Fleet or disable it
- [ ] Graduate to selfHeal once drift behaviour is understood
