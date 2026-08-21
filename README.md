# flux-manifests

The GitOps stack every patchy-platform GKE cluster syncs: one consistent `stack/` packaged as a **keyless-cosign-signed
OCI artifact** in the platform Artifact Registry, consumed by each cluster's FluxInstance on a channel tag (`edge`,
`staging` or `stable`). Nothing is edited per cluster — all variation arrives through the `cluster-vars` ConfigMap the
terraform module publishes.

## What the stack deploys

```text
kyverno ──► kyverno-policies ──┬──► cert-manager ──► cert-manager-issuers ──► gateway
    (policy engine)   (gate)   ├──► external-dns
                               ├──► otel-collector
                               └──► flux
```

| component                  | role                                                                                                                                                                                                                                                                  |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| kyverno + kyverno-policies | admission enforcement: every pod image must carry a cosign signature from the platform pipeline — keyless identity or, in KMS mode, the signing key (cloud system registries excluded)                                                                                |
| cert-manager (+ issuers)   | Let's Encrypt via DNS-01 against the delegated zone (Cloud DNS / Route53 by `CLOUD`); Gateway API integration on                                                                                                                                                      |
| external-dns               | publishes Gateway HTTPRoute hosts into the delegated zone (per-cluster ownership, pruning sync)                                                                                                                                                                       |
| gateway                    | the shared platform Gateway on terraform-reserved addresses + the platform hostnames' certificate — a GKE global external ALB (`NamedAddress`) on google, a Cilium Gateway whose Service the AWS Load Balancer Controller binds to the reserved EIPs as an NLB on aws |
| otel-collector             | the platform OTLP endpoint (`otel-collector.otel-collector:4317`) forwarding by `CLOUD`: Cloud Trace/Logging + Managed Prometheus on google; X-Ray + CloudWatch (EMF metrics, plus AMP remote-write when `OTEL_AMP_ENDPOINT` is set) on aws                           |
| flux                       | flux managing flux: the operator + FluxInstance HelmReleases adopt terraform's bootstrap releases and follow the newest mirrored charts; distribution manifests come embedded in the operator image (`distribution.artifact` removed by postRenderer)                 |

Every chart component is a `GARArtifactTag` ResourceSetInputProvider (newest in-range chart version in the platform
registry) plus a ResourceSet templating an OCIRepository (**cosign verify**, branching on the signing mode: keyless
`matchOIDCIdentity` against the Fulcio identities, or — when `SIGNED_IDENTITY_KMS_KEY` is set — a `secretRef` to the
per-namespace `cosign-pub` Secret the same template renders from `COSIGN_PUBLIC_KEY`) and a HelmRelease. A
flux-containers publish therefore rolls out on the next reconcile — bounded by each component's semver range,
overridable per cluster via `*_SEMVER` cluster vars.

Components whose image the mirror tracks independently of the chart (dex, external-dns, otel-collector — images that
release faster than their charts, pinned by `.images.track` in flux-containers) carry a **second** `GARArtifactTag`
provider watching the mirrored image repository. Their ResourceSets join both providers with the `Permute` input
strategy (inputs namespaced per provider: `inputs.<name>.tag`, `inputs.<name>_image.tag`) and feed the image pick into
the HelmRelease `image.tag`, so a tracked image bump published by the mirror rolls out with no chart release — bounded
by `*_IMAGE_SEMVER` cluster vars, which should mirror the track rule's release train.

On top of the always-on core above sits an **optional tier — `dex`, `flux-web`, `patchy` — elected by short name** via
the `STACK_COMPONENTS` cluster var (comma-separated; unset elects everything, so the default cluster is unchanged; the
terraform module includes `dex` exactly when its `sso` toggle is on). The `optional` Kustomization templates the tier's
Flux Kustomizations from the election (`components/optional`), and the same var reaches inside components for the
cross-wiring: dex only registers and syncs OAuth2 client secrets for **elected** relying parties, `flux-web` deploys
only when dex is also elected (it is nothing but the flux UI's SSO wiring — without it the operator's web UI stays
reachable via port-forward), and on a dex-less cluster patchy's status page drops to its rollups-only posture with no
human-facing HTTPRoute (port-forward to reach; the webhook edge is unaffected — machines authenticate by HMAC, not SSO).

