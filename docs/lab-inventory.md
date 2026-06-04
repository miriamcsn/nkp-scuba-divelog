# Lab Inventory — NKP Sprint

## Nutanix infrastructure

- **AOS version:** 7.5
- **Hypervisor:** AHV
- **Cluster name(s):** `<cluster-name>`
- **Prism Element URL:** `https://<prism-element-ip>:9440`
- **Prism Central URL:** `https://<prism-central-ip>:9440`
- **Prism Central version:** pc.7.5.0.1

## Storage

- **Storage container name(s) usable for CSI / PVCs:** default
- **Notes:** any size limits, compression/dedup enabled, separate container for K8s? No

## Networking

- **Subnet:** `<subnet-name>`
- **IP range available for cluster VMs:** `<start-ip>` – `<end-ip>`
- **Gateway:** `<gateway-ip>`
- **VLAN ID:** `<vlan-id>`
- **DNS servers:** `<dns1>`, `<dns2>`
- **NTP servers:** `<ntp-server>`
- **Internet egress:** no
- **Load balancer / VIP available for ingress:** `<metallb-range>`

## NKP

- **NKP version available:** v2.17.1
- **Install method I'll use:** NKP Bundle
- **Management cluster status:** Bootstrap
- **Image registry available in lab:** `<registry-url-if-applicable>`
