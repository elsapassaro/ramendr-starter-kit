#!/usr/bin/env python3
"""Fail when a managed VirtualMachine mounts a claim that has no DataVolume
manifest in the same application path.

Argo CD only prunes resources that its Application owns. A claim created
outside Git therefore survives a failover and blocks the source VRG from
becoming Secondary, which parks the DRPC in Cleaning Up. Defining the
DataVolume in the application path makes Argo own the disk, so the source
prune removes it.

The check also requires the appname label the DRPC selects and a storage
class on each DataVolume.
"""
import argparse
import os
import sys

import yaml

APP_PATHS = ("clusters/dell-s4/workloads", "clusters/dell-s4/workloads-win")


def documents(path):
    for name in sorted(os.listdir(path)):
        if not name.endswith((".yaml", ".yml")):
            continue
        with open(os.path.join(path, name), encoding="utf-8") as handle:
            for doc in yaml.safe_load_all(handle):
                if isinstance(doc, dict) and doc.get("kind"):
                    yield name, doc


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".", help="repository root")
    args = parser.parse_args()
    failed = False
    for rel in APP_PATHS:
        path = os.path.join(args.root, rel)
        if not os.path.isdir(path):
            continue
        vms = []
        dvs = {}
        for filename, doc in documents(path):
            if doc["kind"] == "VirtualMachine":
                vms.append((filename, doc))
            elif doc["kind"] == "DataVolume":
                dvs[doc["metadata"]["name"]] = (filename, doc)
        for filename, vm in vms:
            namespace = vm["metadata"].get("namespace")
            spec = vm.get("spec", {}).get("template", {}).get("spec", {})
            for volume in spec.get("volumes") or []:
                claim = (volume.get("persistentVolumeClaim") or {}).get("claimName")
                if not claim:
                    continue
                if claim not in dvs:
                    print(
                        f"FAIL {rel}: {filename} VM {vm['metadata']['name']} "
                        f"mounts {claim} but no DataVolume manifest defines it"
                    )
                    failed = True
                    continue
                dv_file, dv = dvs[claim]
                if dv["metadata"].get("namespace") != namespace:
                    print(
                        f"FAIL {rel}: {dv_file} DataVolume {claim} namespace "
                        f"{dv['metadata'].get('namespace')} does not match VM namespace {namespace}"
                    )
                    failed = True
                if not (dv["metadata"].get("labels") or {}).get("appname"):
                    print(f"FAIL {rel}: {dv_file} DataVolume {claim} has no appname label")
                    failed = True
                storage = (dv.get("spec") or {}).get("storage") or {}
                if not storage.get("storageClassName"):
                    print(f"FAIL {rel}: {dv_file} DataVolume {claim} has no storageClassName")
                    failed = True
    if not failed:
        print("OK: every managed VM claim has a DataVolume manifest with appname and storage class")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
