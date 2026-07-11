k3s Cluster Setup

k3s running on Rocky Linux 9.7 VMs hosted on the Proxmox cluster. Control plane on pve1, workers on pve2 and pve3.

VMs

VMRoleNodeIPk3s-controlControl Planepve1192.168.30.21k3s-worker1Workerpve2192.168.30.22k3s-worker2Workerpve3192.168.30.23

VM Specs


OS: Rocky Linux 9.7 Minimal
CPU: 2 cores each
RAM: 4GB (control plane), 6GB (workers)
Disk: 32GB each
Network: VLAN 30 (192.168.30.0/24)


Firewall Configuration

Rocky Linux ships with firewalld enabled, and k3s needs more than the default openings. The k3s docs actually recommend just disabling firewalld, but I wanted to keep it on and learn the rules instead.

Ports opened on the control plane:

PortProtocolPurpose6443TCPKubernetes API server6444TCPk3s supervisor10250TCPKubelet (logs, exec, metrics)8472UDPFlannel VXLAN (pod network between nodes)

Workers only need 10250 and 8472 — they initiate connections to the control plane, so 6443/6444 stay closed on them.

bashfirewall-cmd --permanent --add-port=10250/tcp
firewall-cmd --permanent --add-port=8472/udp
firewall-cmd --reload

k3s internal networks also need to be trusted on every node, otherwise firewalld drops the cluster's own traffic and things like CoreDNS fail in ways that are hard to trace:

bashfirewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16
firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16
firewall-cmd --reload

10.42.0.0/16 is the pod network, 10.43.0.0/16 is the service network.

MetalLB

k3s ships with its own load balancer (ServiceLB) and a bundled Traefik install. I disabled both — anything k3s manages on its own lives outside my control and outside this repo, and the end goal is everything defined in Git. MetalLB replaces ServiceLB, and Traefik will get reinstalled later via Helm where I own the config.

Disabled the bundled components on the control plane:

bashcat > /etc/rancher/k3s/config.yaml << 'EOF'
disable:
  - servicelb
  - traefik
EOF
systemctl restart k3s

k3s reads that config file at startup like command-line flags, and on restart it cleaned up the old traefik and svclb pods on its own.

MetalLB speakers gossip with each other over port 7946 to coordinate which node announces which IP, so this got opened on all three nodes:

bashfirewall-cmd --permanent --add-port=7946/tcp
firewall-cmd --permanent --add-port=7946/udp
firewall-cmd --reload

Installed MetalLB v0.15.2 and gave it a pool of addresses on VLAN 30:

bashkubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml

yamlapiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: vlan30-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.30.200-192.168.30.220
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: vlan30-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - vlan30-pool

The pool is the range MetalLB is allowed to hand out (kept outside the DHCP range on VLAN 30). The L2Advertisement makes a speaker pod answer ARP for whatever IPs get assigned, so the rest of the network knows where to send traffic.

Verified with a throwaway nginx deployment exposed as a LoadBalancer service — it pulled 192.168.30.201 from the pool and loaded from a browser on the LAN, across VLANs. Note it grabbed .201, not .200 — MetalLB doesn't assign sequentially, it just picks a free address. Deleted the test after.

Traefik via Helm

First time using Helm. Short version: it's a package manager for Kubernetes — a chart is a bundle of YAML templates, you supply a values file for the settings you want to change, and Helm installs the whole stack as one release it can upgrade or roll back later.

Installing the Helm CLI failed at first because Rocky Minimal doesn't ship with tar (or git). Minimal means minimal.

bashdnf install -y tar git
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

Helm also couldn't find the cluster ("localhost:8080 connection refused") — k3s puts its kubeconfig in a nonstandard spot and the bundled kubectl knows about it but Helm doesn't:

bashecho 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> /root/.bashrc

The actual install. Only one value overridden from chart defaults — pinning Traefik to a static IP from the MetalLB pool, since this is the front door everything will point at and I don't want it moving:

yaml# traefik-values.yaml
service:
  annotations:
    metallb.io/loadBalancerIPs: 192.168.30.200

bashhelm repo add traefik https://traefik.github.io/charts
helm repo update
helm install traefik traefik/traefik --namespace traefik --create-namespace -f traefik-values.yaml

Troubleshooting: the IP that wouldn't assign

The new service sat at <pending>. kubectl describe svc showed the reason in Events: the old bundled Traefik's Service object was still alive in kube-system and holding .200. Disabling traefik in k3s config killed the pods but this Service survived — and it's also why my MetalLB test service got .201 instead of .200 last time. The clue was there and I missed it.

Deleting it didn't work either — kubectl said deleted, but the object stayed, AGE still 36d. Turns out it had a finalizer from ServiceLB (a cleanup step that has to sign off before an object is removed), and ServiceLB is disabled now, so nothing was ever going to sign off. Stuck terminating forever.

bashkubectl patch svc traefik -n kube-system -p '{"metadata":{"finalizers":[]}}' --type=merge

Force-clearing finalizers skips whatever cleanup the owner intended, so it's only safe when the owning controller is confirmed gone — which it was. The moment the old service actually deleted, the MetalLB controller assigned .200 to the new Traefik on its own. No retry needed — that's the reconciliation loop doing its job.

Verified: one traefik service cluster-wide, EXTERNAL-IP 192.168.30.200, and browsing to it returns a 404 from Traefik — which is correct, since no routes are defined yet.

Next up: first IngressRoute so Traefik has something to route.

First IngressRoute: whoami

Traefik was up with its LoadBalancer IP but had nothing to route, so I deployed the standard whoami test app to prove the full path: DNS → MetalLB VIP → Traefik → pod.