### Secret sync (`CLOUD`)

Every credential Secret the optional tier consumes is materialised by a `SecretProviderClass`/`SecretSync` pair, and the
`CLOUD` cluster var selects the dialect both render in — the mapping (source path → Secret key), the consuming
`*-secrets` ServiceAccounts, and the Secret names the charts hardcode are identical on both clouds:

- **`google`** (the default): GKE Integrated Secret Synchronization, enabled by the gke module's `secret_sync` toggle —
  `provider: gke`, GCP Secret Manager `resourceName`s under `GCP_PROJECT`, `SecretSync` from `secret-sync.gke.io/v1`.
  The `*-secrets` KSAs hold direct Workload Identity `secretAccessor` grants made beside the secret containers.
- **`aws`**: the Secrets Store CSI driver + AWS provider arrive as the `aws-secrets-store-csi-driver-provider` EKS
  add-on (terraform, `terraform-aws-eks-flux`), and the missing piece — the upstream
  [secrets-store-sync-controller](https://github.com/kubernetes-sigs/secrets-store-sync-controller), which materialises
  Secrets **without** a pod mounting a CSI volume — deploys as this stack's `secret-sync` component, emitted by the
  `optional` election only on `CLOUD=aws` and only when a secret-consuming component is elected (dex, flux-web and
  patchy's Kustomizations then depend on it, so the `secret-sync.x-k8s.io/v1alpha1` CRD exists before any `SecretSync`
  is applied). Syncs render `provider: aws` with `usePodIdentity: "true"` and Secrets Manager `objectName`s
  (`${SECRET_PREFIX}<name>` in `AWS_REGION`): the controller requests each `SecretSync`'s KSA token with the
  `pods.eks.amazonaws.com` audience, so the reader identity is the consumer KSA's **Pod Identity association** (the
  reader roles the cluster module creates), never the controller's own. The mirrored chart is expected at
  `charts/secrets-store-sync-controller` in the platform registry (`SECRET_SYNC_SEMVER` overrides its range).

## The terraform ↔ flux contract (cluster-vars)

Published by `terraform-google-gke-flux` into the `cluster-vars` ConfigMap (flux-system) and substituted into every
Kustomization (`${VAR}`, `${VAR:=default}`); optional surfaces use the empty-string convention.

