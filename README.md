# flux-manifests

The GitOps stack every patchy-platform GKE cluster syncs: one consistent `stack/` packaged as a **keyless-cosign-signed
OCI artifact** in the platform Artifact Registry, consumed by each cluster's FluxInstance on a channel tag (`edge`,
`staging` or `stable`). Nothing is edited per cluster — all variation arrives through the `cluster-vars` ConfigMap the terraform
module publishes.

## What the stack deploys

```text
kyverno ──► kyverno-policies ──┬──► cert-manager ──► cert-manager-issuers ──► gateway
    (policy engine)   (gate)   ├──► external-dns
                               └──► otel-collector
```

| component                  | role                                                                                                                                              |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| kyverno + kyverno-policies | admission enforcement: every pod image must carry a keyless signature from the platform publish workflow (GKE system registries excluded)         |
| cert-manager (+ issuers)   | Let's Encrypt via DNS-01 against the delegated Cloud DNS zone; Gateway API integration on                                                         |
| external-dns               | publishes Gateway HTTPRoute hosts into the delegated zone (per-cluster ownership, pruning sync)                                                   |
| gateway                    | the shared `gke-l7-global-external-managed` Gateway on the terraform-reserved static IP + the webhook host's certificate                          |
| otel-collector             | the platform OTLP endpoint (`otel-collector.otel-collector:4317`) forwarding traces/logs to Cloud Trace/Logging and metrics to Managed Prometheus |

Every chart component is a `GARArtifactTag` ResourceSetInputProvider (newest in-range chart version in the platform
registry) plus a ResourceSet templating an OCIRepository (**keyless verify** via `matchOIDCIdentity`) and a HelmRelease.
A flux-containers publish therefore rolls out on the next reconcile — bounded by each component's semver range,
overridable per cluster via `*_SEMVER` cluster vars.

## The terraform ↔ flux contract (cluster-vars)

Published by `terraform-google-gke-flux` into the `cluster-vars` ConfigMap (flux-system) and substituted into every
Kustomization (`${VAR}`, `${VAR:=default}`); optional surfaces use the empty-string convention.

| key                      | example                                            | consumed by                                                      |
| ------------------------ | -------------------------------------------------- | ---------------------------------------------------------------- |
| `CLUSTER_NAME`           | `patchy-x`                                         | external-dns (txtOwnerId)                                        |
| `GCP_PROJECT`            | `x-patchy-app-ab12`                                | external-dns, issuers                                            |
| `GCP_PROJECT_NUMBER`     | `123456789012`                                     | (published for component use)                                    |
| `GCP_REGION`             | `us-central1`                                      | (published for component use)                                    |
| `PLATFORM_REGISTRY`      | `us-central1-docker.pkg.dev/…/platform`            | every RSIP + OCIRepository                                       |
| `CONTAINER_REGISTRY`     | same                                               | every HelmRelease image value (`images/<upstream-path>`)         |
| `OCI_PROVIDER`           | default `gcp`                                      | OCIRepository registry auth                                      |
| `SIGNED_IDENTITY_ISSUER` | `^https://token\.actions\.githubusercontent\.com$` | verify blocks + kyverno policy                                   |
| `SIGNED_IDENTITY_CHARTS` | flux-containers publish@main regexp                | chart OCIRepository verify                                       |
| `SIGNED_IDENTITY_IMAGES` | flux-containers publish@main regexp                | kyverno policy                                                   |
| `DNS_ZONE_NAME`          | `patchy-bitwisemedia-co-uk`                        | external-dns zone filter                                         |
| `DNS_DOMAIN`             | `patchy.bitwisemedia.co.uk`                        | external-dns domain filter                                       |
| `PATCHY_DOMAIN`          | `patchy.bitwisemedia.co.uk`                        | gateway listener + certificate                                   |
| `ACME_EMAIL`             | `you@bitwisemedia.co.uk`                           | issuers                                                          |
| `GATEWAY_ADDRESS_NAME`   | `patchy-x-gateway`                                 | gateway (NamedAddress)                                           |
| `GATEWAY_IP`             | `203.0.113.10`                                     | (informational)                                                  |
| `OTEL_PROJECT`           | `x-patchy-app-ab12`                                | otel-collector exporters                                         |
| `KYVERNO_FAILURE_ACTION` | default `Audit`                                    | kyverno policy — flip to `Enforce` after soaking a fresh cluster |
| `*_SEMVER`               | `>=3.8.0 <4.0.0`                                   | per-component chart range overrides                              |

Workload identity contract (namespace/serviceaccount names terraform grants against — pinned in the HelmRelease values
here): `external-dns/external-dns`, `cert-manager/cert-manager`, `otel-collector/otel-collector`,
`kyverno/kyverno-{admission,reports}-controller`, `flux-system/{source-controller,flux-operator}`.

## Releases and channels

release-please cuts `vX.Y.Z` from Conventional Commits; **publish.yaml** pushes the signed artifact and moves `staging`;
**promote.yaml** (workflow_dispatch, `production` environment) moves `stable` after soak. **publish-edge.yaml**
additionally pushes every merge to main as the `edge` channel — for dev/sandbox clusters that validate trunk
continuously; the release channels only ever see release-tagged artifacts. Clusters pin their channel in terraform
(`flux.sync.ref`). The signing identity clusters verify is exactly
`…/flux-manifests/.github/workflows/publish.yaml@refs/tags/v*` for `staging`/`stable`, and
`…/publish-edge.yaml@refs/heads/main` for `edge`.

## Validation

`make test` renders every component and the stack, substitutes the `tests/cluster-vars.env` fixture the way
kustomize-controller postBuild does, renders each ResourceSet with `tests/inputs/` fixtures via the flux-operator CLI,
and kubeconforms everything against flux + vendored CRD schemas (`tests/schemas/`, regenerated from upstream CRDs — see
scripts/validate.sh).

## Caveats

- **Bootstrap order**: the platform registry must hold every chart + image (flux-containers) before a cluster can
  reconcile this stack, and the first cluster apply needs a published (staging or stable) artifact.
- **Kyverno starts in Audit**: the policy's failureAction defaults to Audit — review PolicyReports on a fresh cluster,
  then set `KYVERNO_FAILURE_ACTION=Enforce` via terraform's `flux.cluster_vars`.
- **Patchy's Cilium FQDN egress toggle won't work here**: GKE Dataplane V2 rejects raw `CiliumNetworkPolicy`, and
  `FQDNNetworkPolicy` needs GKE Enterprise. Deploy patchy with its baseline Kubernetes NetworkPolicy until that changes
  — don't flip `agent.networkPolicy.cilium.enabled` expecting it to work.
- **Gateway `NamedAddress`**: verify the accepted `spec.addresses.type` on the cluster's GKE version at first apply
  (`networking.gke.io` annotations are the fallback).
