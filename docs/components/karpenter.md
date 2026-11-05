---
description:
  "Node auto-provisioning on EKS: the Karpenter controller, the shared EC2NodeClass and the default NodePool."
---

# karpenter

[Karpenter](https://karpenter.sh) launches EC2 nodes for pods the scheduler can't place, and consolidates or retires
them when they're no longer needed. On aws it's where all workload capacity comes from: the terraform-managed system
node group is only the platform's floor, and it carries the platform controllers.

terraform-aws-eks-flux owns everything AWS-side: the controller and node IAM roles, the SQS interruption queue and its
EventBridge rules, the discovery tags, and the Pod Identity association. It publishes the wiring and the default
NodePool's shape as `KARPENTER_*` cluster variables. This component owns the chart and the cluster-side objects, so
terraform never has to apply a resource whose CRD Flux hasn't installed yet.

|                |                                                                                                                                    |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| **Tier**       | core                                                                                                                               |
| **Clouds**     | aws only (GKE provisions node pools itself)                                                                                        |
| **Depends on** | kyverno-policies                                                                                                                   |
| **Namespace**  | `KARPENTER_NAMESPACE` (`kube-system` by default)                                                                                   |
| **Chart**      | [`karpenter`](https://oss.bitwisemedia.uk/flux-containers/charts/karpenter/), range `KARPENTER_SEMVER` (default `<2.0.0 >=1.15.1`) |
| **Timeout**    | 10m                                                                                                                                |

## Namespace

The Pod Identity association binds `<namespace>/<service account>`, and the chart has to install exactly there or the
controller runs without credentials. terraform publishes both halves of `workload_identity.karpenter`:
`KARPENTER_NAMESPACE` and `KARPENTER_SERVICE_ACCOUNT`. Every namespaced object in the component reads
`KARPENTER_NAMESPACE`, so overriding the pair in terraform needs no manifests change. The default is `kube-system`,
upstream's recommended home.

`namespace.yaml` creates the namespace when it doesn't exist. It's applied with `ssa: IfNotPresent`, so flux never
patches an existing namespace such as `kube-system`, and with `prune: disabled`, so changing the variable never deletes
the old one. The chart's public-key Secret is named `cosign-pub-karpenter` rather than `cosign-pub`, because the cilium
component already owns a `cosign-pub` in `kube-system`.

`KARPENTER_NAMESPACE` is required, with no default, like every variable terraform always publishes. It needs the
terraform-aws-eks-flux release that publishes it; on an older module the karpenter Kustomization fails strict
substitution.

## Notable values

- **CRDs from the chart.** The `karpenter` chart carries the `karpenter.sh` and `karpenter.k8s.aws` CRDs in `crds/`.
  Helm installs those once and never upgrades them, so the HelmRelease sets `crds: CreateReplace` on install and
  upgrade. That does what upstream's separate `karpenter-crd` chart exists for, so that chart isn't mirrored.
- **No separate image train.** The chart pins the controller by tag and digest. Only the repository is remapped to the
  mirror, and because the mirror copies by digest, the chart's own `tag@digest` names the mirrored image.
- **Region pinned.** `controller.env` sets `AWS_REGION`. Pod Identity hands out credentials but not a region, and the
  SDK's IMDS fallback is unreliable under the hardened node metadata settings.
- **Interruption handling on.** `settings.interruptionQueue` is the terraform queue, so Karpenter drains a node before a
  spot interruption, rebalance or scheduled event takes it.
- **On the system pool.** `nodeSelector: {role: system}`. The chart's own affinity already keeps the controller off
  nodes Karpenter launched.

## The default capacity

`resourceset-nodes.yaml` renders two objects from the cluster variables. It's a ResourceSet for its `dependsOn`:
flux-operator holds it until the chart's CRDs exist, since an apply naming an unknown kind would fail the whole
Kustomization. It also needs template functions: lists arrive comma-joined (`splitList`) and the AMI selector arrives as
JSON (`mustFromJson`).

### `EC2NodeClass default`

The one platform-owned node class, and a contract applications build on:

- **role**: `KARPENTER_NODE_ROLE`, terraform's node role. Karpenter manages the instance profile for it.
- **AMI**: `amiSelectorTerms` is `KARPENTER_AMI_SELECTOR_TERMS` verbatim. That's an alias term (`al2023@latest` by
  default), or for a custom image an id term or one name and owner term per owner. `amiFamily` is set only when
  `KARPENTER_AMI_FAMILY` is (`AL2023`, for custom images; an alias implies its family).
- **subnets and security groups**: everything tagged `${CLUSTER_DISCOVERY_TAG}=${CLUSTER_DISCOVERY_VALUE}`. terraform
  tags the cluster security group and, while `network.manage_discovery_tags` is on, the node subnets only. The public
  and internal subnets stay untagged, so Karpenter never launches nodes into them. Older terraform-aws-eks-flux releases
  tagged the public subnets too; the release that publishes `KARPENTER_NAMESPACE` removes those tags.
- **root volume**: `KARPENTER_NODE_DISK_GIB`, encrypted gp3 on `/dev/xvda` (`/dev/xvdb`, the data volume, for a
  Bottlerocket alias).
- **metadata**: IMDSv2 only, hop limit 1, so pods can't reach the node's credentials.

### `NodePool ${KARPENTER_NODE_POOL_NAME}`

The cluster's default pool (`default` unless terraform renames it), against `EC2NodeClass default`:

- **requirements**: Linux, `KARPENTER_ARCHITECTURES`, `KARPENTER_CAPACITY_TYPES`, and whichever of
  `KARPENTER_INSTANCE_CATEGORIES`, `KARPENTER_INSTANCE_FAMILIES` and `KARPENTER_INSTANCE_SIZES` are set. An empty one
  drops its requirement rather than rendering an empty list.
- **limits**: `KARPENTER_CPU_LIMIT`, `KARPENTER_MEMORY_LIMIT` and `KARPENTER_MAX_NODES`. These are ceilings only;
  Karpenter scales from zero.
- **disruption**: `KARPENTER_CONSOLIDATION_POLICY` after `KARPENTER_CONSOLIDATE_AFTER`, and every node expires after
  `KARPENTER_EXPIRE_AFTER`.
- **startup taint**: `node.cilium.io/agent-not-ready=true:NoExecute`, the bootstrap taint terraform's managed node
  groups carry. Nothing schedules on a new node until Cilium can give it an address, and the Cilium operator removes the
  taint once the agent is ready.

## Application NodePools

An application that needs dedicated capacity, such as a runner scale set on its own scale-to-zero nodes, ships its own
`NodePool` in its manifest image with `nodeClassRef: {group: karpenter.k8s.aws, kind: EC2NodeClass, name: default}`. It
inherits the node role, subnets, security groups and AMI from the platform, and adds only its own requirements, taints,
labels and limits. It should repeat the Cilium startup taint above. See
[Dedicated capacity](../applications.md#dedicated-capacity).

## Identity

The `${KARPENTER_NAMESPACE}/${KARPENTER_SERVICE_ACCOUNT}` ServiceAccount (`kube-system/karpenter` by default) has a Pod
Identity association with the controller policy, created by terraform. That policy scopes launches and terminations to
resources tagged for this cluster, and allows `iam:PassRole` on the node role only.

## Cluster variables

`CLUSTER_NAME`, `AWS_REGION`, `CLUSTER_DISCOVERY_TAG`, `CLUSTER_DISCOVERY_VALUE`, `KARPENTER_NODE_ROLE`,
`KARPENTER_INTERRUPTION_QUEUE`, `KARPENTER_NAMESPACE`, `KARPENTER_SERVICE_ACCOUNT`, `KARPENTER_NODE_POOL_NAME`,
`KARPENTER_INSTANCE_CATEGORIES`, `KARPENTER_INSTANCE_FAMILIES`, `KARPENTER_INSTANCE_SIZES`, `KARPENTER_CAPACITY_TYPES`,
`KARPENTER_ARCHITECTURES`, `KARPENTER_AMI_ALIAS`, `KARPENTER_AMI_SELECTOR_TERMS`, `KARPENTER_AMI_FAMILY`,
`KARPENTER_MAX_NODES`, `KARPENTER_CPU_LIMIT`, `KARPENTER_MEMORY_LIMIT`, `KARPENTER_NODE_DISK_GIB`,
`KARPENTER_CONSOLIDATION_POLICY`, `KARPENTER_CONSOLIDATE_AFTER`, `KARPENTER_EXPIRE_AFTER`, `PLATFORM_REGISTRY`,
`CONTAINER_REGISTRY`, `ARTIFACT_TAG_PROVIDER`, `OCI_PROVIDER`, `SIGNED_IDENTITY_*`, `COSIGN_PUBLIC_KEY`,
`KARPENTER_SEMVER`.

## Source

??? example "components/karpenter/aws/namespace.yaml"

    ```yaml
    --8<-- "components/karpenter/aws/namespace.yaml"
    ```

??? example "components/karpenter/aws/input-provider.yaml"

    ```yaml
    --8<-- "components/karpenter/aws/input-provider.yaml"
    ```

??? example "components/karpenter/aws/resourceset.yaml"

    ```yaml
    --8<-- "components/karpenter/aws/resourceset.yaml"
    ```

??? example "components/karpenter/aws/resourceset-nodes.yaml"

    ```yaml
    --8<-- "components/karpenter/aws/resourceset-nodes.yaml"
    ```
