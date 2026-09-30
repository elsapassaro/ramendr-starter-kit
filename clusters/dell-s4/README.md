# Dell PowerStore GitOps-managed VM failover (VIRTDR-292)

GitOps-managed VM workload for DR failover testing on Dell PowerStore VSAs.

## Structure

```
clusters/dell-s4/
  workloads/           VM manifests deployed by ArgoCD to the target spoke
    namespace.yaml     gitops-vms namespace
    datavolumes.yaml   rootdisk (35Gi, cloned from RHEL 9 DataSource) + datadisk (20Gi, blank)
    virtualmachine.yaml  hammerdb-rhel9 VM (2 vCPU, 8Gi RAM)
    secret.yaml        cloudinit-hammerdb (set userdata before applying)
    service.yaml       SSH service for HammerDB bootstrap
  hub-dr/              Hub-side DR resources (applied to the hub cluster)
    applicationset.yaml  ArgoCD ApplicationSet using ACM Placement generator
    placement.yaml       ACM Placement (scheduling disabled, controlled by DRPC)
    drpc.yaml            DRPlacementControl with dr-policy-15m (15-min RPO)
```

## Usage

1. Set the cloud-init secret userdata in `workloads/secret.yaml`
2. Apply hub-dr resources to the hub: `oc apply -f clusters/dell-s4/hub-dr/`
3. ArgoCD deploys the VM workload to the spoke selected by the Placement
4. Run `bootstrap-hammerdb.sh` from RedHatQE/ramendr-storage-ui-tests to install
   PostgreSQL + HammerDB inside the VM
5. Test failover via the hub Data Services DR console UI

## Prerequisites

- Steps 1-8 of the RamenDR Dell Setup completed
- OpenShift GitOps installed on the hub
- DRPolicy `dr-policy-15m` created
- Dell CSI driver with csi-addons VolumeReplication on both spokes
- StorageClass `powerstore-sc` on both spokes
