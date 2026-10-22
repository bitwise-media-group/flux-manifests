---
description:
  "The secrets-store-sync-controller EKS lacks: materialises SecretSync Secrets without a pod mounting a CSI volume."
---

# secret-sync

The upstream [secrets-store-sync-controller](https://github.com/kubernetes-sigs/secrets-store-sync-controller): the
piece of the secret-sync machinery EKS doesn't ship. It supplies the `SecretSync` CRD (`secret-sync.x-k8s.io/v1alpha1`)
and materialises each SecretSync's Secret **without** a pod mounting a CSI volume, the standalone sync GKE provides
natively. How the platform syncs secrets on both clouds is on [Secret sync](../concepts/secret-sync.md).

|                |                                                                                                                                                                             |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Tier**       | core, unconditional                                                                                                                                                         |
| **Clouds**     | aws only                                                                                                                                                                    |
| **Depends on** | kyverno-policies                                                                                                                                                            |
| **Namespace**  | `secret-sync`                                                                                                                                                               |
| **Chart**      | [`secrets-store-sync-controller`](https://oss.bitwisemedia.uk/flux-containers/charts/secrets-store-sync-controller/), range `SECRET_SYNC_SEMVER` (default `<1.0.0 >=0.0.5`) |
| **Timeout**    | 5m                                                                                                                                                                          |

It's unconditional because the platform can't know which applications consume secrets, and the machinery must exist
before any of them renders a SecretSync. On aws, [dex](dex.md), [flux-web](flux-web.md) and every application that syncs
secrets depend on it. The Secrets Store CSI driver and AWS provider it talks to come from the
`aws-secrets-store-csi-driver-provider` EKS add-on, installed by terraform.

## Notable values

- **`ECRArtifactTag` unconditionally** in the input provider: this component lives only in the aws tree.
- **`tokenRequestAudience: sts.amazonaws.com`**, the IRSA audience. The controller impersonates each SecretSync's
  ServiceAccount, requesting its token with this audience, and hands it to the AWS provider, so the reader identity is
  always the consumer's IRSA role, never the controller's own. This is why every SecretProviderClass the platform
  authors sets `usePodIdentity: "false"`: the syncs are podless, and Pod Identity requires a pod claim.
- **CRDs `CreateReplace`**, so the SecretSync CRD tracks the chart.
- **Provider socket post-render.** The chart hardcodes its provider-socket `hostPath` to
  `/var/run/secrets-store-sync-providers`, which the AWS provider never writes to; the provider registers in the CSI
  driver's `/var/run/secrets-store-csi-providers` instead. With no values knob, a post-renderer patches the volume path.
  A `test` op pins the volume's name first, so a chart reorder fails loudly instead of patching the wrong volume.

## Cluster variables

`PLATFORM_REGISTRY`, `CONTAINER_REGISTRY`, `OCI_PROVIDER`, `SIGNED_IDENTITY_*`, `COSIGN_PUBLIC_KEY`,
`SECRET_SYNC_SEMVER`.

## Source

??? example "components/secret-sync/aws/input-provider.yaml"

    ```yaml
    --8<-- "components/secret-sync/aws/input-provider.yaml"
    ```

??? example "components/secret-sync/aws/resourceset.yaml"

    ```yaml
    --8<-- "components/secret-sync/aws/resourceset.yaml"
    ```
