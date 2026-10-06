# Dell PowerStore GitOps-managed VM failover (VIRTDR-292)

GitOps-managed VM workload for DR failover testing on Dell PowerStore VSAs.

## Structure

```
clusters/dell-s4/
  workloads/           VM manifests deployed by ArgoCD to the target spoke
    datavolumes.yaml   rootdisk (35Gi, cloned from RHEL 9 DataSource) + datadisk (20Gi, blank)
    virtualmachine.yaml  hammerdb-rhel9 VM (2 vCPU, 8Gi RAM)
    service.yaml       SSH service for HammerDB bootstrap
  hub-gitops/          Hub GitOps registration (applied to the hub cluster)
    gitopscluster.yaml   GitOpsCluster + registration Placement with tolerations
  hub-dr/              Hub-side DR resources (applied to the hub cluster)
    placement.yaml       DR Placement (scheduling disabled, controlled by DRPC)
    applicationset.yaml  Pull-model ApplicationSet using the DR Placement decisions
    drpc.yaml            Managed-application DRPC with dr-policy-15m (15-min RPO)
  spoke-rbac/          Applied to both managed clusters
    clusterrolebinding.yaml  cluster-admin for the spoke ArgoCD application controller
```

All hub objects live in `openshift-gitops`. The ApplicationSet generator only
reads PlacementDecisions from the ArgoCD namespace, and Ramen requires the
DRPC and its Placement to share a namespace.

The workload path intentionally has no Namespace manifest. ArgoCD creates
`gitops-vms` through `CreateNamespace=true` and never deletes it. If the
namespace were an ArgoCD-managed resource, failover would prune it on the
source cluster, deleting the VRG before it reaches Secondary and leaving the
DRPC stuck in `Cleaning Up`.

## Usage

1. Apply `spoke-rbac/` to both spokes: `oc apply -f clusters/dell-s4/spoke-rbac/`
2. Create the `gitops-vms` namespace and the `cloudinit-hammerdb` Secret on both
   spokes (the Secret is not stored in this public repo)
3. Apply the GitOps registration to the hub: `oc apply -f clusters/dell-s4/hub-gitops/`
4. Apply the DR resources to the hub: `oc apply -f clusters/dell-s4/hub-dr/`
5. ArgoCD deploys the VM workload to the spoke selected by the Placement (spoke-0)
6. Run `bootstrap-hammerdb.sh` from RedHatQE/ramendr-storage-ui-tests to install
   PostgreSQL + HammerDB inside the VM
7. Test failover via the hub Data Services DR console UI

## Prerequisites

- Steps 1-8 of the RamenDR Dell Setup completed
- OpenShift GitOps installed on the hub and both spokes
- DRPolicy `dr-policy-15m` created
- Dell CSI driver with csi-addons VolumeReplication on both spokes
- StorageClass `powerstore-sc` on both spokes
