# Lab Inventory — NKP Sprint

Captured: <date>
Goal: know my lab cold before Day 4 (NKP provisioning) so cluster setup is execution, not discovery.

---

## Nutanix infrastructure

- **AOS version:** <e.g. 6.8.x>
- **Hypervisor:** AHV / ESXi
- **Cluster name(s):** <name>
- **Prism Element URL:** <https://...>
- **Prism Central URL:** <https://...>
- **Prism Central version:** <pc.2024.x>

## Storage

- **Storage container name(s) usable for CSI / PVCs:** <name>
- **Notes:** any size limits, compression/dedup enabled, separate container for K8s?

## Networking

- **Subnet / IP range available for cluster VMs:** <CIDR>
- **Gateway:** <ip>
- **VLAN ID:** <if applicable>
- **DNS servers:** <ip(s)>
- **NTP servers:** <ip(s) or hostnames>
- **Internet egress:** yes / proxied / air-gapped
  - If proxied: proxy URL = <...>, no_proxy list = <...>
- **Load balancer / VIP available for ingress:** <ip range or "MetalLB needed">

## NKP

- **NKP version available:** <e.g. 2.13.x or 2.14.x>
- **Install method I'll use:** dkp CLI / Konvoy / NKP Konvoy Image Builder / pre-baked
- **Management cluster status:** does one already exist in the lab, or do I need to bootstrap?
- **Image registry available in lab:** Harbor / built-in / external (ghcr.io for our sprint)

## Access & people

- **My lab credentials confirmed working:** yes / no
- **Lab admin / point of contact:** <name, slack/email>
- **Ticket queue or chat for lab issues:** <link>

## NKP architecture mental model (in my own words, 2–3 sentences)

> What's the difference between an NKP management cluster and an NKP workload cluster?
> Why is this split useful?
> Where would my scuba app run — management or workload cluster?

(Fill this in after skimming the NKP docs.)

## What surprised me

- <bullet 1>
- <bullet 2>
