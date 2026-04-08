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

* Update managed cluster version from 4.18.7 to 4.21.1 (hub, primary, and secondary).
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
  - Change worker instance type from m5.4xlarge to m5.metal in overrides/values-cluster-names.yaml.
    m5.4xlarge nodes in eu-north-1 and eu-west-1 do not expose the vmx CPU flag, so /dev/kvm
    is absent and devices.kubevirt.io/kvm is never advertised — VMs land in ErrorUnschedulable.
    m5.metal provides direct hardware access and /dev/kvm works out of the box on all workers.
  - Add rootVolume (300 GB gp3) to the worker compute spec. Without an explicit rootVolume,
    Hive provisions workers with the default RHCOS image disk (~16 GB), which causes
    ephemeral-storage DiskPressure as container images fill the filesystem.
  - Fix opp-policy argocd-health-monitor Job sync-wave from 0 to 20, eliminating the
    chicken-and-egg deadlock where wave-0 needed ArgoCD on managed clusters before the
    PlacementRules (wave 2) that deploy ArgoCD were applied.
  - Fix submariner-catalog ManifestWork to include ClusterRole/ClusterRoleBinding granting
    klusterlet-work-sa permission to manage CatalogSource resources, which is required for the
    ManifestWork to apply the custom CatalogSource in openshift-marketplace.
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