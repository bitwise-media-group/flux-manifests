# Adding a component

A component is a directory under `components/`, published as its own OCI image, and one entry in each cloud's
entrypoint. This page walks through everything a new one needs, using a helm-chart component as the example. Most
platform components are one; a few (gateway, rbac, cert-manager-issuers) are plain manifests and skip the chart steps.

!!! warning "The platform is generic"

    Only add a component here if every cluster could reasonably run it. Something a single application needs belongs in
    that application's own manifest image. See [Applications](../applications.md).

## 1. Mirror the chart first

Clusters only pull charts and images from the platform registry, so the chart and every image it runs must be mirrored
by [flux-containers](https://oss.bitwisemedia.uk/flux-containers/getting-started/adding-a-chart/) before anything here
can reconcile. Note the chart's mirrored path (`charts/<chart>`) and each image's (`images/<upstream path>`), and the
version constraint the mirror carries. Your semver range must sit inside it.

## 2. Create the common tier

```text
components/<name>/common/
  kustomization.yaml     resources: namespace.yaml, input-provider.yaml, resourceset.yaml
  namespace.yaml
  input-provider.yaml    ResourceSetInputProvider: newest mirrored chart tag in range
  resourceset.yaml       ResourceSet: cosign-pub Secret + OCIRepository (verify) + HelmRelease
```

Copy the shape of an existing chart component. [kyverno](../components/kyverno.md) and
[cert-manager](../components/cert-manager.md) are the plainest. [Chart delivery](../concepts/chart-delivery.md) explains
each object and why the OCIRepository sits in `resourcesTemplate` rather than `resources`. The essentials:

- The input provider's `type` is `"${ARTIFACT_TAG_PROVIDER:=GARArtifactTag}"` and its range is
  `"${<NAME>_SEMVER:=<ceiling >=floor}"`, ceiling first (see the comment in any existing provider for why).
- The OCIRepository verify block branches on `SIGNED_IDENTITY_KMS_KEY`, and the `cosign-pub` Secret renders only when
  `COSIGN_PUBLIC_KEY` is set. Copy both verbatim, changing only the namespace and names.
- Every image `repository` points at `${CONTAINER_REGISTRY}/images/<upstream path>`.
- Controllers get `nodeSelector: {role: system}`.
- If terraform grants the component a cloud identity, pin the ServiceAccount name in the values. That namespace/name
  pair is the contract with the cluster module.

The common tier must stay cloud-neutral. It may only reference variables that both clouds publish, and a single-cloud
variable only behind a `:=` default. `make test` enforces this. See [Layout & cloud overlays](../concepts/layout.md).

## 3. Add an overlay per cloud

Each cloud the component runs on needs `components/<name>/<cloud>/kustomization.yaml`. With nothing cloud-specific it's
just the common tier:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../common
```

Anything only one cloud needs (a secret-sync dialect, a cloud-specific policy, an identity annotation) goes in that
overlay as an extra resource. A component that only makes sense on one cloud has only that overlay and no common tier.

## 4. Add it to the entrypoint

Add one `dict` to the `$components` list in `platform/aws/resourceset.yaml`, `platform/google/resourceset.yaml`, or
both:

```yaml
(dict "name" "<name>" "timeout" "5m" "dependsOn" (list "kyverno-policies") "when" (list) "ref"
"${<NAME>_MANIFESTS_REF:=}")
```

- **`dependsOn`**: at least `kyverno-policies` for anything that runs pods, so the signature policy exists first.
- **`when`**: empty for the core tier. For an electable component, list the election names it requires, and add the
  component to `ELECTABLE` in `scripts/validate.sh` so the election-independence guard knows.
- **`ref`**: `${<NAME>_MANIFESTS_REF:=}`, upper-cased with `-` turned into `_`.
- Every dict carries every key; the template renders with `missingkey=error`.

The entrypoint completeness guard fails `make test` if a component has an overlay for a tree but no entry in that tree's
entrypoint, or the other way round. See [Elections & the graph](../concepts/graph.md).

## 5. Add validation fixtures

Every ResourceSet needs sample inputs at `tests/inputs/<name>/{common,<tree>}/<file>.yaml`, standing in for its input
providers:

```yaml
# tests/inputs/<name>/common/resourceset.yaml
- id: "1"
  tag: "1.2.3"
  digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
```

A ResourceSet using the `Permute` input strategy (a chart plus a tracked image) needs `Static` ResourceSetInputProvider
fixtures instead, so the inputs are namespaced exactly as on a cluster. [dex](../components/dex.md)'s fixture is the
example.

If the component ships custom resources kubeconform has no schema for, vendor the schema into `tests/schemas/` (the
refresh command is at the bottom of `scripts/validate.sh`). If an overlay contains only custom resources, add it to the
skip list in the `lint-kustomize` task in `tasks.toml`, because kubescape fails on directories it can't map.

## 6. Cluster variables

A new variable has to be published by the cluster module (`terraform-aws-eks-flux` / `terraform-google-gke-flux`) before
a cluster can use it, and recorded in the env contract here: `tests/aws.env`, `tests/google.env`, or both. The contract
is how the harness knows which cloud publishes what. Add it to [Cluster variables](../reference/cluster-vars.md) too.

## 7. Document it

1. Add `docs/components/<name>.md`, following the shape of the existing pages: a `description` in the front matter (the
   landing page shows it on the component's card), the facts table, what it deploys, the variables it reads, and the
   source embeds.
2. Add the page to the **Components** section of the `nav` in `zensical.toml`. The landing page's marquee, count and
   cards come from that list.
3. Add a row to the [catalogue](../components/index.md) and update the graph on
   [Elections & the graph](../concepts/graph.md).

## 8. Validate and ship

```sh
make pr
```

Then follow the [daily workflow](daily-workflow.md). A new component is a `feat`. The publish workflows pick up every
directory under `components/` automatically, so nothing else needs registering.
