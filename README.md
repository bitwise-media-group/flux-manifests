# flux-manifests

The **platform** every cluster syncs: a small entrypoint image plus one cosign-signed OCI image per component, published
to the platform registry and consumed by each cluster's FluxInstance on a channel tag (`edge`, `staging` or `stable`).
The FluxInstance syncs the entrypoint alone (`oci://<registry>/manifests/platform`, path `aws` or `google`); its one
`ResourceSet` elects the components the cluster runs and emits, per component, the `OCIRepository` that pulls
`oci://<registry>/manifests/<component>` and the `Kustomization` that applies that component's overlay for the cloud.
Nothing is edited per cluster: all remaining variation arrives through the `cluster-vars` ConfigMap the cluster module
publishes.

The platform is generic. It knows no application by name: applications are their own manifest images, seeded once by the
cluster module and self-owned afterwards, and everything an application needs from the platform - a host on the Gateway,
a dex client, an image-signature exception, secret sync, RBAC on the platform's groups - is a contract it consumes
rather than a branch inside a platform component.

## Documentation

The documentation site at <https://oss.bitwisemedia.uk/flux-manifests/> covers how the platform works and has a page per
component. Start with:

- [Architecture](docs/concepts/architecture.md) and [Elections & the graph](docs/concepts/graph.md) - how one sync
  becomes the whole platform
- [Components](docs/components/index.md) - what each component deploys, its clouds, dependencies and variables
- [Applications](docs/applications.md) - the contracts an application consumes
- [Cluster variables](docs/reference/cluster-vars.md) - the terraform to flux contract
- [Releases & channels](docs/concepts/releases.md) and [Operations](docs/reference/operations.md) - publishing,
  promotion, pinning and re-pointing
- [Migrating from 3.x](docs/reference/migrating-3x.md)

Preview it locally with `make serve`. See [Working on the docs](docs/reference/docs.md).

## Layout

```text
platform/{aws,google}/            the entrypoint: one ResourceSet per cloud    -> oci://<registry>/manifests/platform
components/<name>/common/         the component's cloud-neutral tier
components/<name>/{aws,google}/   the per-cloud overlay (resources: ../common + cloud files)
                                                                             -> oci://<registry>/manifests/<name>
tests/                            the cluster-vars env contract, render fixtures, vendored CRD schemas
scripts/                          validate.sh (make test) and publish.sh (the publish workflows)
docs/ · zensical.toml             the documentation site
```

Three rules keep the layout honest, and `make test` enforces each of them: a common tier references only variables both
clouds publish (a single-cloud variable only behind a `:=` default), a per-cloud overlay carries no defaults left over
for the other cloud, and the entrypoint is the graph - ordering, timeouts, election gates and release pins live in
`platform/<tree>/resourceset.yaml` and nowhere else. See [Layout & cloud overlays](docs/concepts/layout.md).

## What the platform deploys

```text
kyverno ──► kyverno-policies ──┬──► cert-manager ──► cert-manager-issuers ──► gateway ──┬──► dex ──► flux-web
    (policy engine)   (gate)   ├──► external-dns                                       │      ▲
                               ├──► flux                                               │      │
                               ├──► secret-sync (aws) ─────────────────────────────────┴──────┘
                               ├──► aws-load-balancer-controller (aws)
                               └──► arc
gateway-api-crds (aws, GATEWAY_API_CRDS) ──► cilium (aws)          rbac (no dependencies)
```

The **core tier** deploys on every cluster; the **electable tier** (`dex`, `flux-web`, `arc`) deploys only when named in
the `PLATFORM_COMPONENTS` cluster var. Every chart comes from the platform registry, mirrored, scanned and signed by
[flux-containers](https://github.com/bitwise-media-group/flux-containers), and every pod image must carry the platform
pipeline's signature to be admitted. See the [component catalogue](docs/components/index.md).

## Development

Clone with `--recurse-submodules` (the toolchain lives at `.mise/`), then `mise trust --all` once. `make help` lists
tasks.

```sh
make test    # render + guard + kubeconform every tree, {google,aws} x {keyless,keyed}
make lint    # license headers, prose, workflows, shell, kubescape
make pr      # fmt + lint + test + docs build, before opening a pull request
make serve   # preview the docs on http://localhost:8004
```

release-please cuts `vX.Y.Z` from Conventional Commits. Every merge to main publishes `edge`; a release publishes
`staging`; the gated promote workflow moves `stable`. See [Releases & channels](docs/concepts/releases.md).
