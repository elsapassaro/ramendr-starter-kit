# Change history for significant pattern releases

v1.0 - November 2025

* Arrange to default baseDomain settings appropriately so that forking the pattern is not a hard requirement
* Initial release

v1.0 - February 2026

* The names ocp-primary and ocp-secondary were hardcoded in various places, which caused issues when trying
to install two copies of this pattern into the same DNS domain.
* Also parameterize the version of edge-gitops-vms chart in case it needs to get updated. It too was hardcoded.
* Update to ACM 2.14 in prep for OCP 4.20+ testing.

v1.1 - March 2026

* Update managed cluster version from 4.18.7 to 4.21.6 (hub, primary, and secondary).
* Update ACM subscription channel from release-2.14 to release-2.16 (compatible with OCP 4.21).
* Add explicit ODF channel stable-4.21 for odf-operator and odf-multicluster-orchestrator on hub and managed clusters.
* Update OADP subscription channel from stable-1.4 to stable (tracks the single supported version for OCP 4.21, currently 1.7.x).
* Update openshift-install download URL to stable-4.21 in deployment guide.
* Fix Submariner gateway node provisioning for OCP 4.21:
  - Change gateway instance type from c5d.large to m5.large (c5d/r5d/m5d NVMe instance types
    fail to bootstrap on OCP 4.21 due to rpm-ostreed crash loops).
  - Add a ManifestWork-based CatalogSource (redhat-operator-index:v4.20) on managed clusters
    to provide the submariner package, which is absent from redhat-operator-index:v4.21.
  - Configure SubmarinerConfig.subscriptionConfig to use this custom catalog source.
* Fix cluster private key ExternalSecret to read ssh-privatekey/ssh-publickey directly from
  secret/hub/aws (already populated by values-secret.yaml) instead of the separate
  secret/hub/privatekey path that was never seeded by the pattern — removing an entire class
  of SecretSyncedError failures on fresh deployments.
* Fix KubeVirt VM scheduling on ocp-primary and ocp-secondary:
  - Fix opp-policy argocd-health-monitor Job sync-wave from 0 to 20, eliminating the
    chicken-and-egg deadlock where wave-0 needed ArgoCD on managed clusters before the
    PlacementRules (wave 2) that deploy ArgoCD were applied.
  - Fix submariner-catalog ManifestWork to include ClusterRole/ClusterRoleBinding granting
    klusterlet-work-sa permission to manage CatalogSource resources, which is required for the
    ManifestWork to apply the custom CatalogSource in openshift-marketplace.
  - Add a c5.metal bare-metal MachineSet to both primary and secondary clusters.
    Standard EC2 instance types (m5, m8i, etc.) do not expose vmx/svm CPU flags, so
    /dev/kvm is unavailable and KubeVirt reports allocatable KVM=0, making VMs
    ErrorUnschedulable. Only bare-metal instance types (e.g. c5.metal) provide native
    KVM support. Each managed cluster needs at least one metal worker node for
    OpenShift Virtualization to schedule VMs. This is also required on the secondary
    cluster so that DR failover can start VMs there.
  - Move primary cluster region from eu-north-1 to eu-central-1 because c5.metal
    has better availability there.
* Fix VM startup failures on OCP 4.21:
  - Update VM machineType from pc-q35-rhel8.4.0 to pc-q35-rhel9.4.0 (deprecated type triggers
    DeprecatedMachineType alerts and may cause startup failures on 4.21).
  - Add boot source readiness check in edge-gitops-vms-deploy script: waits up to 10 minutes
    for the rhel9 DataSource in openshift-virtualization-os-images to become ready before
    deploying VMs, preventing ErrorPvcNotFound / DataVolumeError states.
* Fix Submariner cross-cluster tunnel with VXLAN cable driver:
  - The Submariner operator (from the v4.20 catalog) passes --encapsulation=yes to libreswan when
    establishing the IPsec tunnel. OCP 4.21 RHCOS nodes ship with libreswan (pluto) 4.15, which
    does not recognise that flag — exit status 33 — so the IPsec tunnel never forms and VolSync
    rsync-tls source pods cannot resolve destination clusterset.local hostnames.
  - Switched SubmarinerConfig.spec.cableDriver from libreswan to vxlan and set NATTEnable: false.
    VXLAN bypasses libreswan/IKE entirely and builds the tunnel over UDP 4800, working reliably on
    OCP 4.21 RHCOS with the v4.20-catalog Submariner operator.
  - Added UDP 4490 (VXLAN NAT-discovery) and UDP 4800 (VXLAN tunnel data) to both clusters'
    Submariner gateway security groups. The Submariner prerequisites job only opens IPsec ports
    (ESP, AH, UDP 4500/4900) — the VXLAN ports must be added separately.
  - Added fix_submariner_vxlan_sg() function to redeploy.sh to automate adding these ports after
    future deployments.
* Fix klusterlet ManifestWork RBAC for ACM 2.16:
  - ACM 2.16 restricts klusterlet-work-sa permissions. Added a ManifestWork that deploys
    ClusterRole/Binding granting access to CatalogSource and Submariner CRDs on managed
    clusters, preventing ManifestWork apply failures.
