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
rather than a branch inside a platform component. See [Applications](#applications).

## Layout

```text
platform/{aws,google}/            the entrypoint: one ResourceSet per cloud    -> oci://<registry>/manifests/platform
components/<name>/common/         the component's cloud-neutral tier
components/<name>/{aws,google}/   the per-cloud overlay (resources: ../common + cloud files)
                                                                             -> oci://<registry>/manifests/<name>
```

Every component ships one overlay per cloud it supports, and the entrypoint's `Kustomization` for it points at `./aws`
or `./google` inside the component's own image. A component with nothing cloud-specific has overlays that are the common
tier verbatim (kyverno, cert-manager, flux, rbac, arc); a component that is one cloud's alone has that overlay only
(cilium, aws-load-balancer-controller, secret-sync on aws); a component whose secret-sync or edge dialect differs per
cloud carries the difference in its overlay (dex, flux-web). What used to be a shared tree branching on a `CLOUD` var,
then three trees, is now a common tier per component and nothing else:

- **`components/*/common` may only reference both-cloud vars.** A var published by a single cloud's module may appear in
  a common tier **only** behind a `:=` default (and then only for per-cluster _elections_, never for cloud identity).
  `make test` enforces this mechanically: a bare single-cloud `${VAR}` in a common tier fails the neutrality guard, and
  any `inputs.cloud` / `${CLOUD...}` reference fails outright.
- **Per-cloud overlays carry no cross-cloud defaults.** Inside an `aws/` or `google/` overlay (or entrypoint), a `:=`
  default over a var that cloud's own module always publishes is dead code left over from the shared-tree era (it only
  existed to survive the other cloud's strict substitution) and fails the dead-default guard.
- **The entrypoint is the graph.** Ordering (`dependsOn`), timeouts, election gates and per-component release pins live
  in `platform/<tree>/resourceset.yaml` and nowhere else; `make test` proves the list complete (every shipped overlay is
  emitted, every `dependsOn` resolves) and the core tier election-independent.

### The empty-var convention

Flux's post-build substitution round-trips each manifest through YAML (parse, serialize, envsubst, reparse), and the
serialize step drops redundant quotes - so `key: "${VAR}"` in **structured** YAML (a ResourceSet's `spec.resources` or
`spec.inputs`, or any plain manifest) becomes `key: null` when the var is empty, and helm schemas / CRDs reject the key.
Therefore: a var that can legally be empty on its own tree must never appear as a bare quoted scalar. In order of
preference:

1. **Key absent when empty** - a conditional flow mapping or template gate - when the consumer treats empty as "off"
   (the `serviceAccount.annotations` flow mapping in `components/dex/common/resourceset.yaml`).
2. **`<< "${VAR:=}" | quote >>`** - when the field must exist as a string under a strict chart schema.
3. Move the value into a `resourcesTemplate: |` block scalar, where quotes are literal text and survive.

`make test` substitutes exactly as the controller does and fails any `${VAR}`-bearing scalar that becomes null (the null
guard self-tests at startup, so it cannot rot).

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

Two tiers. The **core tier** has no election gate and deploys on every cluster; the **electable tier** (`dex`,
`flux-web`, `arc`) deploys only when named in the `PLATFORM_COMPONENTS` cluster var (short names, comma-separated; unset
elects `dex,flux-web`; the reserved name `none`, which terraform publishes for an empty election, matches nothing).
`dex` is not elected by hand: the cluster module includes it exactly when its `sso` toggle is on. `flux-web` deploys
only when `dex` is also elected (it is nothing but the flux UI's SSO wiring and edge). Every component's `Kustomization`
follows the cluster's release channel unless its `<NAME>_MANIFESTS_REF` caller extra pins it to a tag.

| component                    | tier      | clouds | depends on                              | role                                                                                                                                                                                                                                                                                                                                                       |
| ---------------------------- | --------- | ------ | --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| kyverno                      | core      | both   |                                         | admission enforcement engine; `PolicyException`s enabled, homed in the `kyverno` namespace                                                                                                                                                                                                                                                                 |
| kyverno-policies             | core      | both   | kyverno                                 | every pod image must carry a cosign signature from the platform pipeline - keyless identity or, in KMS mode, the signing key in that cloud's URI scheme; cloud system registries excluded; one identity, no application carve-outs                                                                                                                         |
| flux                         | core      | both   | kyverno-policies                        | flux managing flux: the operator + FluxInstance HelmReleases adopt terraform's bootstrap releases and follow the newest mirrored charts; re-asserts `sync.url` (`FLUX_SYNC_URL`) and `sync.path` (`PLATFORM_TREE`) on the FluxInstance, which is how a running cluster is re-pointed                                                                       |
| cilium                       | core      | aws    | gateway-api-crds (while it exists)      | cilium managing cilium: name-matched adoption of terraform's bootstrap-only release; the first reconcile lands after the Gateway API CRDs establish                                                                                                                                                                                                        |
| cert-manager                 | core      | both   | kyverno-policies                        | Let's Encrypt via DNS-01 with ambient credentials; Gateway API integration on                                                                                                                                                                                                                                                                              |
| cert-manager-issuers         | core      | both   | cert-manager                            | the ClusterIssuers' DNS-01 solver - Route53 on aws, Cloud DNS on google                                                                                                                                                                                                                                                                                    |
| aws-load-balancer-controller | core      | aws    | kyverno-policies                        | turns the Cilium Gateway's LoadBalancer Service into the NLB on the terraform-reserved EIPs                                                                                                                                                                                                                                                                |
| external-dns                 | core      | both   | kyverno-policies                        | publishes every HTTPRoute host into the delegated zone (per-cluster ownership, pruning sync); one instance per zone flavour on aws                                                                                                                                                                                                                         |
| gateway                      | core      | both   | cert-manager-issuers                    | the shared platform Gateway on terraform-reserved addresses: **one wildcard `https` listener on `*.${PLATFORM_DOMAIN}`** terminating with the `platform-wildcard` Certificate (`platform-tls`), admitting routes from any namespace labelled `platform.bitwisemedia.uk/gateway-access: "true"`; the aws overlay also carries the vendored Gateway API CRDs |
| rbac                         | core      | both   |                                         | `cluster-admin` / `edit` / `view` bindings on `RBAC_GROUP_ADMINS` / `_DEVOPS` / `_VIEWERS`; nothing narrower (application roles are the application's to bind)                                                                                                                                                                                             |
| secret-sync                  | core      | aws    | kyverno-policies                        | the upstream secrets-store-sync-controller: the `SecretSync` CRD and the podless materialiser EKS does not ship (GKE has it built in). Unconditional: the platform cannot know which applications consume secrets                                                                                                                                          |
| dex                          | electable | both   | kyverno-policies, gateway, secret-sync¹ | the OIDC identity provider: connectors from `DEX_CONNECTORS`, static clients from `DEX_CLIENTS`, its `dex-env` Secret synced from the `dex-<id>-<field>` and `dex-client-<id>` containers                                                                                                                                                                  |
| flux-web                     | electable | both   | gateway, secret-sync¹, dex              | the Flux status UI's SSO wiring: the `flux-web-auth` Web Config sync, the `flux.` HTTPRoute, the edge-admission policy, and the `gateway-access` label on `flux-system`                                                                                                                                                                                    |
| arc                          | electable | both   | kyverno-policies                        | the Actions Runner Controller (controller half only, watching every namespace); runner scale sets are application-level - see [Applications](#applications)                                                                                                                                                                                                |

¹ aws only; the google entrypoint omits the edge.

Every chart component is a tag-listing ResourceSetInputProvider (newest in-range chart version in the platform registry;
`GARArtifactTag` on google, `ECRArtifactTag` on aws) plus a ResourceSet templating an OCIRepository (**cosign verify**,
branching on the signing mode: keyless `matchOIDCIdentity` against the Fulcio identities, or - when
`SIGNED_IDENTITY_KMS_KEY` is set - a `secretRef` to the per-namespace `cosign-pub` Secret the same template renders from
`COSIGN_PUBLIC_KEY`) and a HelmRelease. A flux-containers publish therefore rolls out on the next reconcile - bounded by
each component's semver range, overridable per cluster via `*_SEMVER` cluster vars.

Components whose image the mirror tracks independently of the chart (dex, external-dns - images that release faster than
their charts, pinned by `.images.track` in flux-containers) carry a **second** tag provider watching the mirrored image
repository. Their ResourceSets join both providers with the `Permute` input strategy (inputs namespaced per provider:
`inputs.<name>.tag`, `inputs.<name>_image.tag`) and feed the image pick into the HelmRelease `image.tag`, so a tracked
image bump published by the mirror rolls out with no chart release - bounded by `*_IMAGE_SEMVER` cluster vars, which
should mirror the track rule's release train.

### Secret sync

Every credential Secret the platform consumes (dex's connector fields and client secrets, the Flux status UI's Web
Config document) is materialised by a `SecretProviderClass`/`SecretSync` pair in the component's per-cloud overlay - the
mapping (source path to Secret key), the consuming `*-secrets` ServiceAccounts and the Secret names the charts hardcode
are identical on both clouds; only the dialect differs:

- **google**: GKE Integrated Secret Synchronization, enabled by the gke module's `secret_sync` toggle - `provider: gke`,
  GCP Secret Manager `resourceName`s under `GCP_PROJECT`, `SecretSync` from `secret-sync.gke.io/v1`. The `*-secrets`
  KSAs hold direct Workload Identity `secretAccessor` grants made beside the secret containers.
- **aws**: the Secrets Store CSI driver + AWS provider arrive as the `aws-secrets-store-csi-driver-provider` EKS add-on
  (terraform, `terraform-aws-eks-flux`), and the missing piece - the upstream
  [secrets-store-sync-controller](https://github.com/kubernetes-sigs/secrets-store-sync-controller), which materialises
  Secrets **without** a pod mounting a CSI volume - is the `secret-sync` component every consumer depends on. Syncs
  render `provider: aws` with `usePodIdentity: "false"` and Secrets Manager `objectName`s (`${SECRET_PREFIX}<name>` in
  `AWS_REGION`): the controller requests each `SecretSync`'s KSA token with the `sts.amazonaws.com` audience, so the
  reader identity is the consumer KSA's **IRSA role** (each sync KSA's `eks.amazonaws.com/role-arn` annotation,
  `${SECRETS_ROLE_PREFIX}<ns>-<sa>`, names the reader role the cluster module creates), never the controller's own. IRSA
  rather than EKS Pod Identity because the syncs are podless: a TokenRequest token with no pod behind it lacks the
  `kubernetes.io/pod` claim Pod Identity's `AssumeRoleForPodIdentity` demands.

## Applications

An application is a manifest image of its own (`oci://<registry>/manifests/<app>`, published by the application's repo
through its own path-scoped publisher), **seeded** once by the cluster module and self-owned from its first reconcile.
The platform never names it; what it needs is a set of contracts, all of them consumed from the application's image:

- **The seed.** The cluster module creates, in `flux-system`, a `ResourceSetInputProvider` and a `ResourceSet` both
  named `<app>-manifests`, carrying the label `kustomize.toolkit.fluxcd.io/prune: disabled`. The ResourceSet emits the
  `OCIRepository <app>-manifests` (tag + digest from the provider, cosign verify) and the `Kustomization <app>` (path
  `./deploy/<PLATFORM_TREE>`, `dependsOn` the platform gates it names, `substituteFrom` `cluster-vars` plus the optional
  `<app>-vars` ConfigMap). The image ships **the same two objects** under `flux/`, with the same names, and its
  `deploy/<tree>/kustomization.yaml` includes `../../flux` - so on the first reconcile the application adopts its own
  seed through server-side apply and owns its range, verify identity and graph from then on. The `prune: disabled` label
  must stay on the image's copies too: without it, an image that dropped `flux/` would prune its own parent.
- **Its variables.** Everything application-specific the cluster module used to publish (`AGENT_*`, `CLAUDE_*`,
  `PATCHY_*`, `SCC_*`, ...) now arrives through the application's `<app>-vars` ConfigMap (`application_vars` on the
  cluster module), substituted after `cluster-vars`. A platform manifest reading an application var fails strict
  substitution in `make test`. Applications may read any platform var; `PLATFORM_TREE` tells them which of their own
  overlays the platform selected.
- **A host.** Label the route's namespace `platform.bitwisemedia.uk/gateway-access: "true"` and attach the HTTPRoute to
  `platform` in `gateway` by hostname (`<host>.${PLATFORM_DOMAIN}`, no `sectionName`): the wildcard listener admits it
  and the wildcard certificate covers it. external-dns publishes the record.
- **An identity.** Declare dex clients through the cluster module (`applications[*].dex_clients`); the cluster module
  composes them into `DEX_CLIENTS` beside the platform's own, mints a `dex-client-<id>` Secrets Manager container for
  every confidential client, and the dex component registers the client and syncs its secret. The application syncs the
  same container into its own namespace (`${SECRET_PREFIX}dex-client-<id>`).
- **Its own image signer.** The platform policy verifies every pod image against the platform pipeline's identity, with
  no carve-outs. An application whose images are signed elsewhere ships a `PolicyException` in the `kyverno` namespace
  (scoped to its namespaces and its images) beside its own `ClusterPolicy` verifying that signer - every image is still
  verified by exactly one policy.
- **RBAC.** Bind the application's own roles (a status page's verbs, a findings viewer) as RoleBindings in its
  namespaces against the same `RBAC_GROUP_*` vars; the platform binds only the built-in cluster roles.
- **Secrets.** Ship a `SecretProviderClass`/`SecretSync` pair per credential in the cloud's dialect (above), with the
  sync KSA annotated `${SECRETS_ROLE_PREFIX}<ns>-<sa>` on aws; the cluster module creates the reader role from the
  application's declared `secret_readers`. Depend on `secret-sync` when `${PLATFORM_TREE}` is `aws`.
- **GitHub Actions runners.** With `arc` elected, ship a `gha-runner-scale-set` HelmRelease in the application's
  namespace: its own tag provider over the mirrored chart on the same `ARC_SEMVER` range (the two charts release in
  lockstep and a scale set cannot run against a different controller version), `controllerServiceAccount`
  `{namespace: arc-systems, name: arc-gha-rs-controller}`, and `dependsOn: [arc, secret-sync]` for the GitHub App
  credential sync.

Removing the application's key from the cluster module uninstalls the seed; the ResourceSet finalizer garbage-collects
the Kustomization, whose finalizer prunes the application.

## The terraform to flux contract (cluster-vars)

Published by the cluster module (`terraform-google-gke-flux` / `terraform-aws-eks-flux`) into the `cluster-vars`
ConfigMap (flux-system) and substituted into every Kustomization (`${VAR}`, `${VAR:=default}`); optional surfaces use
the empty-string convention. `tests/{google,aws}.env` (+ `.keyed` overlays) are the machine-readable copies of these
tables - the harness's guards compare the manifests against them.

### Published by both modules

| key                         | example                                                                 | consumed by                                                                                                                                                                                |
| --------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `CLUSTER_NAME`              | `patchy-x`                                                              | external-dns (txtOwnerId)                                                                                                                                                                  |
| `PLATFORM_REGISTRY`         | `us-central1-docker.pkg.dev/.../platform`                               | every RSIP + OCIRepository, the entrypoint's `manifests/<component>` sources                                                                                                               |
| `CONTAINER_REGISTRY`        | same                                                                    | every HelmRelease image value (`images/<upstream-path>`)                                                                                                                                   |
| `PLATFORM_COMPONENTS`       | `dex,flux-web,arc` (unset elects `dex,flux-web`; `none` elects nothing) | the entrypoint's election                                                                                                                                                                  |
| `PLATFORM_TREE`             | `aws` / `google` (from `flux.sync.path`)                                | flux - FluxInstance `sync.path`; applications select their own overlay by it                                                                                                               |
| `PLATFORM_DOMAIN`           | `patchy.bitwisemedia.co.uk`                                             | gateway listener + certificate, every platform HTTPRoute host, the dex issuer                                                                                                              |
| `FLUX_SYNC_URL`             | `oci://<registry>/manifests/platform`                                   | flux - FluxInstance `sync.url` (how a running cluster is re-pointed)                                                                                                                       |
| `FLUX_SYNC_CHANNEL`         | `edge` / `stable` (default `stable`)                                    | flux - FluxInstance sync ref; the entrypoint - every unpinned component's tag                                                                                                              |
| `SIGNED_IDENTITY_ISSUER`    | `^https://token\.actions\.githubusercontent\.com$`                      | verify blocks + kyverno policy (empty in KMS mode)                                                                                                                                         |
| `SIGNED_IDENTITY_CHARTS`    | flux-containers publish@main regexp                                     | chart OCIRepository verify (empty in KMS mode)                                                                                                                                             |
| `SIGNED_IDENTITY_IMAGES`    | flux-containers publish@main regexp                                     | kyverno policy (empty in KMS mode)                                                                                                                                                         |
| `SIGNED_IDENTITY_MANIFESTS` | flux-manifests publish regexp (per channel)                             | flux - sync OCIRepository verify patch; the entrypoint - every `platform-<component>` OCIRepository verify (empty in KMS mode)                                                             |
| `SIGNED_IDENTITY_KMS_KEY`   | KMS key ARN / resource name (empty when keyless)                        | selects KMS signing mode: chart and manifests verifies flip to the `cosign-pub` secretRef, the kyverno platform rule to a `keys.kms` attestor (`awskms:///` on aws, `gcpkms://` on google) |
| `COSIGN_PUBLIC_KEY`         | base64 PEM of the signing key's public half                             | KMS mode only - rendered into each component namespace's `cosign-pub` Secret for the chart verifies                                                                                        |
| `DNS_ZONE_NAME`             | `patchy-bitwisemedia-co-uk`                                             | external-dns zone filter (google; informational on aws - the zone ids filter there)                                                                                                        |
| `DNS_DOMAIN`                | `patchy.bitwisemedia.co.uk`                                             | external-dns domain filter                                                                                                                                                                 |
| `ACME_EMAIL`                | `you@bitwisemedia.co.uk`                                                | issuers                                                                                                                                                                                    |
| `GATEWAY_IP`                | `203.0.113.10`                                                          | (informational)                                                                                                                                                                            |
| `SECRET_PREFIX`             | `patchy-x-` (empty for unprefixed containers)                           | distinct per-cluster secret names - every GCP resourceName / AWS objectName                                                                                                                |
| `DEX_CONNECTORS`            | JSON array (typed `sso.connector`; `[]` when sso off)                   | dex - arbitrary SSO federation, one entry per upstream connector                                                                                                                           |
| `DEX_CLIENTS`               | JSON array of `{id, name, public, redirectURIs}` (`[]` when sso off)    | dex - every static client (the platform's `flux-web` and kubectl clients plus each application's); the `dex-client-<id>` sync per confidential entry. Every key present on every entry     |
| `RBAC_GROUP_VIEWERS`        | `gcp-x-patchy-viewers@bitwisemedia.co.uk`                               | rbac - cluster-wide `view`                                                                                                                                                                 |
| `RBAC_GROUP_DEVELOPERS`     | `gcp-x-patchy-developers@bitwisemedia.co.uk`                            | (no platform binding - applications bind their own roles on it)                                                                                                                            |
| `RBAC_GROUP_DEVOPS`         | `gcp-x-patchy-devops@bitwisemedia.co.uk`                                | rbac - cluster-wide `edit`                                                                                                                                                                 |
| `RBAC_GROUP_ADMINS`         | `gcp-x-patchy-admins@bitwisemedia.co.uk`                                | rbac - cluster-wide `cluster-admin`                                                                                                                                                        |
| `KYVERNO_FAILURE_ACTION`    | default `Audit`                                                         | kyverno policy - flip to `Enforce` after soaking a fresh cluster                                                                                                                           |
| `*_SEMVER`                  | `>=3.8.0 <4.0.0`                                                        | per-component chart range overrides (`ARC_SEMVER` also bounds every application scale set)                                                                                                 |
| `<NAME>_MANIFESTS_REF`      | `4.1.0` (caller extra; empty follows `FLUX_SYNC_CHANNEL`)               | the entrypoint - pins one component's manifests image to a tag (`-` to `_`, uppercased: `CERT_MANAGER_ISSUERS_MANIFESTS_REF`)                                                              |

### google only (`terraform-google-gke-flux`)

| key                    | example                                     | consumed by                                                                |
| ---------------------- | ------------------------------------------- | -------------------------------------------------------------------------- |
| `GCP_PROJECT`          | `x-patchy-app-ab12`                         | external-dns, issuers, every gke secret sync                               |
| `GCP_PROJECT_NUMBER`   | `123456789012`                              | (published for component use)                                              |
| `GCP_REGION`           | `us-central1`                               | (published for component use)                                              |
| `GATEWAY_ADDRESS_NAME` | `patchy-x-gateway`                          | gateway (`NamedAddress`)                                                   |
| `DEX_DIRECTORY_SA`     | `dex-directory@....iam.gserviceaccount.com` | dex KSA annotation (typed `sso.directory_sa`; empty when sso off or unset) |

### aws only (`terraform-aws-eks-flux`)

| key                                                                      | example                                     | consumed by                                                                                                                                                                      |
| ------------------------------------------------------------------------ | ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AWS_ACCOUNT_ID`                                                         | `123456789012`                              | (published for component use)                                                                                                                                                    |
| `AWS_REGION`                                                             | `eu-west-2`                                 | every aws SecretProviderClass (Secrets Manager region), external-dns SDK region, issuers                                                                                         |
| `AWS_PARTITION`                                                          | `aws`                                       | (published for component use)                                                                                                                                                    |
| `SECRETS_ROLE_PREFIX`                                                    | `arn:aws:iam::...:role/x-secrets-`          | every sync KSA's `eks.amazonaws.com/role-arn` annotation (`${SECRETS_ROLE_PREFIX}<ns>-<sa>` - the IRSA reader roles)                                                             |
| `OCI_PROVIDER`                                                           | `aws`                                       | OCIRepository registry auth (ECR via Pod Identity) and the FluxInstance `cluster.type` (the value sets coincide); the google tree relies on the manifests' `gcp` default instead |
| `ARTIFACT_TAG_PROVIDER`                                                  | `ECRArtifactTag`                            | every platform-registry RSIP; the google tree relies on the `GARArtifactTag` default                                                                                             |
| `DNS_PUBLIC_ZONE_ID`, `DNS_PRIVATE_ZONE_ID`                              | `Z0123456789ABCDEFGHIJ`                     | external-dns zone filters (one instance per flavour), issuers (route53 `hostedZoneID`)                                                                                           |
| `GATEWAY_NLB_SCHEME`                                                     | `internet-facing` / `internal`              | gateway - the NLB's scheme (a private Gateway)                                                                                                                                   |
| `GATEWAY_EIP_ALLOCATIONS`                                                | `eipalloc-...,eipalloc-...`                 | gateway - NLB Elastic IP allocation ids (Service annotation; absent for an internal NLB)                                                                                         |
| `GATEWAY_SUBNETS`                                                        | `subnet-...,subnet-...`                     | gateway - the subnets the NLB spans (Service annotation)                                                                                                                         |
| `GATEWAY_NLB_TARGET_TYPE`                                                | `instance`                                  | gateway - NLB target type; instance is all the LB controller supports off the VPC CNI                                                                                            |
| `GATEWAY_API_CRDS`                                                       | `true`                                      | gateway - installs the vendored Gateway API standard channel; flip `false` when EKS ships the CRDs natively (orphaned, never pruned)                                             |
| `CILIUM_K8S_SERVICE_HOST`                                                | `ABCDEF....gr7.eu-west-2.eks.amazonaws.com` | cilium - the EKS API server endpoint hostname (terraform's `cluster_endpoint_host` local), `k8sServiceHost` value                                                                |
| `CILIUM_POD_SUBNET_IDS`                                                  | `["subnet-...","subnet-..."]`               | cilium - JSON array, terraform's `pod_subnet_ids` local, `eni.subnetIDsFilter` value                                                                                             |
| `VPC_ID`, `NODE_SECURITY_GROUP_ID`, `CLUSTER_DISCOVERY_*`, `KARPENTER_*` | -                                           | reserved forward contract for future aws-only components (karpenter et al.)                                                                                                      |

Workload identity contract (namespace/serviceaccount names terraform grants against - pinned in the HelmRelease values
here): `external-dns/external-dns`, `cert-manager/cert-manager`, `kyverno/kyverno-{admission,reports}-controller`,
`flux-system/{source-controller,flux-operator}`, and the sync KSAs `dex/dex-secrets`, `flux-system/flux-web-secrets`.

## Releases and channels

release-please cuts `vX.Y.Z` from Conventional Commits; **publish.yaml** runs `scripts/publish.sh push` (every
`components/<name>` as `manifests/<name>:X.Y.Z`, cosign-signed per digest, then `platform` as `manifests/platform:X.Y.Z`
**last** - a tag never points at an entrypoint whose components are not there) and
`scripts/publish.sh tag X.Y.Z staging`; **promote.yaml** (workflow_dispatch, `production` environment) tags `stable`
after soak, pulling each image first as a sanity check. **publish-edge.yaml** additionally pushes every merge to main as
`edge-next`, signs it, and only then moves `edge` onto the same digests - so an edge cluster never pulls an artifact
whose signature is not yet attached. Clusters pin their channel in terraform (`flux.sync.ref`) and may pin a single
component's image with `<NAME>_MANIFESTS_REF`. The signing identity clusters verify is exactly
`.../flux-manifests/.github/workflows/publish.yaml@refs/tags/v*` for `staging`/`stable`, and
`.../publish-edge.yaml@refs/heads/main` for `edge` - the same identity for the entrypoint and every component image.

Every registry in the org's `PLATFORM_REGISTRY` and `AWS_PLATFORM_REGISTRY` variables receives every image; the AWS
branch of each workflow runs only when `AWS_MANIFEST_PUBLISHER_ROLE` is set (the artifact-store module's
`manifest_publishers` output for this repo, whose push grant covers `manifests/*`; an application repo's publisher
covers exactly `manifests/<app>`). `AWS_REGION` names the store's region.

### Re-pointing a cluster

`flux.sync.url` and `flux.sync.path` are applied by terraform at bootstrap and published as `FLUX_SYNC_URL` /
`PLATFORM_TREE`; the platform's own `flux` component re-asserts both on the FluxInstance (which is stack-managed and
which terraform ignores after bootstrap). Changing either in terraform therefore re-points a running cluster on the next
reconcile of `flux`. To recover a cluster stranded on an image or path that no longer exists, patch the FluxInstance
directly; the platform then holds the value as a fixed point:

```sh
kubectl patch fluxinstance flux -n flux-system --type merge \
  -p '{"spec":{"sync":{"url":"oci://<registry>/manifests/platform","path":"aws"}}}'    # "google" on the GKE cluster
```

## Validation

`make test` renders everything **four times - `{google,aws} x {keyless,keyed}`** - building every component's overlay
for the tree and the tree's entrypoint under that cloud's env contract alone (`tests/<tree>.env`, with
`tests/<tree>.keyed.env` overlaid for the KMS-signing passes; the google keyed overlay doubles as the _sparse_ caller,
publishing every optional surface empty). Substitution is faithful to kustomize-controller's post-build roundtrip -
scalar styles are normalized the way the controller's serializer would before a **textual** envsubst - so a quoted empty
var becomes null locally exactly as it would on the cluster, and the null guard fails the run naming the file and path
(self-tested at startup). Structural guards keep the layout honest: a common tier may not branch on cloud nor
bare-reference a single-cloud var, and a per-cloud overlay may not keep a `:=` default whose only purpose was surviving
the other cloud. ResourceSets render with `tests/inputs/<component>/{<tree>,common}/` fixtures via the flux-operator CLI
(the tree directory shadows `common` per basename; a `<file>.<variant>.yaml` sibling re-renders the same ResourceSet
with a different input set), the entrypoint with `tests/inputs/platform/<tree>/resourceset{,.none}.yaml` (everything
elected, then nothing), and two guards read those renders: **entrypoint completeness** (every shipped overlay is
emitted; every `dependsOn` resolves to a Kustomization the entrypoint or a component ResourceSet emits) and **election
independence** (the `none` render still emits every core component and no electable one). Everything kubeconforms
against flux + vendored CRD schemas (`tests/schemas/`, regenerated from upstream CRDs - see scripts/validate.sh).

## Migrating from 3.x

3.x shipped the whole repository as one artifact (`oci://<registry>/flux-manifests`, tree roots `aws/` and `google/`)
and carried the patchy application inside it. 4.0 publishes the entrypoint and one image per component, and patchy moves
to its own repo and image, seeded by the cluster module. On a running cluster, in order:

1. **Promote the transitional 3.x release** (the last 3.x): it annotates the eleven tree-root Kustomizations
   `kustomize.toolkit.fluxcd.io/prune: disabled`, sets `prune: false` on `optional` and everything it emits, renders
   `sync.url` from `FLUX_SYNC_URL` when set, and issues `Certificate platform-wildcard` (`platform-tls`) ahead of the
   listener swap. Verify the annotations and the wildcard secret.
2. **Freeze the optional tier**: `flux suspend ks optional -n flux-system` and annotate `ResourceSet/optional`
   `fluxcd.controlplane.io/reconcile=disabled`.
3. **Apply the 4.x cluster module** with the application composed in the root: `cluster-vars` gains the new keys
   (including `FLUX_SYNC_URL`), `<app>-vars` appears, the application seed is created and adopts the application's
   existing `Kustomization`.
4. **Re-point**: `flux reconcile ks flux -n flux-system`. The transitional flux component asserts the new `sync.url`;
   source-controller pulls `manifests/platform:<channel>`; the `flux-system` Kustomization applies
   `ResourceSet/platform` and its prune skips the annotated eleven; the `platform-<name>` sources appear and the
   same-named Kustomizations are adopted. The gateway swaps to the wildcard listener (`platform-tls` already issued);
   routes attach by hostname. Verify every Kustomization and source Ready, HelmReleases on their previous revisions, TLS
   serving.
5. **Remove the old tier**: delete the `dex-cloud`, `flux-web-cloud` and `<app>-cloud` Kustomizations (prune is off),
   `ResourceSet/optional`, `Kustomization/optional`, and the old `patchy-tls` Certificate.

Rollback through step 4: patch the FluxInstance back to the old url (above); the eleven Kustomizations are re-adopted by
`flux-system`; `flux resume ks optional`. Nothing was deleted with prune on.

Contract changes: `PLATFORM_COMPONENTS`, `PLATFORM_TREE`, `PLATFORM_DOMAIN`, `FLUX_SYNC_URL`, `DEX_CLIENTS` and the
`<NAME>_MANIFESTS_REF` / `ARC_SEMVER` extras are new; `STACK_COMPONENTS`, `FLUX_SYNC_PATH`, `PATCHY_DOMAIN`,
`PATCHY_EVALUATION`, `AGENT_*`, `CLAUDE_*`, `SCC_*` and `KUBECTL_OIDC_*` are gone (application-owned, delivered through
`<app>-vars`; kubectl's public client arrives in `DEX_CLIENTS`). The google module must publish the new keys to sync
4.0.

## Caveats

- **Bootstrap order**: the platform registry must hold every chart + image (flux-containers) and every
  `manifests/<component>` image plus the entrypoint (this repo's publish workflow) before a cluster can reconcile the
  platform, and the first cluster apply needs a published (staging or stable) channel.
- **Kyverno starts in Audit**: the policy's failureAction defaults to Audit - review PolicyReports on a fresh cluster,
  then set `KYVERNO_FAILURE_ACTION=Enforce` via terraform's `flux.cluster_vars`.
- **A component pin outlives the channel**: `<NAME>_MANIFESTS_REF` holds that component on its tag through every channel
  move until the extra is removed. Pin to soak or hold back, never to forget.
- **Un-electing flux-web keeps `flux-system`**: the component adopts the namespace to label it, and its manifest carries
  `kustomize.toolkit.fluxcd.io/prune: disabled` so the adoption can never garbage-collect the namespace flux itself runs
  in. Do not remove that label.
- **Gateway `NamedAddress`**: verify the accepted `spec.addresses.type` on the cluster's GKE version at first apply
  (`networking.gke.io` annotations are the fallback).
- **Gateway API CRDs on aws land after Cilium starts**: EKS ships no `gateway.networking.k8s.io` CRDs, so the gateway
  component's aws overlay ships the vendored standard channel under `crds/`, applied by the `gateway-api-crds`
  Kustomization its `resourceset-crds.yaml` emits while `GATEWAY_API_CRDS` holds. Cilium only enables its Gateway API
  controller when the CRDs are present at agent/operator startup, and on a fresh bootstrap terraform's cilium release
  comes up first. The entrypoint closes this: `cilium` depends on `gateway-api-crds` while the toggle holds, so the
  first-ever Flux reconcile of the adopted `cilium` HelmRelease lands only after the CRDs establish.
  `operator.podAnnotations`/`podAnnotations` also carry a version pin matching the vendored CRDs' `v=`
  (`components/gateway/aws/crds/kustomization.yaml`), bumped in lockstep with them, so a future CRD version bump forces
  a rollout too. When AWS ships the CRDs as managed cluster furniture, flip the cluster module's `gateway.install_crds`
  off: the entrypoint drops the dependency with the toggle, and the CRDs are orphaned (`prune: false`) - deleting them
  would cascade into every Gateway and HTTPRoute.
