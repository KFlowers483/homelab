# k9s

Terminal UI for Kubernetes. Not infrastructure — nothing in this repo
depends on it — but it replaces about thirty `kubectl get` commands with
one screen, and when something is stuck it's faster at telling me why.

## Install (control plane)

```bash
curl -sL https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz | tar xz -C /tmp k9s
install -m 0755 /tmp/k9s /usr/local/bin/k9s
```

KUBECONFIG is already exported in `/root/.bashrc` so it just works as root.
If it opens to an empty cluster that's the config not being found, not the
cluster being down.

## From WSL

Better setup — real terminal, no SSH lag. Copy the kubeconfig and fix the
server address; k3s writes `127.0.0.1` into it because it assumes you're
on the node.

```bash
mkdir -p ~/.kube
scp kflowers@192.168.30.21:/etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i 's|127.0.0.1|192.168.30.21|' ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes
```

If that times out it's the pfSense rule between the LAN VLAN and VLAN 30
on 6443, not k9s.

## Keys worth knowing

| Key | Does |
|-----|------|
| `:` | command mode — `:po`, `:svc`, `:ing`, `:app` |
| `0` | all namespaces |
| `d` | describe |
| `l` | logs |
| `s` | shell into container |
| `y` | live YAML |
| `esc` | back |

`:app` lists ArgoCD Applications — sync status without opening the web UI.