Three manifests in k3s/whoami/:


deployment.yaml — the traefik/whoami container
service.yaml — ClusterIP service in front of it
ingressroute.yaml — Traefik IngressRoute matching Host(`whoami.home`) on the web entrypoint


Applied them with kubectl, then added a DNS Resolver host override in pfSense pointing whoami.home at 192.168.30.200. Traefik does the actual routing by hostname — every .home service shares the same VIP, and the Host header decides which backend gets the request.

Hitting http://whoami.home returned the pod's hostname and headers. Ingress stack confirmed working end to end.

Installing ArgoCD

With ingress working, next step was GitOps. Installed ArgoCD into its own namespace from the official stable manifest:

bashkubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

No new firewall ports needed — ArgoCD talks to the Kubernetes API and gets reached through the existing Traefik entrypoint, all of which rides the pod/service networks already trusted in firewalld.

Gotcha — CRD too large for client-side apply. The ApplicationSet CRD blows past the 262KB annotation limit that client-side kubectl apply uses to track state (metadata.annotations: Too long). The fix is server-side apply (--server-side --force-conflicts), which skips the last-applied-configuration annotation entirely. If you already tried a normal apply and it half-failed, re-running with server-side apply cleans it up.

Exposed the UI through the existing ingress stack instead of port-forwarding: k3s/argocd/ingressroute.yaml routes Host(`argocd.home`) on the web entrypoint to the argocd-server service on port 80, plus a matching pfSense host override for argocd.home. Since this is plain HTTP for now, argocd-server runs in insecure mode (server.insecure: "true" in the argocd-cmd-params-cm ConfigMap, then restart the argocd-server deployment) so it doesn't try to redirect everything to TLS it isn't serving. Proper TLS is on the list once cert-manager is in.

First app managed through ArgoCD was whoami — an Application manifest in apps/whoami-app.yaml pointing at k3s/whoami/ in this repo. Since the manifests in Git were identical to what was already live, ArgoCD adopted the running resources with a clean diff. From this point on, whoami is deployed by Git, not by me.

Bringing MetalLB and Traefik under ArgoCD

whoami was easy because it was born simple. MetalLB and Traefik were already running from manual installs, so they had to be adopted — brought under ArgoCD management without recreating or breaking them. Two different patterns depending on how each was installed.

MetalLB: vendor the manifest

MetalLB was installed from the upstream manifest, so the move was to vendor that exact manifest (v0.15.2) into the repo at k3s/metallb/ alongside the existing pool.yaml, and point an Application at the directory (apps/metallb-app.yaml).

One ordering problem: the IPAddressPool and L2Advertisement are custom resources whose CRDs come from the install manifest itself. If ArgoCD applies the pool before the CRDs exist, the sync fails. Sync-wave annotations fix this — the install manifest gets an earlier wave than the pool config, so ArgoCD applies them in order:

yamlmetadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"

First sync was manual so I could read the diff before trusting it. It came back clean — same manifest, same config — so ArgoCD adopted everything in place without restarting a single pod.

Traefik: multi-source Application

Traefik was installed via Helm, which is a different problem: the source of truth is a chart plus a values file, not raw manifests. First step was moving traefik-values.yaml into the repo at k3s/traefik/values.yaml — ArgoCD can only render values it can pull from a source.

ArgoCD handles the Helm case with a multi-source Application (apps/traefik-app.yaml): one source pulls the chart from the Traefik Helm repo (pinned to chart 40.3.0), the second source is this Git repo, referenced as $values so the chart renders with the values file:

yamlsources:
  - repoURL: https://traefik.github.io/charts
    chart: traefik
    targetRevision: 40.3.0
    helm:
      valueFiles:
        - $values/k3s/traefik/values.yaml
  - repoURL: https://github.com/KFlowers483/homelab.git
    targetRevision: main
    ref: values

Same adoption approach: manual sync first, read the diff. Worth knowing: ArgoCD only reconciles fields the rendered chart actually declares. Anything the chart doesn't set, ArgoCD leaves alone — which is exactly why adoption didn't clobber the live install.

Graduating to automated selfHeal

Both adopted apps started on manual sync so I could read the diff and watch a few syncs before letting ArgoCD act on its own. Once each had been Synced and Healthy through normal operation, I flipped them to automated selfHeal — MetalLB first, then Traefik:

yamlsyncPolicy:
  automated:
    selfHeal: true
    prune: false

selfHeal: true means live drift gets reverted automatically — if someone (me) hand-edits a managed resource with kubectl, ArgoCD puts it back within its refresh cycle. That closes the classic failure mode where the cluster quietly diverges from the repo one "temporary" manual fix at a time.

prune stays false on purpose. selfHeal corrects fields; prune deletes live resources that disappear from Git. Deletion stays a human decision until the repo structure has been stable a lot longer.

The workflow for changing anything ArgoCD manages is now: edit in the repo, commit, push, let ArgoCD roll it out. The one exception is the Application manifests themselves in apps/ — nothing manages those yet, so they're applied by hand after pushing. An app-of-apps root Application would close that gap; it's on the list.

Status


 VMs provisioned
 Rocky Linux 9.7 installed
 System updated
 k3s installed on control plane
 Workers joined to cluster
 Firewall ports opened
 MetalLB configured (ArgoCD-managed, selfHeal on)
 Traefik configured (ArgoCD-managed, selfHeal on)
 ArgoCD installed, whoami deployed via GitOps
 cert-manager + internal TLS
 Prometheus + Grafana
 Longhorn storage
 app-of-apps root Application
 Vaultwarden
