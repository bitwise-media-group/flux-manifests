# Cluster variables

The cluster module (`terraform-google-gke-flux` or `terraform-aws-eks-flux`) publishes these into the `cluster-vars`
ConfigMap in `flux-system`. Every component's Kustomization substitutes them (`${VAR}`, `${VAR:=default}`). Optional
surfaces use the empty-string convention: published, but empty. See
[The empty-var convention](../concepts/substitution.md).

`tests/{google,aws}.env` (with the `.keyed` overlays) are the machine-readable copies of these tables, and the
[validation guards](../concepts/validation.md#the-env-contract) compare the manifests against them. Change both
together.

## Published by both modules

| key                         | example                                                                 | consumed by                                                                                                                                                                                                       |
| --------------------------- | ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CLUSTER_NAME`              | `patchy-x`                                                              | external-dns (`txtOwnerId`), aws-load-balancer-controller                                                                                                                                                         |
| `PLATFORM_REGISTRY`         | `us-central1-docker.pkg.dev/.../platform`                               | every input provider and OCIRepository, the entrypoint's `manifests/<component>` sources                                                                                                                          |
| `CONTAINER_REGISTRY`        | same                                                                    | every HelmRelease image value (`images/<upstream-path>`)                                                                                                                                                          |
| `PLATFORM_COMPONENTS`       | `dex,flux-web,arc` (unset elects `dex,flux-web`; `none` elects nothing) | the entrypoint's election                                                                                                                                                                                         |
| `PLATFORM_TREE`             | `aws` / `google` (from `flux.sync.path`)                                | flux: FluxInstance `sync.path`; applications select their own overlay by it                                                                                                                                       |
| `PLATFORM_DOMAIN`           | `patchy.bitwisemedia.co.uk`                                             | gateway listener and certificate, every platform HTTPRoute host, the dex issuer                                                                                                                                   |
| `FLUX_SYNC_URL`             | `oci://<registry>/manifests/platform`                                   | flux: FluxInstance `sync.url` (how a running cluster is re-pointed)                                                                                                                                               |
| `FLUX_SYNC_CHANNEL`         | `edge` / `stable` (default `stable`)                                    | flux: FluxInstance sync ref; the entrypoint: every unpinned component's tag                                                                                                                                       |
| `SIGNED_IDENTITY_ISSUER`    | `^https://token\.actions\.githubusercontent\.com$`                      | verify blocks and the kyverno policy (empty in KMS mode)                                                                                                                                                          |
| `SIGNED_IDENTITY_CHARTS`    | flux-containers `publish.yaml@main` regexp                              | chart OCIRepository verify (empty in KMS mode)                                                                                                                                                                    |
| `SIGNED_IDENTITY_IMAGES`    | flux-containers `publish.yaml@main` regexp                              | kyverno policy (empty in KMS mode)                                                                                                                                                                                |
| `SIGNED_IDENTITY_MANIFESTS` | flux-manifests publish regexp (per channel)                             | flux: the sync OCIRepository verify patch; the entrypoint: every `platform-<component>` OCIRepository verify (empty in KMS mode)                                                                                  |
| `SIGNED_IDENTITY_KMS_KEY`   | KMS key ARN / resource name (empty when keyless)                        | selects KMS signing mode: chart and manifests verifies switch to the `cosign-pub` secretRef, the kyverno rule to a `keys.kms` attestor (`awskms:///` on aws, `gcpkms://` on google)                               |
| `COSIGN_PUBLIC_KEY`         | base64 PEM of the signing key's public half                             | KMS mode only: rendered into each component namespace's `cosign-pub` Secret for the chart verifies                                                                                                                |
| `DNS_ZONE_NAME`             | `patchy-bitwisemedia-co-uk`                                             | external-dns zone filter (google; informational on aws, where the zone ids filter)                                                                                                                                |
| `DNS_DOMAIN`                | `patchy.bitwisemedia.co.uk`                                             | external-dns domain filter                                                                                                                                                                                        |
| `ACME_EMAIL`                | `you@bitwisemedia.co.uk`                                                | issuers                                                                                                                                                                                                           |
| `GATEWAY_IP`                | `203.0.113.10`                                                          | (informational)                                                                                                                                                                                                   |
| `SECRET_PREFIX`             | `patchy-x-` (empty for unprefixed containers)                           | distinct per-cluster secret names: every GCP `resourceName` and AWS `objectName`                                                                                                                                  |
| `DEX_CONNECTORS`            | JSON array (typed `sso.connector`; `[]` when sso is off)                | dex: arbitrary SSO federation, one entry per upstream connector                                                                                                                                                   |
| `DEX_CLIENTS`               | JSON array of `{id, name, public, redirectURIs}` (`[]` when sso is off) | dex: the platform's own static clients (`flux-web`, kubectl); the `dex-client-<id>` sync per confidential entry. Every key present on every entry. Applications register clients with `DexClient` objects instead |
| `RBAC_GROUP_VIEWERS`        | `gcp-x-patchy-viewers@bitwisemedia.co.uk`                               | rbac: cluster-wide `view`                                                                                                                                                                                         |
| `RBAC_GROUP_DEVELOPERS`     | `gcp-x-patchy-developers@bitwisemedia.co.uk`                            | (no platform binding; applications bind their own roles on it)                                                                                                                                                    |
| `RBAC_GROUP_DEVOPS`         | `gcp-x-patchy-devops@bitwisemedia.co.uk`                                | rbac: cluster-wide `edit`                                                                                                                                                                                         |
| `RBAC_GROUP_ADMINS`         | `gcp-x-patchy-admins@bitwisemedia.co.uk`                                | rbac: cluster-wide `cluster-admin`                                                                                                                                                                                |
| `KYVERNO_FAILURE_ACTION`    | default `Audit`                                                         | kyverno policy: switch to `Enforce` after soaking a fresh cluster                                                                                                                                                 |
| `*_SEMVER`                  | `>=3.8.0 <4.0.0`                                                        | per-component chart range overrides (`ARC_SEMVER` also bounds every application scale set)                                                                                                                        |
| `*_IMAGE_SEMVER`            | `>=2.44.0 <3.0.0`                                                       | tracked-image range overrides (`DEX_IMAGE_SEMVER`, `EXTERNAL_DNS_IMAGE_SEMVER`)                                                                                                                                   |
| `<NAME>_MANIFESTS_REF`      | `4.1.0` (caller extra; empty follows `FLUX_SYNC_CHANNEL`)               | the entrypoint: pins one component's manifests image to a tag (`-` to `_`, upper-cased: `CERT_MANAGER_ISSUERS_MANIFESTS_REF`)                                                                                     |

## google only

Published by `terraform-google-gke-flux`.

| key                    | example                                     | consumed by                                                                              |
| ---------------------- | ------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `GCP_PROJECT`          | `x-patchy-app-ab12`                         | external-dns, issuers, every gke secret sync                                             |
| `GCP_PROJECT_NUMBER`   | `123456789012`                              | (published for component use)                                                            |
| `GCP_REGION`           | `us-central1`                               | (published for component use)                                                            |
| `GATEWAY_ADDRESS_NAME` | `patchy-x-gateway`                          | gateway (`NamedAddress`)                                                                 |
| `DEX_DIRECTORY_SA`     | `dex-directory@....iam.gserviceaccount.com` | dex ServiceAccount annotation (typed `sso.directory_sa`; empty when sso is off or unset) |

## aws only

Published by `terraform-aws-eks-flux`.

| key                                                            | example                                     | consumed by                                                                                                                                                                      |
| -------------------------------------------------------------- | ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AWS_ACCOUNT_ID`                                               | `123456789012`                              | (published for component use)                                                                                                                                                    |
| `AWS_REGION`                                                   | `eu-west-2`                                 | every aws SecretProviderClass (Secrets Manager region), external-dns and the load balancer controller's region, issuers                                                          |
| `AWS_PARTITION`                                                | `aws`                                       | (published for component use)                                                                                                                                                    |
| `SECRETS_ROLE_PREFIX`                                          | `arn:aws:iam::...:role/x-secrets-`          | every sync ServiceAccount's `eks.amazonaws.com/role-arn` annotation (`${SECRETS_ROLE_PREFIX}<ns>-<sa>`, the IRSA reader roles)                                                   |
| `OCI_PROVIDER`                                                 | `aws`                                       | OCIRepository registry auth (ECR via Pod Identity) and the FluxInstance `cluster.type` (the value sets coincide); the google tree relies on the manifests' `gcp` default instead |
| `ARTIFACT_TAG_PROVIDER`                                        | `ECRArtifactTag`                            | every platform-registry input provider; the google tree relies on the `GARArtifactTag` default                                                                                   |
| `DNS_PUBLIC_ZONE_ID`, `DNS_PRIVATE_ZONE_ID`                    | `Z0123456789ABCDEFGHIJ`                     | external-dns zone filters (one instance per flavour), issuers (route53 `hostedZoneID`)                                                                                           |
| `GATEWAY_NLB_SCHEME`                                           | `internet-facing` / `internal`              | gateway: the NLB's scheme (a private Gateway)                                                                                                                                    |
| `GATEWAY_EIP_ALLOCATIONS`                                      | `eipalloc-...,eipalloc-...`                 | gateway: NLB Elastic IP allocation ids (Service annotation; absent for an internal NLB)                                                                                          |
| `GATEWAY_SUBNETS`                                              | `subnet-...,subnet-...`                     | gateway: the subnets the NLB spans (Service annotation)                                                                                                                          |
| `GATEWAY_NLB_TARGET_TYPE`                                      | `instance`                                  | gateway: NLB target type; `instance` is all the load balancer controller supports off the VPC CNI                                                                                |
| `GATEWAY_API_CRDS`                                             | `true`                                      | gateway: installs the vendored Gateway API standard channel; switch to `false` when EKS ships the CRDs natively (orphaned, never pruned)                                         |
| `CILIUM_K8S_SERVICE_HOST`                                      | `ABCDEF....gr7.eu-west-2.eks.amazonaws.com` | cilium: the EKS API server endpoint hostname (terraform's `cluster_endpoint_host` local), `k8sServiceHost` value                                                                 |
| `CILIUM_POD_SUBNET_IDS`                                        | `["subnet-...","subnet-..."]`               | cilium: JSON array, terraform's `pod_subnet_ids` local, `eni.subnetIDsFilter` value                                                                                              |
| `VPC_ID`                                                       | `vpc-...`                                   | aws-load-balancer-controller (`vpcId`)                                                                                                                                           |
| `NODE_SECURITY_GROUP_ID`, `CLUSTER_DISCOVERY_*`, `KARPENTER_*` | -                                           | reserved forward contract for future aws-only components (karpenter and others)                                                                                                  |

## Workload identity contract

terraform grants cloud identities against fixed namespace/ServiceAccount pairs, and the components pin those names in
their HelmRelease values so the contract holds:

| ServiceAccount                                                               | used for                                                 |
| ---------------------------------------------------------------------------- | -------------------------------------------------------- |
| `external-dns/external-dns`                                                  | DNS zone access                                          |
| `cert-manager/cert-manager`                                                  | DNS-01 challenges                                        |
| `kyverno/kyverno-admission-controller`, `kyverno/kyverno-reports-controller` | registry access for signatures; KMS verify in keyed mode |
| `flux-system/source-controller`, `flux-system/flux-operator`                 | registry access for artifacts and tag listing            |
| `aws-load-balancer-controller/aws-load-balancer-controller` (aws)            | ELB/EC2 for the NLB                                      |
| `dex/dex` (google)                                                           | Directory API through domain-wide delegation             |
| `dex/dex-secrets`, `flux-system/flux-web-secrets`                            | secret sync readers                                      |

## The env contracts

??? example "tests/aws.env"

    ```sh
    --8<-- "tests/aws.env"
    ```

??? example "tests/aws.keyed.env"

    ```sh
    --8<-- "tests/aws.keyed.env"
    ```

??? example "tests/google.env"

    ```sh
    --8<-- "tests/google.env"
    ```

??? example "tests/google.keyed.env"

    ```sh
    --8<-- "tests/google.keyed.env"
    ```
