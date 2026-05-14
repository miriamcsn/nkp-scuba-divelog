# Lab Inventory — NKP Sprint

Captured: 05-12-2026
Goal: know my lab cold before Day 4 (NKP provisioning) so cluster setup is execution, not discovery.

---

## Nutanix infrastructure

- **AOS version:** 7.5
- **Hypervisor:** AHV
- **Cluster name(s):** DM3-POC087
- **Prism Element URL:** https://10.55.87.7:9440/console/#page/dashboard/?clusterid=00064898-a8ad-760c-3f5b-ac1f6b3d7d4b&fullVersion=el8.5-release-ganges-7.5-stable-cd8cd937b6288cf2c58a44a0bc1c58d85bf5c0bb
- **Prism Central URL:** https://10.55.87.7:9440/dm/infrastructure/page/pc_dashboard
- **Prism Central version:** pc.7.5.0.1

<!-- 

/25 has 128 ips available
start with 0 and go to 127
128 to 
130-134 are static IPs
230-232

## static IPs:
1 IP for cluster API 10.54.27.130
at least 3 contiguous static IPs to metalLB range 10.54.27.131-133

DHCP IPs:
virtual machines, control plane and others are deployed using DHCP IPs

infoblox or entire range in DHCP
will have to reserve IPs to kubeAPI server and MetalLB range

IPAM: search for it! -->

## Storage

- **Storage container name(s) usable for CSI / PVCs:** default
- **Notes:** any size limits, compression/dedup enabled, separate container for K8s? No

## Networking

- **Subnet:** SAWest-10_55_87_128-25
- **IP range available for cluster VMs:** 10.55.87.200 - 10.55.87.230
- **Gateway:** 10.55.87.129
- **VLAN ID:** 871
- **DNS servers:** 10.55.87.6 and 10.54.11.21
- **NTP servers:** ntnxlab.local
- **Internet egress:** no
- **Load balancer / VIP available for ingress:** 10.54.27.131-133

## NKP

- **NKP version available:** v2.17.1
- **Install method I'll use:** NKP Bundle
- **Management cluster status:** Bootstrap
- **Image registry available in lab:** 
