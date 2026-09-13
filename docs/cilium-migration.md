# Flannel → Cilium cutover

Flannel enforces no NetworkPolicy. Cilium (`talos/cluster-services/cilium`) replaces it as the CNI only; kube-proxy keeps owning Services.

## Constraints

- **Full outage, ~20–30 min.** Every pod restarts on the new network. blackbox is the only control-plane node.
- Argo runs on the pod network. It can install Cilium while flannel is still up, but it can't help once networking is broken. The manual fallback is step 3b.
- Don't merge the `cilium` branch early. Once Argo sees `talos/cluster-services/cilium` on `main`, it installs Cilium. `cni.exclusive` then renames flannel's CNI config, so new pods land on Cilium and can't reach old flannel pods.
- Avoid the p2pool CronJobs at 14:00 and 19:00 Central.
- Talos doesn't remove flannel when the CNI setting changes. Delete it by hand (step 4).

## Steps

```sh
K=(kubectl --kubeconfig ~/.kube/clusters/homelab.yaml)
```

1. **Talos config.** Stops Talos re-applying flannel. It doesn't touch running pods.
   ```sh
   cat > /tmp/cni-none.yaml <<'EOF'
   cluster:
     network:
       cni:
         name: none
   EOF
   talosctl -n 10.0.1.47 patch mc --patch @/tmp/cni-none.yaml
   talosctl -n 10.0.1.12 patch mc --patch @/tmp/cni-none.yaml
   ```
   Mirror the change into the gitignored local `talos/config/controlplane-blackbox.yaml` and `worker-ramhaus-nvme.yaml`, so a later `apply-config` doesn't bring flannel back.

2. **Merge `cilium` to `main`** and wait for the Argo `cilium` app to create the DaemonSets.
   ```sh
   "${K[@]}" -n kube-system rollout status ds/cilium --timeout=5m
   ```

3. **If Argo can't sync** (3b): apply the same render by hand. Argo adopts it afterwards.
   ```sh
   kustomize build --enable-helm --enable-exec --enable-alpha-plugins talos/cluster-services/cilium \
     | "${K[@]}" apply --server-side -f -
   ```

4. **Remove flannel.**
   ```sh
   "${K[@]}" -n kube-system delete ds/kube-flannel cm/kube-flannel-cfg sa/flannel
   "${K[@]}" delete clusterrolebinding/flannel clusterrole/flannel
   ```

5. **Reboot ramhaus, then blackbox.** Clears flannel's interfaces, routes and rules; every pod comes back on Cilium.
   ```sh
   talosctl -n 10.0.1.12 reboot --wait
   talosctl -n 10.0.1.47 reboot --wait
   ```

## Verify

```sh
"${K[@]}" -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief
"${K[@]}" get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
"${K[@]}" -n kube-system get ds kube-flannel   # expect NotFound
```

- **Cross-node pod traffic and DNS:** `kubectl run` a busybox pod on each node, then `nslookup kubernetes.default` and `wget` a Service on the other node.
- **LoadBalancer IPs:** traefik `10.0.7.200` (open a `*.local.asandov.com` page), piper `.201:10200`, unifi `.202:8443`. MetalLB BGP sessions must show Established in OPNsense.
- **External paths:** jellyfin.asandov.com through the WireGuard tunnel, monerod outbound peers (Monero dashboard), p2pool back to Ready from its cache.
- **aldo VM:** `virtctl ssh`, or check the VMI is Running with an IP.
- **Hubble:** hubble.local.asandov.com loads behind Authentik; Grafana has a Cilium folder.

## Rollback

Revert the merge (Argo prunes Cilium). Patch both nodes back to `cni.name: flannel`, which Talos re-applies, then reboot both nodes.
