# Elections & the graph

The entrypoint, `platform/<tree>/resourceset.yaml`, is a list. Each entry names a component, its timeout, what it
depends on, which elections it needs and which release pin variable it reads. A template walks the list and emits an
`OCIRepository` and a `Kustomization` for every entry that's switched on.

```yaml
<< $components := list (dict "name" "kyverno" "timeout" "10m" "dependsOn" (list) "when" (list) "ref"
"${KYVERNO_MANIFESTS_REF:=}") (dict "name" "kyverno-policies" "timeout" "5m" "dependsOn" (list "kyverno") "when" (list)
"ref" "${KYVERNO_POLICIES_MANIFESTS_REF:=}") … (dict "name" "flux-web" "timeout" "5m" "dependsOn" (list "gateway"
"secret-sync" "dex") "when" (list "flux-web" "dex") "ref" "${FLUX_WEB_MANIFESTS_REF:=}") >>
```

## The dependency graph

```text
kyverno ──► kyverno-policies ──┬──► cert-manager ──► cert-manager-issuers ──► gateway ──┬──► dex ──► flux-web
    (policy engine)   (gate)   ├──► external-dns                                       │      ▲
                               ├──► flux                                               │      │
                               ├──► secret-sync (aws) ─────────────────────────────────┴──────┘
                               ├──► aws-load-balancer-controller (aws)
                               └──► arc
gateway-api-crds (aws, GATEWAY_API_CRDS) ──► cilium (aws)          rbac (no dependencies)
```

`kyverno-policies` is the gate: almost everything that runs pods waits for the signature policy to exist, so no
component can start an unverified image while the policy is still being installed. On google the `secret-sync` edges
don't exist, because GKE syncs secrets natively.

Every emitted Kustomization uses `wait: true`, so a dependant only starts once everything it depends on is healthy.

## Two tiers

The **core tier** has no election gate and deploys on every cluster:

- **both clouds**: kyverno, kyverno-policies, flux, cert-manager, cert-manager-issuers, external-dns, gateway, rbac
- **aws only**: cilium, aws-load-balancer-controller, secret-sync

The **electable tier** deploys only when named in the `PLATFORM_COMPONENTS` cluster variable:

| component  | elected by                                                                                      |
| ---------- | ----------------------------------------------------------------------------------------------- |
| `dex`      | the cluster module, exactly when its `sso` toggle is on. Don't elect it by hand.                |
| `flux-web` | naming it; it also requires `dex`, since it's nothing but the Flux UI's SSO wiring and its edge |
| `arc`      | naming it                                                                                       |

`PLATFORM_COMPONENTS` is a comma-separated list of short names. Unset, it elects `dex,flux-web`. The reserved name
`none`, which terraform publishes for an empty election, matches nothing. An entry's `when` list must be fully elected
for it to render.

`make test` renders the entrypoint twice per cloud, with everything elected and with `none`, and the
election-independence guard checks the `none` render still emits every core component and no electable one. See
[Validation](validation.md).

## Release pins

Each entry's `ref` is its `<NAME>_MANIFESTS_REF` cluster variable: the component name upper-cased, with `-` turned into
`_` (`CERT_MANAGER_ISSUERS_MANIFESTS_REF`). Empty, the component follows the cluster's channel (`FLUX_SYNC_CHANNEL`);
set to a version, it pulls that tag instead. See [Operations](../reference/operations.md#pinning-a-component).

## Template mechanics

A few details of the template are deliberate:

- **Every `dict` carries every key.** flux-operator renders with `missingkey=error`, so a missing key fails the render
  rather than silently becoming empty.
- **`$on` is declared in the outer scope** so the inner `range` over an entry's `when` list can switch it off.
- **`${…}` is substituted first.** Flux's post-build substitution runs before the ResourceSet template, so the variable
  names in the list are plain text to the template engine, and an empty pin variable is just `""`.
- **The verify block follows the signing mode.** `$keyed` is true when `SIGNED_IDENTITY_KMS_KEY` is set, switching each
  OCIRepository from keyless identity matching to the `cosign-pub` Secret. See [Signing & verification](signing.md).
- **aws only: `$crds`.** `cilium` depends on `gateway-api-crds` only while `GATEWAY_API_CRDS` is `true`. See
  [cilium](../components/cilium.md).

## The source

??? example "platform/aws/resourceset.yaml"

    ```yaml
    --8<-- "platform/aws/resourceset.yaml"
    ```

??? example "platform/google/resourceset.yaml"

    ```yaml
    --8<-- "platform/google/resourceset.yaml"
    ```
