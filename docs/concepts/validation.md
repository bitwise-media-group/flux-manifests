# Validation

`make test` runs `scripts/validate.sh`, which renders everything each cluster would apply and checks it. It's built to
fail locally, with a message naming the file, for exactly the mistakes that would otherwise only fail on a cluster.

## The passes

Everything renders **four times**: `{google,aws} × {keyless,keyed}`. Each pass runs in a subshell with only that cloud's
env contract loaded, so one cloud's variables can never leak into the other's render. Their absence is part of what's
being tested.

For each pass:

1. **Build.** `kustomize build` every component overlay for the tree (`components/<name>/<tree>`, which pulls in
   `../common`) and the tree's entrypoint (`platform/<tree>`).
2. **Substitute.** Apply the env contract the way kustomize-controller's `postBuild` does. See
   [faithful substitution](#faithful-substitution) below.
3. **Render.** Render every ResourceSet with sample inputs through the flux-operator CLI
   (`flux-operator build resourceset`), the entrypoint included.

Then, once per tree, the graph guards run over the keyless render, and finally **kubeconform** validates every built and
rendered document against the Kubernetes schemas, the Flux schemas, and the CRD schemas vendored in `tests/schemas/`.

## The env contract

`tests/<tree>.env` is the full set of variables that cloud's cluster module publishes, with realistic values.
`tests/<tree>.keyed.env` is sourced on top for the KMS-signing passes: it sets `SIGNED_IDENTITY_KMS_KEY` and
`COSIGN_PUBLIC_KEY` and empties the keyless identities. The google keyed overlay also doubles as the **sparse** caller,
publishing every optional surface empty (`DEX_DIRECTORY_SA=`, `DEX_CONNECTORS='[]'`, `DEX_CLIENTS='[]'`), the
composition that once reproduced a live empty-variable bug.

These files are the machine-readable copy of [Cluster variables](../reference/cluster-vars.md). The guards read the
**names** they publish to decide which variables belong to which cloud. A variable that's in neither file doesn't exist
as far as the harness is concerned.

No application variable appears in them. A platform manifest that reads one fails strict substitution.

## Faithful substitution

kustomize-controller doesn't substitute text directly: it parses each manifest, serialises it (dropping redundant
quotes), substitutes textually, and parses again. The harness does the same: it normalises every scalar's style with
`yq`, then runs a textual `envsubst`. A quoted empty variable therefore becomes null locally exactly as it would on a
cluster. ([The empty-var convention](substitution.md) explains why that matters.)

Two more details keep the render faithful:

- **Strict mode.** Before substituting, every bare `${VAR}` in the file must be set in the env, or the run fails, just
  as the controller's strict mode would.
- **Bare `$VAR` is shielded.** `yq`'s `envsubst` would also replace bare `$VAR` (dex's own references, Go template
  variables) where the controller only touches `${…}`. These are hidden behind a sentinel and restored afterwards.

## The guards

| guard                   | fails when                                                                                                                                                                               |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| null-guard self-test    | the null guard no longer trips on a canary empty quoted variable. Runs first, so the guard can't rot unnoticed                                                                           |
| null guard              | a `${VAR}`-bearing scalar becomes null after substitution                                                                                                                                |
| strict substitution     | a bare `${VAR}` isn't published by the tree's env contract                                                                                                                               |
| common neutrality       | a `common/` tier branches on cloud, or bare-references a variable only one cloud publishes                                                                                               |
| dead defaults           | a per-cloud overlay or entrypoint keeps a `:=` default on a variable its own cloud always publishes                                                                                      |
| entrypoint completeness | a shipped overlay has no `platform-<name>` in the entrypoint (or vice versa), a `dependsOn` names a Kustomization nothing emits, or a Kustomization's `path` isn't in the image it reads |
| election independence   | under the `none` election, a core component is missing or an electable one is present                                                                                                    |

The completeness guard counts Kustomizations emitted by component ResourceSets too, so the aws `cilium` →
`gateway-api-crds` dependency resolves against the one the gateway component emits. It also checks every one of those
Kustomizations against the image it reads: a source named `platform-<name>` carries `components/<name>/` and
`flux-system` carries `platform/`, so the `path` must hold a `kustomization.yaml` there. A path missing from its image
renders cleanly and fails only on a cluster.

The list of electable components the independence guard uses is `ELECTABLE` at the top of `scripts/validate.sh`. Keep it
in step with the `when` lists in the entrypoints.

## Fixtures

Every ResourceSet needs sample inputs, looked up as `tests/inputs/<component>/<tree>/<file>.yaml` first, then
`tests/inputs/<component>/common/<file>.yaml`. The tree directory shadows `common` per file name.

- **Input lists** (`--inputs-from`): a YAML list of input sets standing in for a tag provider.
- **Static providers** (`--inputs-from-provider`): `ResourceSetInputProvider` manifests of `type: Static`, for
  ResourceSets using the `Permute` strategy, so inputs are namespaced by provider name exactly as on a cluster.
- **Variants**: a `<file>.<variant>.yaml` sibling renders the same ResourceSet again with a different input set, so both
  sides of an input branch get validated. The entrypoint uses this: `resourceset.yaml` elects everything,
  `resourceset.none.yaml` elects nothing.

A fixture on the empty side of a branch may legitimately render nothing; the harness accepts exactly that failure from
the CLI and keeps the empty render.

## Schemas

kubeconform runs in strict mode against the default Kubernetes schemas, the
[flux2-schemas](https://github.com/fluxcd-community/flux2-schemas) catalogue, and the JSON schemas in `tests/schemas/`
for everything else (kyverno, cert-manager, Gateway API, Cilium, secret sync, flux-operator, GKE). Those are converted
from upstream CRDs:

```sh
curl <crd-yaml> | yq -o=json '.spec.versions[0].schema.openAPIV3Schema'
```

`CustomResourceDefinition` itself is skipped: the vendored Gateway API CRDs are upstream-generated.

## Other checks

`make lint` adds, among the toolchain's standard checks, a kubescape configuration scan over every per-cloud component
overlay. Overlays made only of custom resources kubescape can't map (cert-manager-issuers, cilium, flux,
kyverno-policies, rbac, secret-sync) are skipped; the workloads themselves are scanned in flux-containers, over each
chart's rendered manifests. Accepted kubescape findings live in `.kubescape/exceptions.json`.