| key                            | example                                                | consumed by                                                                                                                                                            |
| ------------------------------ | ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CLUSTER_NAME`                 | `patchy-x`                                             | external-dns (txtOwnerId)                                                                                                                                              |
| `CLOUD`                        | default `google` (`aws`)                               | secret syncs + optional tier — selects the secret-sync dialect (see below)                                                                                             |
| `GCP_PROJECT`                  | `x-patchy-app-ab12`                                    | external-dns, issuers, google secret syncs                                                                                                                             |
| `AWS_REGION`                   | `eu-west-2` (aws clusters only)                        | every aws SecretProviderClass — the Secrets Manager region                                                                                                             |
| `GCP_PROJECT_NUMBER`           | `123456789012`                                         | (published for component use)                                                                                                                                          |
| `GCP_REGION`                   | `us-central1`                                          | (published for component use)                                                                                                                                          |
| `PLATFORM_REGISTRY`            | `us-central1-docker.pkg.dev/…/platform`                | every RSIP + OCIRepository                                                                                                                                             |
| `CONTAINER_REGISTRY`           | same                                                   | every HelmRelease image value (`images/<upstream-path>`)                                                                                                               |
| `OCI_PROVIDER`                 | default `gcp`                                          | OCIRepository registry auth                                                                                                                                            |
| `ARTIFACT_TAG_PROVIDER`        | default `GARArtifactTag` (`ECRArtifactTag`)            | every platform-registry RSIP — the tag-listing type, flux-operator's RSIP dialect of `OCI_PROVIDER`                                                                    |
| `SIGNED_IDENTITY_ISSUER`       | `^https://token\.actions\.githubusercontent\.com$`     | verify blocks + kyverno policy (empty in KMS mode)                                                                                                                     |
| `SIGNED_IDENTITY_CHARTS`       | flux-containers publish@main regexp                    | chart OCIRepository verify (empty in KMS mode)                                                                                                                         |
| `SIGNED_IDENTITY_IMAGES`       | flux-containers publish@main regexp                    | kyverno policy (empty in KMS mode)                                                                                                                                     |
| `SIGNED_IDENTITY_MANIFESTS`    | flux-manifests publish regexp (per channel)            | flux — sync OCIRepository verify patch (empty in KMS mode)                                                                                                             |
| `SIGNED_IDENTITY_KMS_KEY`      | KMS key ARN / resource name (empty when keyless)       | selects KMS signing mode: chart verify flips to the `cosign-pub` secretRef, the kyverno platform rule to a `keys.kms` attestor (`awskms:///` / `gcpkms://` by `CLOUD`) |
| `COSIGN_PUBLIC_KEY`            | base64 PEM of the signing key's public half            | KMS mode only — rendered into each component namespace's `cosign-pub` Secret for the chart verifies                                                                    |
| `FLUX_SYNC_CHANNEL`            | `edge` / `stable` (default `stable`)                   | flux — FluxInstance sync ref (release channel)                                                                                                                         |
| `DNS_ZONE_NAME`                | `patchy-bitwisemedia-co-uk`                            | external-dns zone filter                                                                                                                                               |
| `DNS_DOMAIN`                   | `patchy.bitwisemedia.co.uk`                            | external-dns domain filter                                                                                                                                             |
| `PATCHY_DOMAIN`                | `patchy.bitwisemedia.co.uk`                            | gateway listener + certificate                                                                                                                                         |
| `ACME_EMAIL`                   | `you@bitwisemedia.co.uk`                               | issuers                                                                                                                                                                |
| `GATEWAY_ADDRESS_NAME`         | `patchy-x-gateway`                                     | gateway (NamedAddress)                                                                                                                                                 |
| `GATEWAY_IP`                   | `203.0.113.10`                                         | (informational)                                                                                                                                                        |
| `OTEL_PROJECT`                 | `x-patchy-app-ab12`                                    | otel-collector exporters                                                                                                                                               |
| `SECRET_PREFIX`                | `patchy-x-` (empty for unprefixed containers)          | distinct per-cluster secret names — every GCP resourceName / AWS objectName                                                                                            |
| `STACK_COMPONENTS`             | `dex,patchy` (unset elects everything)                 | optional-tier election — see below                                                                                                                                     |
| `DEX_CONNECTORS`               | JSON array (typed `sso.connectors`; `[]` when sso off) | dex — arbitrary SSO federation, one entry per upstream connector (see below)                                                                                           |
| `DEX_DIRECTORY_SA`             | `dex-directory@….iam.gserviceaccount.com`              | dex KSA annotation (typed `sso.directory_sa`; empty when sso off or unset)                                                                                             |
| `RBAC_GROUP_VIEWERS`           | `gcp-x-patchy-viewers@bitwisemedia.co.uk`              | rbac — cluster-wide `view` + patchy findings read                                                                                                                      |
| `RBAC_GROUP_DEVELOPERS`        | `gcp-x-patchy-developers@bitwisemedia.co.uk`           | rbac — `patchy-findings-operator` in the patchy namespace                                                                                                              |
| `RBAC_GROUP_DEVOPS`            | `gcp-x-patchy-devops@bitwisemedia.co.uk`               | rbac — cluster-wide `edit`                                                                                                                                             |
| `RBAC_GROUP_ADMINS`            | `gcp-x-patchy-admins@bitwisemedia.co.uk`               | rbac — cluster-wide `cluster-admin` + `patchy-findings-admin` (demo tooling)                                                                                           |
| `KYVERNO_FAILURE_ACTION`       | default `Audit`                                        | kyverno policy — flip to `Enforce` after soaking a fresh cluster                                                                                                       |
| `AGENT_HARNESSES`              | default `claude` (of `claude,codex,copilot`)           | patchy — agent runner election; also gates each harness's credential sync                                                                                              |
| `AGENT_EGRESS_POLICY`          | default `auto` (`none`/`cilium`/`gke`/`istio`)         | patchy — agent sandbox hostname-egress dialect; `auto` detects it per cluster                                                                                          |
| `AGENT_EGRESS_BROAD`           | default `auto` (`always` to soak)                      | patchy — keep the base "443 to anywhere" rule while a newly enabled dialect soaks                                                                                      |
| `CLAUDE_PROVIDER`              | default `anthropic` (`bedrock`/`vertex`)               | patchy — model API the egress broker fronts; gates the anthropic sync + broker egress                                                                                  |
| `CLAUDE_ANTHROPIC_AUTH`        | default `token` (`key` for a real API key)             | patchy — how the broker sends the anthropic credential (bearer vs `x-api-key`)                                                                                         |
| `CLAUDE_BEDROCK_REGION`        | `us-east-1` (empty unless bedrock)                     | patchy — broker Bedrock region                                                                                                                                         |
| `CLAUDE_BEDROCK_REGION_PREFIX` | `us`/`eu`/`apac` (empty for none)                      | patchy — Bedrock cross-region inference-profile geo prefix                                                                                                             |
| `CLAUDE_VERTEX_REGION`         | `us-east5`/`global` (empty unless vertex)              | patchy — broker Vertex region                                                                                                                                          |
| `CLAUDE_VERTEX_PROJECT_ID`     | `x-patchy-app-ab12` (empty unless vertex)              | patchy — broker Vertex project                                                                                                                                         |
| `CLAUDE_MODEL_MAP`             | `canonical=providerID,…` (empty derives ids)           | patchy — per-provider model-id overrides, comma-joined `k=v` pairs                                                                                                     |
| `SCC_AUDIENCE`                 | `https://integrations.patchy…/google-cloud/webhooks`   | patchy — google-cloud Integration audience, verbatim from terraform                                                                                                    |
| `SCC_PUSH_SA`                  | `patchy-scc-push@….iam.gserviceaccount.com`            | patchy — the only push identity accepted; **empty omits the Integration entirely**                                                                                     |
| `SCC_ORGANIZATION`             | `123456789012`                                         | patchy — numeric org id, for Console links on findings with no `externalUri`                                                                                           |
| `SCC_ASSET_SCOPE`              | `organizations/123456789012`                           | patchy — context-controller asset search scope; empty disables repository resolution                                                                                   |
| `SCC_ASSET_SA`                 | `patchy-assets@….iam.gserviceaccount.com`              | patchy — context-controller KSA annotation; the SA holding the org asset grant                                                                                         |
| `PATCHY_FALLBACK_REPOSITORY`   | `bitwisemedia/security` (empty for none)               | patchy — tracking issues for findings that resolve no repository of their own                                                                                          |
| `PATCHY_EVALUATION`            | default `false`                                        | patchy — evaluation controller + `evals.` edge; dex — evolve public client; rbac — submitter binding                                                                   |
| `*_SEMVER`                     | `>=3.8.0 <4.0.0`                                       | per-component chart range overrides                                                                                                                                    |

