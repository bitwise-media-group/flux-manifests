# Layout & cloud overlays

```text
platform/{aws,google}/            the entrypoint: one ResourceSet per cloud    -> oci://<registry>/manifests/platform
components/<name>/common/         the component's cloud-neutral tier
components/<name>/{aws,google}/   the per-cloud overlay (resources: ../common + cloud files)
                                                                             -> oci://<registry>/manifests/<name>
```

Every component ships one overlay per cloud it supports, and the entrypoint's Kustomization for it always points at
`./aws` or `./google` inside the component's own image. Four shapes cover every component:

| shape                       | components                                                    | overlay contents                         |
| --------------------------- | ------------------------------------------------------------- | ---------------------------------------- |
| common tier verbatim        | kyverno, cert-manager, flux, rbac, arc                        | `resources: [../common]`                 |
| common tier + cloud dialect | dex, flux-web                                                 | `../common` plus secret sync, edge files |
| one cloud only              | cilium, aws-load-balancer-controller, secret-sync (aws)       | the whole component, no `common/`        |
| per-cloud, no shared tier   | kyverno-policies, cert-manager-issuers, external-dns, gateway | each cloud's own manifests               |

The last row is components whose every file differs by cloud (a KMS URI scheme, a DNS solver, a Gateway class), so
there's nothing to share.

## The rules

The layout is only useful if the common tier really is cloud-neutral and the overlays really are cloud-specific. Three
rules keep it that way, and `make test` enforces all of them.

### `common/` may only reference both-cloud variables

A component's common tier is applied verbatim on both clouds, and kustomize-controller substitutes in **strict** mode: a
bare `${VAR}` fails the whole Kustomization on any cluster whose `cluster-vars` doesn't publish `VAR`. So a variable
that only one cloud's module publishes may appear in `common/` **only** behind a `:=` default, and only for per-cluster
_elections_ (an optional surface the other cloud simply doesn't have), never for cloud identity.

Branching on the cloud is banned outright: any `inputs.cloud` or `${CLOUD…}` reference in a common tier fails the run.

The harness knows which cloud publishes what from the env contracts in `tests/` (see
[Validation](validation.md#the-env-contract)).

### Per-cloud overlays carry no cross-cloud defaults

Inside an `aws/` or `google/` overlay, or that cloud's entrypoint, a `:=` default on a variable that cloud's own module
always publishes is dead code. Such defaults only ever existed so a shared tree could survive the _other_ cloud's strict
substitution. The dead-default guard fails them: use the bare `${VAR}` instead, so a missing variable fails loudly
rather than silently taking a default.

Defaults on genuinely optional variables (published by neither module, or by both) are fine.

### The entrypoint is the graph

Ordering (`dependsOn`), timeouts, election gates and per-component release pins live in
`platform/<tree>/resourceset.yaml` and nowhere else. Components don't declare dependencies on each other. `make test`
proves the list complete: every overlay the tree ships is emitted, and every `dependsOn` resolves. See
[Elections & the graph](graph.md).

## Inside a component

Most components are a chart delivered from the mirror:

```text
components/kyverno/common/
  kustomization.yaml     the resource list
  namespace.yaml         the component's namespace
  input-provider.yaml    lists the newest mirrored chart tag in range
  resourceset.yaml       cosign-pub Secret (KMS mode) + OCIRepository + HelmRelease
```

[Chart delivery](chart-delivery.md) explains the pattern. Plain-manifest components (gateway, rbac,
cert-manager-issuers, flux-web) hold the manifests directly, using a ResourceSet only where a template is needed to make
an object or a key conditional (see [The empty-var convention](substitution.md)).

Files named `resourceset-<purpose>.yaml` are companion ResourceSets in an overlay, for example
`resourceset-secrets.yaml` for a component's secret sync, or `resourceset-crds.yaml` for the Gateway API CRDs on aws.
