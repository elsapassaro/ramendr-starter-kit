# Change history for significant pattern releases

v1.0 - November 2025

* Arrange to default baseDomain settings appropriately so that forking the pattern is not a hard requirement
* Initial release

v1.0 - February 2026

* The names ocp-primary and ocp-secondary were hardcoded in various places, which caused issues when trying
to install two copies of this pattern into the same DNS domain.
* Also parameterize the version of edge-gitops-vms chart in case it needs to get updated. It too was hardcoded.
* Update to ACM 2.14 in prep for OCP 4.20+ testing.

v1.0 - March 2026

* Updated workload deployment script to check both clusters for workload instead of just the primary, in case
a failover was in progress at the time.
* Update ACM to 2.15 and golang-external-secrets. Move to 0.2 golang-secrets chart to allow use of v1 API. This is
in prep to move to OCP 4.20 as the default.
* Change machine instance type for submariner to allow deployment on 4.20.
* rdr chart previously used hardcoded and undocumented Vault secrets. Exposed these as variables and referenced
previously documented AWS secret instead of creating a new one with the same material).
* When OCP 4.20+ support is ready, there will be a v1.1 branch to use it.
* Externalize all charts to prep for subsequent demo pattern.
* Pass values-egv-dr into edge-gitops-vms chart. It used to use a symlink when it was local.

v1.1 - April 2026

* Change submariner to use vxlan mode by default, for compatibility reasons
* Default to OCP 4.20+. The subscription for OADP requires "stable" channel not "stable-1.4".
* Numerous small changes to deal with race conditions and other potential issues
* Introduce "BYOC" (bring-your-own-cluster) as an option for cluster provisioning (thanks @darkdoc)

v1.2 - June 2026

* Move cluster CA management stuff to a new namespace (cluster-ca-mgt)
* Use productized OpenShift External Secrets operator
* Default to OCP 4.22
* Update to ACM chart v0.2.*
* Use versioned charts for opp-policy, regionaldr, and application data protection
* Pin ODF to stable-4.21 on hub and spokes (ODF 4.21 supported on OCP 4.22 until ODF 4.22 GA)

ocp-4.22 branch customizations (June 2026)

* BYOC mode with eu-central-1 / eu-west-1 regions for storage-ui-tests
* costManagement `ownerTag` set to `storage-migration-qe` for AWS cost tracking (storage-ui-tests workload)
* mixed Linux + Windows edge VMs with additionalDisks in values-egv-dr

odf-4.22 branch customizations (July 2026)

* Upgrade ODF operator subscriptions to stable-4.22 on hub and resilient spokes (ODF 4.22 GA alongside OCP 4.22)