The `SCC_*` keys are the exception to the first sentence: the SCC pipeline is built by the `patchy` root, not by the
cluster module, so they arrive as caller extras through `flux.cluster_vars` rather than as reserved keys. `SCC_PUSH_SA`
alone gates the `google-cloud` Integration — a cluster whose terraform built the pipeline has all of them, one that did
not has none — because `audience` and `serviceAccount` are required with `minLength: 1` in both the chart's values
schema and the CRD, so there is no such thing as a rendered-but-disabled block.

The `CLAUDE_*` keys configure the claude runner's **egress credential broker** (chart ≥ 0.10.0): all claude model
traffic terminates at the broker in the patchy namespace, which authenticates provider-side — the anthropic credential
when `CLAUDE_PROVIDER=anthropic`, ambient cloud identity (the `patchy-egress-broker` KSA, granted by the cluster module)
for `bedrock`/`vertex`. They are harness-scoped on purpose: the model provider is a per-harness choice, and a future
codex/copilot surface would arrive as `CODEX_*` siblings rather than a rename. **Migration note:** at the 0.10.0 floor
the anthropic credential Secret moves from `patchy-agents` to `patchy` — flux prunes the old SecretSync and creates the
new one automatically, but the `roles/secretmanager.secretAccessor` grant on `patchy-anthropic-token` in the
cloud-accounts patchy root must cover the **patchy**-namespace `patchy-secrets` KSA or the broker's readiness probe
holds forever waiting for the credential.

