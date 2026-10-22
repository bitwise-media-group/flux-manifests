# Operations

Day-two tasks on a running cluster, and the caveats worth knowing before you need them.

## Bootstrap order

A cluster can only reconcile the platform once the registry holds everything it pulls:

1. every chart and image, published by [flux-containers](https://oss.bitwisemedia.uk/flux-containers/);
2. every `manifests/<component>` image and the `manifests/platform` entrypoint, published by this repository;
3. a published channel for the cluster to follow. The first cluster apply needs `staging` or `stable` to exist, unless
   the cluster follows `edge`.

## Enforcing the signature policy

The [signature policy](../components/kyverno-policies.md) starts in `Audit` on a fresh cluster. Review the
PolicyReports, then switch it to `Enforce` through terraform's `flux.cluster_vars`:

```hcl
cluster_vars = {
  KYVERNO_FAILURE_ACTION = "Enforce"
}
```

No manifests release is needed; the next reconcile of `kyverno-policies` picks it up.

## Pinning a component

Every component follows the cluster's channel unless its `<NAME>_MANIFESTS_REF` variable is set: the component name
upper-cased, with `-` turned into `_`. Set it through terraform's caller extras:

```hcl
cluster_vars = {
  DEX_MANIFESTS_REF = "4.1.0"   # hold dex on 4.1.0 whatever the channel does
}
```

Use it to soak a new component version on one cluster before it reaches the channel, or to hold one back while a problem
is fixed.

!!! warning "A pin outlives the channel"

    The component stays on its tag through every channel move until the variable is removed. Pin to soak or to hold
    back, never to forget.

## Narrowing a chart range

Each chart component follows the newest mirrored chart in its `<NAME>_SEMVER` range (and tracked images in
`<NAME>_IMAGE_SEMVER`). Override the range per cluster to hold a chart below a version, or to raise a floor:

```hcl
cluster_vars = {
  KYVERNO_SEMVER = "<3.9.0 >=3.8.0"
}
```

Write the ceiling first: kustomize drops the quotes, and a plain YAML scalar starting with `>` is a folded block.

## Re-pointing a cluster

`flux.sync.url` and `flux.sync.path` are applied by terraform at bootstrap and published as `FLUX_SYNC_URL` and
`PLATFORM_TREE`. The platform's own [flux](../components/flux.md) component re-asserts both on the FluxInstance, which
is platform-managed (terraform ignores it after bootstrap). Changing either in terraform therefore re-points a running
cluster on the next reconcile of `flux`.

To recover a cluster stranded on an image or path that no longer exists, patch the FluxInstance directly. The platform
then holds the value as a fixed point:

```sh
kubectl patch fluxinstance flux -n flux-system --type merge \
  -p '{"spec":{"sync":{"url":"oci://<registry>/manifests/platform","path":"aws"}}}'    # "google" on a GKE cluster
```

## Changing the election

Edit the cluster's `PLATFORM_COMPONENTS` (through the cluster module, which also adds `dex` when `sso` is on). Electing
a component makes the entrypoint emit it on the next reconcile; un-electing one makes the entrypoint stop emitting its
Kustomization, which prunes it.

Un-electing `flux-web` keeps `flux-system`. The component adopts that namespace to label it, and its manifest carries
`kustomize.toolkit.fluxcd.io/prune: disabled` so removing the component can never garbage-collect the namespace Flux
runs in. Don't remove that label.

## Caveats

- **Gateway `NamedAddress` (google).** Verify the accepted `spec.addresses.type` on the cluster's GKE version at first
  apply; `networking.gke.io` annotations are the fallback.
- **Gateway API CRDs on aws land after Cilium starts.** EKS ships no Gateway API CRDs, so the gateway component installs
  them while `GATEWAY_API_CRDS` holds, and the entrypoint makes `cilium` wait for them so its first Flux reconcile (and
  rollout) happens after they're established. When AWS ships the CRDs as managed cluster furniture, switch the cluster
  module's `gateway.install_crds` off. The dependency goes with the toggle, and the CRDs are orphaned (`prune: false`),
  because deleting them would cascade into every Gateway and HTTPRoute. See [cilium](../components/cilium.md).
- **Adopting Cilium on an existing cluster.** Check the live version is in `CILIUM_SEMVER`'s range and that terraform
  sets no `helm_values` overrides first. See
  [cilium](../components/cilium.md#before-pointing-an-existing-cluster-at-it).
- **Kyverno webhooks outlive an uninstall.** The chart's cleanup hooks are disabled to keep the mirrored image set
  exact, so if the kyverno release is ever uninstalled, remove its webhook configurations by hand.
