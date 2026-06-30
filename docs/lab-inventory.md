# Lab Inventory — NKP Sprint

## Environment A (source / management host)

### Nutanix infrastructure
- **AOS version:** 7.5
- **Hypervisor:** AHV
- **Prism Element cluster name:** `<pe-cluster-a>`
- **Prism Element URL:** `https://<pe-a-ip>:9440`
- **Prism Central URL:** `https://<pc-a-ip>:9440`
- **Prism Central version:** pc.7.5.0.1

### Storage
- **Storage container for CSI / PVCs:** default

### Networking
- **Subnet:** `<subnet-a>`
- **IP range for cluster VMs:** `<start-ip-a>` – `<end-ip-a>`
- **Gateway:** `<gw-a>`
- **VLAN ID:** `<vlan-a>`
- **DNS servers:** `<dns1-a>`, `<dns2-a>`
- **NTP servers:** `<ntp-a>`
- **Internet egress:** no
- **MetalLB / VIP range:** `<metallb-range-a>`

### VM image
- **Node OS image uploaded to PC:** `<node-image-a>` (e.g. `nkp-rhel-9.4-...`)

---

## Environment B (target)

### Nutanix infrastructure
- **AOS version:** 7.5
- **Hypervisor:** AHV
- **Prism Element cluster name:** `<pe-cluster-b>`
- **Prism Element URL:** `https://<pe-b-ip>:9440`
- **Prism Central URL:** `https://<pc-b-ip>:9440`
- **Prism Central version:** pc.7.5.0.1

### Storage
- **Storage container for CSI / PVCs:** default

### Networking
- **Subnet:** `<subnet-b>`
- **IP range for cluster VMs:** `<start-ip-b>` – `<end-ip-b>`
- **Gateway:** `<gw-b>`
- **VLAN ID:** `<vlan-b>`
- **DNS servers:** `<dns1-b>`, `<dns2-b>`
- **NTP servers:** `<ntp-b>`
- **Internet egress:** no
- **MetalLB / VIP range:** `<metallb-range-b>`

### VM image
- **Node OS image uploaded to PC:** `<node-image-b>` (e.g. `nkp-rhel-9.4-...`)

---

## NKP

- **NKP version:** v2.17.1
- **Install method:** NKP Bundle (air-gapped)
- **Topology:** 1 management cluster (env A) + 2 workload clusters (wlc-a in env A, wlc-b in env B)
- **Image registry (env A):** `<registry-a-url>` (must be reachable from both envs, or mirror per env)
- **Image registry (env B):** `<registry-b-url>`
- **NKP bundle path on bastion:** `~/nkp-bundle/`

## Cluster names (used in nkp CLI commands)

| Role | Name | Environment |
|------|------|-------------|
| Management | `nkp-mgmt` | A |
| Workload A | `nkp-wlc-a` | A |
| Workload B | `nkp-wlc-b` | B |

## Bastion

- **Host:** `<bastion-ip>`
- **User:** `<bastion-user>`
- **Access to both PCs:** yes (VPN / routing between envs)
