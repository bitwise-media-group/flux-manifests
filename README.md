# flux-manifests

The GitOps stack every patchy-platform cluster syncs, packaged as a **keyless-cosign-signed OCI artifact** in the
platform registry and consumed by each cluster's FluxInstance on a channel tag (`edge`, `staging` or `stable`). The
artifact ships the whole repository; **each cluster syncs its own cloud's tree** — terraform points `flux.sync.path` at
`aws` or `google` — and nothing is edited per cluster: all remaining variation arrives through the `cluster-vars`
ConfigMap the cluster module publishes.

## Layout: two trees and a common tier

```text
common/components/…   cloud-neutral components, served to BOTH clusters verbatim
aws/                  the EKS tree: entrypoint kustomization + aws-only components
google/               the GKE tree: entrypoint kustomization + google-only components
```

Each tree root is the FluxInstance entrypoint (`sync.path: aws|google`) listing the same nine Flux Kustomizations by the
same names; a child's `spec.path` resolves against the artifact root, so a tree freely mixes `./common/components/<x>`
and `./<tree>/components/<x>`. What used to be one shared tree branching on a `CLOUD` var is now forked where the clouds
genuinely differ and shared where they do not:

- **`common/` may only reference both-cloud vars.** A var published by a single cloud's module may appear in `common/`
  **only** behind a `:=` default (and then only for per-cluster _elections_ — SCC on/off, a directory SA, a model
  provider — never for cloud identity). `make test` enforces this mechanically: a bare single-cloud `${VAR}` in
  `common/` fails the neutrality guard, and any `inputs.cloud` / `${CLOUD…}` reference fails outright.
