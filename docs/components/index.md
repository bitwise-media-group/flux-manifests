# Catalogue

Every component the platform can run, side by side. Each is published as `oci://<registry>/manifests/<name>` and applied
by the entrypoint as the Kustomization `<name>` in `flux-system`. The graph and the election rules are on
[Elections & the graph](../concepts/graph.md).

| component                                                       | tier      | clouds | depends on                              | namespace                      | delivers                                                    |
| --------------------------------------------------------------- | --------- | ------ | --------------------------------------- | ------------------------------ | ----------------------------------------------------------- |
| [kyverno](kyverno.md)                                           | core      | both   |                                         | `kyverno`                      | chart `kyverno`                                             |
| [kyverno-policies](kyverno-policies.md)                         | core      | both   | kyverno                                 | (cluster-scoped)               | ClusterPolicy `verify-platform-signature`                   |
| [flux](flux.md)                                                 | core      | both   | kyverno-policies                        | `flux-system`                  | charts `flux-operator` + `flux-instance` (adopted)          |
| [cilium](cilium.md)                                             | core      | aws    | gateway-api-crds (while installed)      | `kube-system`                  | chart `cilium` (adopted)                                    |
| [cert-manager](cert-manager.md)                                 | core      | both   | kyverno-policies                        | `cert-manager`                 | chart `cert-manager`                                        |
| [cert-manager-issuers](cert-manager-issuers.md)                 | core      | both   | cert-manager                            | (cluster-scoped)               | ClusterIssuers `letsencrypt-prod`, `letsencrypt-staging`    |
| [aws-load-balancer-controller](aws-load-balancer-controller.md) | core      | aws    | kyverno-policies                        | `aws-load-balancer-controller` | chart `aws-load-balancer-controller`                        |
| [external-dns](external-dns.md)                                 | core      | both   | kyverno-policies                        | `external-dns`                 | chart `external-dns` + tracked image                        |
| [gateway](gateway.md)                                           | core      | both   | cert-manager-issuers                    | `gateway`                      | Gateway `platform`, Certificate `platform-wildcard`         |
| [rbac](rbac.md)                                                 | core      | both   |                                         | (cluster-scoped)               | ClusterRoleBindings for the platform groups                 |
| [secret-sync](secret-sync.md)                                   | core      | aws    | kyverno-policies                        | `secret-sync`                  | chart `secrets-store-sync-controller`                       |
| [dex](dex.md)                                                   | electable | both   | kyverno-policies, gateway, secret-sync¹ | `dex`                          | chart `dex` + tracked image, `dex-env` secret sync          |
| [flux-web](flux-web.md)                                         | electable | both   | gateway, secret-sync¹, dex              | `flux-system`                  | HTTPRoute `flux.`, `flux-web-auth` secret sync, edge policy |
| [arc](arc.md)                                                   | electable | both   | kyverno-policies                        | `arc-systems`                  | chart `gha-runner-scale-set-controller`                     |

¹ aws only; the google entrypoint has no secret-sync component.

## Common to every chart component

- The chart and every image come from the platform registry, mirrored by
  [flux-containers](https://oss.bitwisemedia.uk/flux-containers/charts/). Each component page links its chart's mirror
  page.
- The chart version is the newest mirrored tag inside the component's `<NAME>_SEMVER` range.
- The chart OCIRepository is cosign-verified against `SIGNED_IDENTITY_CHARTS`, or the `cosign-pub` Secret in KMS mode.
- Controllers run on the system node pool (`nodeSelector: {role: system}`).

The pattern is explained once, in [Chart delivery](../concepts/chart-delivery.md); the component pages cover what's
specific to each.

## Common to every component

- Its Kustomization's timeout comes from the entrypoint (`10m` for kyverno and cert-manager, `15m` for cilium, `5m` for
  the rest), with `wait: true`, `prune: true`, a 30-minute interval and a 2-minute retry.
- `<NAME>_MANIFESTS_REF` pins its manifests image to a tag; empty, it follows `FLUX_SYNC_CHANNEL`.
