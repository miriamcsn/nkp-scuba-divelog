#!/usr/bin/env python3
import os
import logging
import requests
import urllib3
from datetime import datetime, timezone
from kubernetes import client, config
from kubernetes.client.rest import ApiException

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

PRISM_ENDPOINT = os.environ["PRISM_ENDPOINT"]
PRISM_USER = os.environ["PRISM_USER"]
PRISM_PASSWORD = os.environ["PRISM_PASSWORD"]
PRISM_VERIFY_SSL = os.environ.get("PRISM_VERIFY_SSL", "false").lower() == "true"


def parse_memory_mib(quantity: str) -> int:
    quantity = quantity.strip()
    for suffix, mib in [("Ti", 1024 * 1024), ("Gi", 1024), ("Mi", 1), ("Ki", 0)]:
        if quantity.endswith(suffix):
            val = float(quantity[: -len(suffix)])
            if suffix == "Ki":
                return int(val // 1024)
            return int(val * mib)
    return int(quantity) // (1024 * 1024)


def get_vm(uuid: str) -> dict:
    resp = requests.get(
        f"{PRISM_ENDPOINT}/api/nutanix/v3/vms/{uuid}",
        auth=(PRISM_USER, PRISM_PASSWORD),
        verify=PRISM_VERIFY_SSL,
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()


def emit_event(core_v1: client.CoreV1Api, machine: dict, message: str):
    ns = machine["metadata"]["namespace"]
    name = machine["metadata"]["name"]
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    event = client.CoreV1Event(
        metadata=client.V1ObjectMeta(
            generate_name=f"{name}-drift-",
            namespace=ns,
        ),
        involved_object=client.V1ObjectReference(
            api_version="infrastructure.cluster.x-k8s.io/v1beta1",
            kind="NutanixMachine",
            name=name,
            namespace=ns,
            uid=machine["metadata"]["uid"],
        ),
        reason="SpecDriftDetected",
        message=message,
        type="Warning",
        event_time=now,
        action="DriftDetection",
        reporting_component="nutanix-drift-detector",
        reporting_instance="drift-detector",
        first_timestamp=now,
        last_timestamp=now,
        count=1,
    )
    try:
        core_v1.create_namespaced_event(namespace=ns, body=event)
    except ApiException as e:
        log.error(f"Failed to create event for {name}: {e}")


def check(machine: dict, core_v1: client.CoreV1Api):
    ns = machine["metadata"]["namespace"]
    name = machine["metadata"]["name"]
    spec = machine.get("spec", {})
    status = machine.get("status", {})

    uuid = status.get("vmUUID")
    if not uuid:
        log.info(f"{ns}/{name}: no vmUUID yet, skipping")
        return

    desired_vcpus = spec.get("vcpusPerSocket", 0) * spec.get("vcpuSockets", 0)
    desired_mem = parse_memory_mib(spec.get("memorySize", "0"))

    try:
        vm = get_vm(uuid)
    except Exception as e:
        log.error(f"{ns}/{name}: prism fetch failed for {uuid}: {e}")
        return

    res = vm.get("spec", {}).get("resources", {})
    actual_vcpus = res.get("num_vcpus_per_socket", 0) * res.get("num_sockets", 0)
    actual_mem = res.get("memory_size_mib", 0)

    drifts = []
    if desired_vcpus != actual_vcpus:
        drifts.append(f"vCPU desired={desired_vcpus} actual={actual_vcpus}")
    if desired_mem != actual_mem:
        drifts.append(f"memoryMiB desired={desired_mem} actual={actual_mem}")

    if drifts:
        msg = f"Drift on {uuid}: " + ", ".join(drifts)
        log.warning(f"{ns}/{name}: {msg}")
        emit_event(core_v1, machine, msg)
    else:
        log.info(f"{ns}/{name}: ok (uuid={uuid})")


def main():
    try:
        config.load_incluster_config()
    except config.ConfigException:
        config.load_kube_config()

    core_v1 = client.CoreV1Api()
    custom = client.CustomObjectsApi()

    machines = custom.list_cluster_custom_object(
        group="infrastructure.cluster.x-k8s.io",
        version="v1beta1",
        plural="nutanixmachines",
    )

    items = machines.get("items", [])
    log.info(f"Checking {len(items)} NutanixMachine(s)")
    for machine in items:
        check(machine, core_v1)


if __name__ == "__main__":
    main()
