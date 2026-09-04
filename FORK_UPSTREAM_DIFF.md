# Fork customizations on upstream v1.3

This fork tracks **[validatedpatterns/ramendr-starter-kit `v1.3`](https://github.com/validatedpatterns/ramendr-starter-kit/tree/v1.3)** (currently [`8800dd8`](https://github.com/validatedpatterns/ramendr-starter-kit/commit/8800dd8)) and adds **QE/automation overrides** on the default **`odf`** variant.

| Branch | Purpose |
|--------|---------|
| [`v1.3`](https://github.com/elsapassaro/ramendr-starter-kit/tree/v1.3) | Tracks `upstream/v1.3` (no fork changes) |
| [`ocp-4.22-rhdr-ramen`](https://github.com/elsapassaro/ramendr-starter-kit/tree/ocp-4.22-rhdr-ramen) | Upstream v1.3 + QE customizations below |

**Full diff:** [Compare `8800dd8...HEAD`](https://github.com/elsapassaro/ramendr-starter-kit/compare/8800dd8...ocp-4.22-rhdr-ramen) (after push)

---

## Dropped (now in upstream v1.3)

These fork-only RHDR pieces were **removed**; upstream added preview RHDR support in **`drpartner-s4`** and **`drpartner-minimal`** via `indexImages`, `extraObjects` (IDMS), `rhdr-multicluster-operator`, and `regionaldr` `ramen.updateRamenConfig` / `opsNamespace` / `clusterServiceVersionName`.

| Removed fork artifact | Upstream replacement |
|----------------------|----------------------|
| [`APPLY_ME_FIRST.idms.yaml`](https://github.com/elsapassaro/ramendr-starter-kit/commit/11327fb) | `extraObjects.rhdr-fbc-idms` in drpartner hub/spoke BOMs |
| [`charts/hub/rhdr-dr-cluster-operator-config/`](https://github.com/elsapassaro/ramendr-starter-kit/tree/11327fb/charts/hub/rhdr-dr-cluster-operator-config) | `regionaldr-with-virt` ≥ 0.1.3 `ramen.updateRamenConfig` + `opsNamespace` + CSV ([drpartner example](https://github.com/validatedpatterns/ramendr-starter-kit/blob/v1.3/variants/drpartner-s4/values-regional-dr.yaml)) |
| `odf` hub `indexImages` + `rhdr-multicluster-operator` | Ported to **`odf`** variant (mirrors drpartner-s4 preview RHDR wiring) |
| Spoke `rhdr-cluster-operator` subscription on `odf` | Not needed — spoke operator via hub `regionaldr` ManifestWork + CSV (same as drpartner) |
| `opp-policy-chart` pin `0.0.1` | Upstream `0.1.*` |

**Note:** Preview RHDR in upstream is on **drpartner variants only**. This fork **ports the same preview RHDR wiring onto `odf`** (hub MCO subscription, FBC catalog + IDMS, regional-dr CSV) while keeping full ODF Regional DR + VMs.

The old local branch **`ocp-4.22-rhdr-ramen-pre-v1.3-rebase`** is obsolete; upstream v1.3 now includes the variants layout and drpartner RHDR wiring.

---

## Kept — QE / automation customizations

### BYOC, regions, and cost tags

| Change | Link |
|--------|------|
| `byoc: true`, EU regions, cost-management tags | [`overrides/values-cluster-names.yaml`](overrides/values-cluster-names.yaml) |

Upstream v1.3 sets `byoc: true` by default only on **drpartner** regional-dr overlays; **`odf`** still defaults to `byoc: false`, so this override remains on the fork.

### VM workloads (mixed Linux + Windows)

| Change | Link |
|--------|------|
| Mixed VMs, extra disks, CDI imports | [`overrides/values-egv-dr.yaml`](overrides/values-egv-dr.yaml) |
| Windows / Quay secrets | [`values-secret.yaml.template`](values-secret.yaml.template) |

### ODF DR prerequisites (proxy CA)

| Change | Link |
|--------|------|
| `cluster-proxy-ca-bundle` / `trust-bundle` | [`overrides/values-odf-dr-prerequisites.yaml`](overrides/values-odf-dr-prerequisites.yaml) |
| Wired on `odf-dr` app | [`variants/odf/values-odf.yaml`](variants/odf/values-odf.yaml) |

### Preview RHDR on `odf` (ported from upstream drpartner-s4)

| Change | Link |
|--------|------|
| Hub `indexImages`, `extraObjects` (IDMS), `rhdr-multicluster-operator` | [`variants/odf/values-odf.yaml`](variants/odf/values-odf.yaml) |
| Spoke `indexImages`, `extraObjects` (IDMS) | [`variants/odf/values-resilient.yaml`](variants/odf/values-resilient.yaml) |
| `ramen.drClusterOperator.clusterServiceVersionName` | [`overrides/values-odf-regional-dr.yaml`](overrides/values-odf-regional-dr.yaml) |
| ODF operator `stable-4.22` on hub/spoke | [`variants/odf/values-odf.yaml`](variants/odf/values-odf.yaml), [`variants/odf/values-resilient.yaml`](variants/odf/values-resilient.yaml) |

Replaces **`odf-multicluster-orchestrator`** with preview **`rhdr-multicluster-operator`** from `rhdr-catalog`.

### Discovered-app DRPC admin namespace (`openshift-dr-ops`)

Replaces the removed patch Job using upstream regionaldr chart support:

| Change | Link |
|--------|------|
| `ramen.updateRamenConfig` + `opsNamespace` | [`overrides/values-odf-regional-dr.yaml`](overrides/values-odf-regional-dr.yaml) |
| Wired on `regional-dr` app | [`variants/odf/values-odf.yaml`](variants/odf/values-odf.yaml) |
| Spoke namespace | [`variants/odf/values-resilient.yaml`](variants/odf/values-resilient.yaml) |

### Argo CD `ignoreDifferences` (Healthy/OutOfSync noise)

| Change | Link |
|--------|------|
| `opp-policy`, `odf-dr`, `regional-dr` | [`variants/odf/values-odf.yaml`](variants/odf/values-odf.yaml) |

---

## Uncertain — review after next deploy

| Item | Status | Notes |
|------|--------|-------|
| [`overrides/values-aws-cost-optimized.yaml`](overrides/values-aws-cost-optimized.yaml) | **Kept (comments only)** | Referenced from `regional-dr`; no active YAML overrides. Safe to drop if unused. |
| **`odf` + preview RHDR vs `drpartner-s4`** | **Resolved** | Fork runs preview RHDR on **`odf`** (see section above). Use **`drpartner-s4`** only for partner CSI / no-ODF-storage scenarios. |
| **`stable-4.22` ODF channel pin** | **Re-added** | Hub and spoke ODF subscriptions pinned for OCP 4.22 / RHDR preview alignment. |
| **Expanded `ignoreDifferences`** | **Kept** | Not in upstream `odf` yet; drop if upstream adopts the same rules. |
| **`values-odf-dr-prerequisites.yaml`** | **Kept** | Not in upstream; drop if `odf-dr-chart` defaults this for proxy-CA hubs. |

---

## Suggested upstream adoption (remaining fork diff)

1. Adopt `ignoreDifferences` + `values-odf-dr-prerequisites.yaml` on upstream **`odf`** variant.
2. Adopt `values-odf-regional-dr.yaml` pattern (or equivalent) on upstream **`odf`** `regional-dr` app.
3. Keep BYOC/regions/tags as fork/env overrides unless upstream adds a documented QE profile.
