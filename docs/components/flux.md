---
description:
  "Flux managing Flux: adopts terraform's bootstrap flux-operator and FluxInstance, and re-points the cluster's sync."
---

# flux

Flux managing Flux. terraform installs flux-operator and the FluxInstance once, to bootstrap the cluster, and never
reconciles them again. This component adopts both releases by name, so from then on a flux-containers publish of a new
operator or instance chart is the only thing that upgrades Flux, estate-wide.

|                |                                                                                                                                                                                                                                |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Tier**       | core                                                                                                                                                                                                                           |
| **Clouds**     | aws, google (common tier verbatim)                                                                                                                                                                                             |
| **Depends on** | kyverno-policies                                                                                                                                                                                                               |
| **Namespace**  | `flux-system`                                                                                                                                                                                                                  |
| **Charts**     | [`flux-operator`](https://oss.bitwisemedia.uk/flux-containers/charts/flux-operator/) and [`flux-instance`](https://oss.bitwisemedia.uk/flux-containers/charts/flux-instance/), range `FLUX_SEMVER` (default `<1.0.0 >=0.55.0`) |
| **Timeout**    | 5m                                                                                                                                                                                                                             |

## What it deploys

- **One input provider, two charts.** flux-operator and flux-instance are released together upstream on one version
  stream, so a single provider (listing `charts/flux-operator`) drives both OCIRepositories.
- **HelmRelease `flux-operator`**, adopting terraform's release of the same name. It runs the mirrored operator image on
  the system pool, and sets `web.configSecretName: flux-web-auth`, the Flux status UI's Web Config Secret that the
  [flux-web](flux-web.md) component syncs. On a cluster without SSO the Secret never arrives, which is harmless.
- **HelmRelease `flux`**, adopting terraform's FluxInstance release. It depends on `flux-operator`, because the
  FluxInstance it renders can carry fields only the matching operator understands.

## The FluxInstance

The values the `flux` release renders are how the platform holds every cluster's Flux configuration:

- **`distribution`**: version `2.x` from `${CONTAINER_REGISTRY}/images/ghcr.io/fluxcd`. Minor and patch selection
  happens against the manifests **embedded** in the mirrored operator image, so the range never reaches outside the
  estate. flux-containers pins the matching controller images in the same PR as the operator.
- **`cluster.type`**: `${OCI_PROVIDER:=gcp}`. FluxInstance's cloud vocabulary (`aws`/`gcp`) is exactly OCI_PROVIDER's.
- **`sync`**: `url: ${FLUX_SYNC_URL}`, `ref: ${FLUX_SYNC_CHANNEL:=stable}`, `path: ${PLATFORM_TREE}`, with ambient
  registry auth. `url` and `path` are bare on purpose: if either variable went missing, strict substitution fails loudly
  rather than a default silently pointing the cluster at the wrong tree. Re-asserting them here is how a running cluster
  is [re-pointed](../reference/operations.md#re-pointing-a-cluster).

Three kustomize patches ride on the instance:

1. **Controllers on the system pool**, matching the operator.
2. **Signature verification on the sync source.** FluxInstance's `spec.sync` has no verify field, so a patch adds one to
   the generated `flux-system` OCIRepository: the `cosign-pub` Secret in KMS mode, otherwise the manifests identity
   `SIGNED_IDENTITY_MANIFESTS`.
3. **`DisableChartDigestTracking=true` on helm-controller.** helm-controller normally appends the OCI digest to chart
   versions as build metadata (`0.56.0+<digest>`). That synthetic version lands in the helm release storage, which
   terraform shares by name and would read back as a chart tag that doesn't exist. Every chart tag here comes from a
   semver input provider, and the mirror never re-pushes a tag, so the digest isn't needed.

A **post-renderer** removes `spec.distribution.artifact` from the rendered FluxInstance. The chart always renders it
with upstream's `flux-operator-manifests:latest`, an ungated channel that could deliver controller patches before the
mirror carries their images. Without it, the operator builds purely from its embedded manifests. The `remove` op fails
loudly if the chart ever stops rendering the field, which is the signal to delete the patch.

## Identity

terraform grants `flux-system/source-controller` and `flux-system/flux-operator` registry access (Workload Identity on
google, Pod Identity on aws). The operator's identity is what every component's input provider lists tags with.

## Cluster variables

`PLATFORM_REGISTRY`, `CONTAINER_REGISTRY`, `ARTIFACT_TAG_PROVIDER`, `OCI_PROVIDER`, `FLUX_SYNC_URL`,
`FLUX_SYNC_CHANNEL`, `PLATFORM_TREE`, `SIGNED_IDENTITY_*`, `FLUX_SEMVER`.

## Source

??? example "components/flux/common/input-provider.yaml"

    ```yaml
    --8<-- "components/flux/common/input-provider.yaml"
    ```

??? example "components/flux/common/resourceset.yaml"

    ```yaml
    --8<-- "components/flux/common/resourceset.yaml"
    ```