- **Per-cloud trees carry no cross-cloud defaults.** Inside `aws/` or `google/`, a `:=` default over a var that tree's
  own module always publishes is dead code left over from the shared-tree era (it only existed to survive the other
  cloud's strict substitution) and fails the dead-default guard.
- **The optional tier is a pair per component.** Each elected component (dex, flux-web, patchy) is a cloud-neutral
  _core_ in `common/` plus a per-tree _companion_ — `dex-cloud`, `flux-web-cloud`, `patchy-cloud` — carrying that
  cloud's secret-sync dialect (and, on google, the GKE Gateway `HealthCheckPolicy` set). The core's Kustomization
  depends on its companion, so namespaces and credentials exist before the release reconciles.

### The empty-var convention

Flux's post-build substitution round-trips each manifest through YAML (parse → serialize → envsubst → reparse), and the
serialize step drops redundant quotes — so `key: "${VAR}"` in **structured** YAML (a ResourceSet's `spec.resources` or
`spec.inputs`, or any plain manifest) becomes `key: null` when the var is empty, and helm schemas / CRDs reject the key.
Therefore: a var that can legally be empty on its own tree must never appear as a bare quoted scalar. In order of
preference:

1. **Key absent when empty** — a conditional flow mapping or template gate — when the consumer treats empty as "off"
   (`extra:` / `annotations:` in `common/components/patchy/resourceset.yaml`).
2. **`<< "${VAR:=}" | quote >>`** — when the field must exist as a string under a strict chart schema (`region:` /
   `regionPrefix:` there).
3. Move the value into a `resourcesTemplate: |` block scalar, where quotes are literal text and survive.

`make test` substitutes exactly as the controller does and fails any `${VAR}`-bearing scalar that becomes null (the null
guard self-tests at startup, so it cannot rot).

## What the stack deploys

```text
kyverno ──► kyverno-policies ──┬──► cert-manager ──► cert-manager-issuers ──► gateway
    (policy engine)   (gate)   ├──► external-dns
                               └──► flux
```

| component            | tree     | role                                                                                                                                                                                                                                                                                                                                                           |
| -------------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| kyverno              | common   | admission enforcement engine                                                                                                                                                                                                                                                                                                                                   |
| kyverno-policies     | per-tree | every pod image must carry a cosign signature from the platform pipeline — keyless identity or, in KMS mode, the signing key in that cloud's URI scheme; cloud system registries excluded                                                                                                                                                                      |
| cert-manager         | common   | Let's Encrypt via DNS-01 with ambient credentials; Gateway API integration on                                                                                                                                                                                                                                                                                  |
| cert-manager-issuers | per-tree | the ClusterIssuers' DNS-01 solver — Route53 on aws, Cloud DNS on google (plain manifests; the solver shape was the only branch)                                                                                                                                                                                                                                |
| external-dns         | per-tree | publishes Gateway HTTPRoute hosts into the delegated zone (per-cluster ownership, pruning sync); provider block per cloud                                                                                                                                                                                                                                      |
| gateway              | per-tree | the shared platform Gateway on terraform-reserved addresses + the platform hostnames' certificate — a GKE global external ALB (`NamedAddress`) on google, a Cilium Gateway whose Service the AWS Load Balancer Controller binds to the reserved EIPs as an NLB on aws (where the tree also installs the Gateway API standard-channel CRDs, `GATEWAY_API_CRDS`) |
| rbac                 | common   | group → RBAC bindings from `RBAC_GROUP_*`                                                                                                                                                                                                                                                                                                                      |
| flux                 | per-tree | flux managing flux: the operator + FluxInstance HelmReleases adopt terraform's bootstrap releases and follow the newest mirrored charts; carries the tree's fixed `cluster.type` and `sync.path` literals — the fixed point that keeps a running cluster on its own tree                                                                                       |
| cilium               | aws only | cilium managing cilium: same name-matched adoption of terraform's bootstrap-only `helm_release.cilium` (`lifecycle.ignore_changes = all`); its wrapping Kustomization depends on `gateway-api-crds` so the handoff's first reconcile lands after the Gateway API CRDs establish — see the Gateway API CRDs caveat below                                        |
| optional             | per-tree | elects and emits the optional tier (cores + companions; plus `secret-sync` on aws)                                                                                                                                                                                                                                                                             |

Every chart component is a tag-listing ResourceSetInputProvider (newest in-range chart version in the platform registry;
`GARArtifactTag` on google, `ECRArtifactTag` on aws) plus a ResourceSet templating an OCIRepository (**cosign verify**,
branching on the signing mode: keyless `matchOIDCIdentity` against the Fulcio identities, or — when
`SIGNED_IDENTITY_KMS_KEY` is set — a `secretRef` to the per-namespace `cosign-pub` Secret the same template renders from
`COSIGN_PUBLIC_KEY`) and a HelmRelease. A flux-containers publish therefore rolls out on the next reconcile — bounded by
each component's semver range, overridable per cluster via `*_SEMVER` cluster vars.

Components whose image the mirror tracks independently of the chart (dex, external-dns — images that release faster than
their charts, pinned by `.images.track` in flux-containers) carry a **second** tag provider watching the mirrored image
repository. Their ResourceSets join both providers with the `Permute` input strategy (inputs namespaced per provider:
`inputs.<name>.tag`, `inputs.<name>_image.tag`) and feed the image pick into the HelmRelease `image.tag`, so a tracked
image bump published by the mirror rolls out with no chart release — bounded by `*_IMAGE_SEMVER` cluster vars, which
should mirror the track rule's release train.

On top of the always-on core above sits an **optional tier — `dex`, `flux-web`, `patchy` — elected by short name** via
the `STACK_COMPONENTS` cluster var (comma-separated; unset elects everything, so the default cluster is unchanged; the
terraform module includes `dex` exactly when its `sso` toggle is on). Each tree's `optional` Kustomization templates the
tier's Flux Kustomizations from the election — the `common/` core and its `<name>-cloud` companion per component — and
the same var reaches inside components for the cross-wiring: dex only registers and syncs OAuth2 client secrets for
**elected** relying parties, `flux-web` deploys only when dex is also elected (it is nothing but the flux UI's SSO
wiring — without it the operator's web UI stays reachable via port-forward), and on a dex-less cluster patchy's status
page drops to its rollups-only posture with no human-facing HTTPRoute (port-forward to reach; the webhook edge is
unaffected — machines authenticate by HMAC, not SSO).

### Secret sync (the `*-cloud` companions)

Every credential Secret the optional tier consumes is materialised by a `SecretProviderClass`/`SecretSync` pair in the
per-tree `<name>-cloud` companion — the mapping (source path → Secret key), the consuming `*-secrets` ServiceAccounts,
and the Secret names the charts hardcode are identical on both clouds; only the dialect differs:

- **`google/`**: GKE Integrated Secret Synchronization, enabled by the gke module's `secret_sync` toggle —
  `provider: gke`, GCP Secret Manager `resourceName`s under `GCP_PROJECT`, `SecretSync` from `secret-sync.gke.io/v1`.
  The `*-secrets` KSAs hold direct Workload Identity `secretAccessor` grants made beside the secret containers.
- **`aws/`**: the Secrets Store CSI driver + AWS provider arrive as the `aws-secrets-store-csi-driver-provider` EKS
  add-on (terraform, `terraform-aws-eks-flux`), and the missing piece — the upstream
  [secrets-store-sync-controller](https://github.com/kubernetes-sigs/secrets-store-sync-controller), which materialises
  Secrets **without** a pod mounting a CSI volume — deploys as the aws tree's `secret-sync` component, emitted by the
  `optional` election when a secret-consuming component is elected (the companions then depend on it, so the
  `secret-sync.x-k8s.io/v1alpha1` CRD exists before any `SecretSync` is applied). Syncs render `provider: aws` with
  `usePodIdentity: "false"` and Secrets Manager `objectName`s (`${SECRET_PREFIX}<name>` in `AWS_REGION`): the controller
  requests each `SecretSync`'s KSA token with the `sts.amazonaws.com` audience, so the reader identity is the consumer
  KSA's **IRSA role** (each sync KSA's `eks.amazonaws.com/role-arn` annotation, `${SECRETS_ROLE_PREFIX}<ns>-<sa>`, names
  the reader role the cluster module creates), never the controller's own. IRSA rather than EKS Pod Identity because the
  syncs are podless: a TokenRequest token with no pod behind it lacks the `kubernetes.io/pod` claim Pod Identity's
  `AssumeRoleForPodIdentity` demands. The mirrored chart is expected at `charts/secrets-store-sync-controller` in the
  platform registry (`SECRET_SYNC_SEMVER` overrides its range).

## The terraform ↔ flux contract (cluster-vars)

Published by the cluster module (`terraform-google-gke-flux` / `terraform-aws-eks-flux`) into the `cluster-vars`
ConfigMap (flux-system) and substituted into every Kustomization (`${VAR}`, `${VAR:=default}`); optional surfaces use
the empty-string convention. `tests/{google,aws}.env` (+ `.keyed` overlays) are the machine-readable copies of these
tables — the harness's guards compare the manifests against them.

### Published by both modules

| key                         | example                                                | consumed by                                                                                                                                                                                        |
| --------------------------- | ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CLUSTER_NAME`              | `patchy-x`                                             | external-dns (txtOwnerId)                                                                                                                                                                          |
| `PLATFORM_REGISTRY`         | `us-central1-docker.pkg.dev/…/platform`                | every RSIP + OCIRepository                                                                                                                                                                         |
| `CONTAINER_REGISTRY`        | same                                                   | every HelmRelease image value (`images/<upstream-path>`)                                                                                                                                           |
| `SIGNED_IDENTITY_ISSUER`    | `^https://token\.actions\.githubusercontent\.com$`     | verify blocks + kyverno policy (empty in KMS mode)                                                                                                                                                 |
| `SIGNED_IDENTITY_CHARTS`    | flux-containers publish@main regexp                    | chart OCIRepository verify (empty in KMS mode)                                                                                                                                                     |
| `SIGNED_IDENTITY_IMAGES`    | flux-containers publish@main regexp                    | kyverno policy (empty in KMS mode)                                                                                                                                                                 |
| `SIGNED_IDENTITY_MANIFESTS` | flux-manifests publish regexp (per channel)            | flux — sync OCIRepository verify patch (empty in KMS mode)                                                                                                                                         |
| `SIGNED_IDENTITY_KMS_KEY`   | KMS key ARN / resource name (empty when keyless)       | selects KMS signing mode: chart verify flips to the `cosign-pub` secretRef, the kyverno platform rule to a `keys.kms` attestor (`awskms:///` on aws, `gcpkms://` on google — baked into each tree) |
| `COSIGN_PUBLIC_KEY`         | base64 PEM of the signing key's public half            | KMS mode only — rendered into each component namespace's `cosign-pub` Secret for the chart verifies                                                                                                |
| `FLUX_SYNC_CHANNEL`         | `edge` / `stable` (default `stable`)                   | flux — FluxInstance sync ref (release channel)                                                                                                                                                     |
| `DNS_ZONE_NAME`             | `patchy-bitwisemedia-co-uk`                            | external-dns zone filter (google; informational on aws — `DNS_ZONE_ID` filters there)                                                                                                              |
| `DNS_DOMAIN`                | `patchy.bitwisemedia.co.uk`                            | external-dns domain filter                                                                                                                                                                         |
| `PATCHY_DOMAIN`             | `patchy.bitwisemedia.co.uk`                            | gateway listeners + certificate, every HTTPRoute host                                                                                                                                              |
| `ACME_EMAIL`                | `you@bitwisemedia.co.uk`                               | issuers                                                                                                                                                                                            |
| `GATEWAY_IP`                | `203.0.113.10`                                         | (informational)                                                                                                                                                                                    |
| `SECRET_PREFIX`             | `patchy-x-` (empty for unprefixed containers)          | distinct per-cluster secret names — every GCP resourceName / AWS objectName                                                                                                                        |
| `STACK_COMPONENTS`          | `dex,patchy` (unset elects everything)                 | optional-tier election                                                                                                                                                                             |
| `DEX_CONNECTORS`            | JSON array (typed `sso.connectors`; `[]` when sso off) | dex — arbitrary SSO federation, one entry per upstream connector                                                                                                                                   |
| `RBAC_GROUP_VIEWERS`        | `gcp-x-patchy-viewers@bitwisemedia.co.uk`              | rbac — cluster-wide `view` + patchy findings read                                                                                                                                                  |
| `RBAC_GROUP_DEVELOPERS`     | `gcp-x-patchy-developers@bitwisemedia.co.uk`           | rbac — `patchy-findings-operator` in the patchy namespace                                                                                                                                          |
| `RBAC_GROUP_DEVOPS`         | `gcp-x-patchy-devops@bitwisemedia.co.uk`               | rbac — cluster-wide `edit`                                                                                                                                                                         |
| `RBAC_GROUP_ADMINS`         | `gcp-x-patchy-admins@bitwisemedia.co.uk`               | rbac — cluster-wide `cluster-admin` + `patchy-findings-admin` (demo tooling)                                                                                                                       |
| `KYVERNO_FAILURE_ACTION`    | default `Audit`                                        | kyverno policy — flip to `Enforce` after soaking a fresh cluster                                                                                                                                   |
| `AGENT_HARNESSES`           | default `claude` (of `claude,codex,copilot`)           | patchy — agent runner election; also gates each harness's credential sync                                                                                                                          |
| `AGENT_EGRESS_POLICY`       | default `auto` (`none`/`cilium`/`gke`/`istio`)         | patchy — agent sandbox hostname-egress dialect; `auto` detects it per cluster                                                                                                                      |
| `AGENT_EGRESS_BROAD`        | default `auto` (`always` to soak)                      | patchy — keep the base "443 to anywhere" rule while a newly enabled dialect soaks                                                                                                                  |
| `CLAUDE_PROVIDER`           | default `anthropic` (`bedrock`/`vertex`)               | patchy — model API the egress broker fronts; gates the anthropic sync + broker egress                                                                                                              |
| `CLAUDE_ANTHROPIC_AUTH`     | default `token` (`key` for a real API key)             | patchy — how the broker sends the anthropic credential (bearer vs `x-api-key`)                                                                                                                     |
| `CLAUDE_MODEL_MAP`          | `canonical=providerID,…` (empty derives ids)           | patchy — per-provider model-id overrides, comma-joined `k=v` pairs                                                                                                                                 |
| `PATCHY_EVALUATION`         | default `false`                                        | patchy — evaluation controller + `evals.` edge; dex — evolve public client; rbac — submitter binding                                                                                               |
| `*_SEMVER`                  | `>=3.8.0 <4.0.0`                                       | per-component chart range overrides                                                                                                                                                                |

### google only (`terraform-google-gke-flux`)

| key                        | example                                   | consumed by                                                                |
| -------------------------- | ----------------------------------------- | -------------------------------------------------------------------------- |
| `GCP_PROJECT`              | `x-patchy-app-ab12`                       | external-dns, issuers, every gke secret sync                               |
| `GCP_PROJECT_NUMBER`       | `123456789012`                            | (published for component use)                                              |
| `GCP_REGION`               | `us-central1`                             | (published for component use)                                              |
| `GATEWAY_ADDRESS_NAME`     | `patchy-x-gateway`                        | gateway (`NamedAddress`)                                                   |
| `DEX_DIRECTORY_SA`         | `dex-directory@….iam.gserviceaccount.com` | dex KSA annotation (typed `sso.directory_sa`; empty when sso off or unset) |
| `CLAUDE_VERTEX_REGION`     | `us-east5`/`global` (empty unless vertex) | patchy — broker Vertex region                                              |
| `CLAUDE_VERTEX_PROJECT_ID` | `x-patchy-app-ab12` (empty unless vertex) | patchy — broker Vertex project                                             |

Plus the **caller extras** of the google patchy-app root (never reserved keys — they arrive through `flux.cluster_vars`,
and only `common/` references them, always behind `:=` defaults):

| key                          | example                                              | consumed by                                                                                 |
| ---------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `SCC_AUDIENCE`               | `https://integrations.patchy…/google-cloud/webhooks` | patchy — google-cloud Integration audience, verbatim from terraform                         |
| `SCC_PUSH_SA`                | `patchy-scc-push@….iam.gserviceaccount.com`          | patchy — the only push identity accepted; **empty omits the Integration entirely**          |
| `SCC_ORGANIZATION`           | `123456789012`                                       | patchy — numeric org id, for Console links on findings with no `externalUri`                |
| `SCC_ASSET_SCOPE`            | `organizations/123456789012`                         | patchy — context-controller asset search scope; empty/absent disables repository resolution |
| `SCC_ASSET_SA`               | `patchy-assets@….iam.gserviceaccount.com`            | patchy — context-controller KSA annotation; the SA holding the org asset grant              |
| `PATCHY_FALLBACK_REPOSITORY` | `bitwisemedia/security` (empty for none)             | patchy — tracking issues for findings that resolve no repository of their own               |

### aws only (`terraform-aws-eks-flux`)

| key                                                                      | example                                   | consumed by                                                                                                                          |
| ------------------------------------------------------------------------ | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `AWS_ACCOUNT_ID`                                                         | `123456789012`                            | (published for component use)                                                                                                        |
| `AWS_REGION`                                                             | `eu-west-2`                               | every aws SecretProviderClass (Secrets Manager region), external-dns SDK region, issuers                                             |
| `AWS_PARTITION`                                                          | `aws`                                     | (published for component use)                                                                                                        |
| `SECRETS_ROLE_PREFIX`                                                    | `arn:aws:iam::…:role/x-secrets-`          | every sync KSA's `eks.amazonaws.com/role-arn` annotation (`${SECRETS_ROLE_PREFIX}<ns>-<sa>` — the IRSA reader roles)                 |
| `OCI_PROVIDER`                                                           | `aws`                                     | OCIRepository registry auth (ECR via Pod Identity); the google tree relies on the manifests' `gcp` default instead                   |
| `ARTIFACT_TAG_PROVIDER`                                                  | `ECRArtifactTag`                          | every platform-registry RSIP in the aws tree; the google tree relies on the `GARArtifactTag` default                                 |
| `DNS_ZONE_ID`                                                            | `Z0123456789ABCDEFGHIJ`                   | external-dns zone filter, issuers (route53 `hostedZoneID`)                                                                           |
| `GATEWAY_EIP_ALLOCATIONS`                                                | `eipalloc-…,eipalloc-…`                   | gateway — NLB Elastic IP allocation ids (Service annotation)                                                                         |
| `GATEWAY_SUBNETS`                                                        | `subnet-…,subnet-…`                       | gateway — the public subnets the NLB spans (Service annotation)                                                                      |
| `GATEWAY_NLB_TARGET_TYPE`                                                | `instance`                                | gateway — NLB target type; instance is all the LB controller supports off the VPC CNI                                                |
| `GATEWAY_API_CRDS`                                                       | `true`                                    | gateway — installs the vendored Gateway API standard channel; flip `false` when EKS ships the CRDs natively (orphaned, never pruned) |
| `CILIUM_K8S_SERVICE_HOST`                                                | `ABCDEF….gr7.eu-west-2.eks.amazonaws.com` | cilium — the EKS API server endpoint hostname (terraform's `cluster_endpoint_host` local), `k8sServiceHost` value                    |
| `CILIUM_POD_SUBNET_IDS`                                                  | `["subnet-…","subnet-…"]`                 | cilium — JSON array, terraform's `pod_subnet_ids` local, `eni.subnetIDsFilter` value                                                 |
| `VPC_ID`, `NODE_SECURITY_GROUP_ID`, `CLUSTER_DISCOVERY_*`, `KARPENTER_*` | —                                         | reserved forward contract for future aws-only components (karpenter et al.)                                                          |
| `CLAUDE_BEDROCK_REGION`                                                  | `us-east-1` (empty unless bedrock)        | patchy — broker Bedrock region                                                                                                       |
| `CLAUDE_BEDROCK_REGION_PREFIX`                                           | `us`/`eu`/`apac` (empty for none)         | patchy — Bedrock cross-region inference-profile geo prefix                                                                           |

`SCC_PUSH_SA` alone gates the `google-cloud` Integration — a cluster whose terraform built the pipeline has all of the
`SCC_*` extras, one that did not has none — because `audience` and `serviceAccount` are required with `minLength: 1` in
both the chart's values schema and the CRD, so there is no such thing as a rendered-but-disabled block.

The `CLAUDE_*` keys configure the claude runner's **egress credential broker** (chart ≥ 0.10.0): all claude model
traffic terminates at the broker in the patchy namespace, which authenticates provider-side — the anthropic credential
when `CLAUDE_PROVIDER=anthropic`, ambient cloud identity (the `patchy-egress-broker` KSA, granted by the cluster module)
for `bedrock`/`vertex`. They are harness-scoped on purpose: the model provider is a per-harness choice, and a future
codex/copilot surface would arrive as `CODEX_*` siblings rather than a rename. Each module publishes only its own
cloud's provider pair (`CLAUDE_BEDROCK_*` on aws, `CLAUDE_VERTEX_*` on google); the patchy core's `:=` defaults carry
the absent side. **Migration note:** at the 0.10.0 floor the anthropic credential Secret moves from `patchy-agents` to
`patchy` — flux prunes the old SecretSync and creates the new one automatically, but the
`roles/secretmanager.secretAccessor` grant on `patchy-anthropic-token` in the cloud-accounts patchy root must cover the
**patchy**-namespace `patchy-secrets` KSA or the broker's readiness probe holds forever waiting for the credential.

`SCC_ASSET_SCOPE` and `SCC_ASSET_SA` are a pair and must move with the IAM grant behind them: the scope is the whole
organization, matching the org-scoped notification config, and an asset search wider than its caller's grant fails
rather than returning fewer results. The grant is org-level `roles/cloudasset.viewer` on an SA the cloud-accounts
**common** root owns — the only tier that can write org IAM — which the context-controller KSA impersonates via the
annotation. Widening or narrowing the scope without moving that grant breaks repository resolution for cloud findings.

Workload identity contract (namespace/serviceaccount names terraform grants against — pinned in the HelmRelease values
here): `external-dns/external-dns`, `cert-manager/cert-manager`, `kyverno/kyverno-{admission,reports}-controller`,
`flux-system/{source-controller,flux-operator}`.

## Releases and channels

release-please cuts `vX.Y.Z` from Conventional Commits; **publish.yaml** pushes the signed artifact and moves `staging`;
**promote.yaml** (workflow_dispatch, `production` environment) moves `stable` after soak. **publish-edge.yaml**
additionally pushes every merge to main as the `edge` channel — for dev/sandbox clusters that validate trunk
continuously; the release channels only ever see release-tagged artifacts. Clusters pin their channel in terraform
(`flux.sync.ref`). The signing identity clusters verify is exactly
`…/flux-manifests/.github/workflows/publish.yaml@refs/tags/v*` for `staging`/`stable`, and
`…/publish-edge.yaml@refs/heads/main` for `edge`.

### Re-pointing a cluster's tree

`flux.sync.path` is applied by terraform at bootstrap, and each tree's own `flux` component re-asserts it (the
FluxInstance is stack-managed and terraform ignores drift after bootstrap). To move a running cluster onto its per-cloud
tree — or to recover one stranded on a path that no longer exists in the artifact — patch the FluxInstance directly; the
stack then holds the value as a fixed point:

```sh
kubectl patch fluxinstance flux -n flux-system --type merge \
  -p '{"spec":{"sync":{"path":"aws"}}}'    # "google" on the GKE cluster
```

## Validation

`make test` renders everything **four times — `{google,aws} × {keyless,keyed}`** — building `common/` plus the tree's
components and the tree root under that cloud's env contract alone (`tests/<tree>.env`, with `tests/<tree>.keyed.env`
overlaid for the KMS-signing passes; the google keyed overlay doubles as the _sparse_ caller, unsetting every optional
extra). Substitution is faithful to kustomize-controller's post-build roundtrip — scalar styles are normalized the way
the controller's serializer would before a **textual** envsubst — so a quoted empty var becomes null locally exactly as
it would on the cluster, and the null guard fails the run naming the file and path (self-tested at startup). Structural
guards keep the split honest: `common/` may not branch on cloud nor bare-reference a single-cloud var, and a per-cloud
tree may not keep a `:=` default whose only purpose was surviving the other cloud. ResourceSets render with
`tests/inputs/{<tree>,common}/` fixtures via the flux-operator CLI (the tree directory shadows `common/` per basename; a
`<file>.<variant>.yaml` sibling re-renders the same ResourceSet with a different input set, so every side of an election
branch is validated), and everything kubeconforms against flux + vendored CRD schemas (`tests/schemas/`, regenerated
from upstream CRDs — see scripts/validate.sh).

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
- **Gateway API CRDs on aws land after Cilium starts**: EKS ships no `gateway.networking.k8s.io` CRDs, so the aws tree
  installs the vendored standard channel (`aws/components/gateway-crds`, emitted while `GATEWAY_API_CRDS` holds). Cilium
  only enables its Gateway API controller when the CRDs are present at agent/operator startup, and on a fresh bootstrap
  terraform's cilium release comes up first. The `cilium` component (`aws/components/cilium`) closes this: its wrapping
  Kustomization (`aws/cilium.yaml`) depends on `gateway-api-crds`, so the first-ever Flux reconcile of the adopted
  `cilium` HelmRelease — the terraform → Flux handoff every cluster goes through once — lands only after the CRDs
  establish. `operator.podAnnotations`/`podAnnotations` also carry a version pin matching the vendored CRDs' `v=`
  (`aws/components/gateway-crds/kustomization.yaml`), bumped in lockstep with them, so a future CRD version bump forces
  a rollout too instead of requiring a manual restart. When AWS eventually ships the CRDs as managed cluster furniture,
  flip the cluster module's `gateway.install_crds` off **and** drop the `dependsOn` in `aws/cilium.yaml` in the same
  change — `gateway-api-crds` stops existing at that point, and a dangling `dependsOn` would freeze `cilium`'s
  reconciliation. The `gateway-api-crds` Kustomization itself is pruned but the CRDs are orphaned (`prune: false`) —
  deleting them would cascade into every Gateway and HTTPRoute.
