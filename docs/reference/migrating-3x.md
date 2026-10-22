# Migrating from 3.x

3.x shipped the whole repository as one artifact (`oci://<registry>/flux-manifests`, tree roots `aws/` and `google/`)
and carried the patchy application inside it. 4.0 publishes the
[entrypoint and one image per component](../concepts/architecture.md), and patchy moves to its own repository and image,
seeded by the cluster module (see [Applications](../applications.md)).

## On a running cluster, in order

1. **Promote the transitional 3.x release** (the last 3.x). It annotates the eleven tree-root Kustomizations
   `kustomize.toolkit.fluxcd.io/prune: disabled`, sets `prune: false` on `optional` and everything it emits, renders
   `sync.url` from `FLUX_SYNC_URL` when set, and issues `Certificate platform-wildcard` (`platform-tls`) ahead of the
   listener swap. Verify the annotations and the wildcard Secret.
2. **Freeze the optional tier.** Run `flux suspend ks optional -n flux-system` and annotate `ResourceSet/optional` with
   `fluxcd.controlplane.io/reconcile=disabled`.
3. **Apply the 4.x cluster module** with the application composed in the root. `cluster-vars` gains the new keys
   (including `FLUX_SYNC_URL`), `<app>-vars` appears, and the application seed is created and adopts the application's
   existing Kustomization.
4. **Re-point.** Run `flux reconcile ks flux -n flux-system`. The transitional flux component asserts the new
   `sync.url`; source-controller pulls `manifests/platform:<channel>`; the `flux-system` Kustomization applies
   `ResourceSet/platform`, and its prune skips the annotated eleven; the `platform-<name>` sources appear and the
   same-named Kustomizations are adopted. The Gateway swaps to the wildcard listener (`platform-tls` is already issued)
   and routes attach by hostname. Verify every Kustomization and source is Ready, HelmReleases are on their previous
   revisions, and TLS is serving.
5. **Remove the old tier.** Delete the `dex-cloud`, `flux-web-cloud` and `<app>-cloud` Kustomizations (prune is off),
   `ResourceSet/optional`, `Kustomization/optional`, and the old `patchy-tls` Certificate.

## Rolling back

Through step 4, patch the FluxInstance back to the old URL (see
[Re-pointing a cluster](operations.md#re-pointing-a-cluster)). The eleven Kustomizations are re-adopted by
`flux-system`; then `flux resume ks optional`. Nothing was deleted while prune was on.

## Contract changes

| change  | variables                                                                                                                                     |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| new     | `PLATFORM_COMPONENTS`, `PLATFORM_TREE`, `PLATFORM_DOMAIN`, `FLUX_SYNC_URL`, `DEX_CLIENTS`, the `<NAME>_MANIFESTS_REF` and `ARC_SEMVER` extras |
| removed | `STACK_COMPONENTS`, `FLUX_SYNC_PATH`, `PATCHY_DOMAIN`, `PATCHY_EVALUATION`, `AGENT_*`, `CLAUDE_*`, `SCC_*`, `KUBECTL_OIDC_*`                  |

The removed application variables are application-owned now, delivered through `<app>-vars`; kubectl's public client
arrives in `DEX_CLIENTS`. The google module must publish the new keys to sync 4.0.