`SCC_ASSET_SCOPE` and `SCC_ASSET_SA` are a pair and must move with the IAM grant behind them: the scope is the whole
organization, matching the org-scoped notification config, and an asset search wider than its caller's grant fails
rather than returning fewer results. The grant is org-level `roles/cloudasset.viewer` on an SA the cloud-accounts
**common** root owns — the only tier that can write org IAM — which the context-controller KSA impersonates via the
annotation. Widening or narrowing the scope without moving that grant breaks repository resolution for cloud findings.

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
kustomize-controller postBuild does, renders each ResourceSet with `tests/inputs/` fixtures via the flux-operator CLI (a
`<file>.<variant>.yaml` sibling fixture — e.g. `resourceset-secrets.aws.yaml` — re-renders the same ResourceSet with a
different input set, so both sides of a `CLOUD` or election branch are validated), renders every ResourceSet a second
time under `tests/cluster-vars-keyed.env` (the KMS signing convention — key set, keyless identities empty — exercising
the `${VAR}`-driven keyed branches a fixture variant can't reach), and kubeconforms everything against flux + vendored
CRD schemas (`tests/schemas/`, regenerated from upstream CRDs — see scripts/validate.sh).

## Caveats

- **Bootstrap order**: the platform registry must hold every chart + image (flux-containers) before a cluster can
  reconcile this stack, and the first cluster apply needs a published (staging or stable) artifact.
- **Kyverno starts in Audit**: the policy's failureAction defaults to Audit — review PolicyReports on a fresh cluster,
  then set `KYVERNO_FAILURE_ACTION=Enforce` via terraform's `flux.cluster_vars`.
- **Patchy's agent egress dialect is detected, not configured**: `agent.networkPolicy.mode` is left at `auto`, so the
  chart reads the cluster's own API surface on every helm-controller reconcile and renders `FQDNNetworkPolicy` on a
  Dataplane V2 cluster that has FQDN policy enabled, `CiliumNetworkPolicy` on a real Cilium, and the base NetworkPolicy
  alone otherwise. Do **not** set `cilium` on GKE: Dataplane V2 publishes the cilium.io CRDs but has not honoured
  `CiliumNetworkPolicy` since 1.21.5-gke.1300 and rejects every L7 rule, so the policy would enforce nothing while
  reading as protection. GKE's FQDN policy is **Preview**, needs the cluster created or updated with
  `--enable-fqdn-network-policy` (terraform, not here), and resolves at most 50 addresses per name — until that flag is
  on, detection correctly finds nothing and the sandbox rests on credential absence plus the base policy.
- **Gateway `NamedAddress`**: verify the accepted `spec.addresses.type` on the cluster's GKE version at first apply
  (`networking.gke.io` annotations are the fallback).
