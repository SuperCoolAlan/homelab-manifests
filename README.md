# homelab-manifests
Kubernetes manifests and other mumbojumbo for my home lab.

## Kubernetes Host
Talos on a mini PC with a i7-4510U in it w/ 8Gb RAM.

## Storage
I repurposed my old gaming PC from high school and am running TrueNAS Scale. `democratic-csi` is used to connect to NFS hosted by TrueNAS while `longhorn` is used for on-cluster storage.

## Network
OPNsense and a dumb switch
