# Changelog

## [3.0.0](https://github.com/bitwise-media-group/flux-manifests/compare/v2.0.0...v3.0.0) (2026-09-03)


### ⚠ BREAKING CHANGES

* **aws:** the aws tree now requires the SECRETS_ROLE_PREFIX cluster var -- pair with the terraform-aws-eks-flux release that registers the cluster's IRSA OIDC provider and publishes it.
* the artifact layout contract changes. There is no ./stack entrypoint any more: clusters must sync path "aws" or "google" (terraform-aws-eks-flux / terraform-google-gke-flux >= their matching feat! releases, or a manual kubectl patch fluxinstance flux -n flux-system --type merge -p '{"spec":{"sync":{"path":"aws"}}}'). The CLOUD cluster var is retired, the aws tree requires the aws module's reserved vars (OCI_PROVIDER, ARTIFACT_TAG_PROVIDER, AWS_*, DNS_ZONE_ID, GATEWAY_*) bare, and otel-collector is gone.

### Features

* **aws:** deploy the AWS Load Balancer Controller ([efd1486](https://github.com/bitwise-media-group/flux-manifests/commit/efd14860b0c2e2e77edb4cd6273a1d390a31e818))
* **aws:** elect an internal Gateway NLB via GATEWAY_NLB_SCHEME ([e7b38b4](https://github.com/bitwise-media-group/flux-manifests/commit/e7b38b4c27a53b96cca6a8182d13eb9e0f2804ed))
* **aws:** filter external-dns on both split-horizon zone ids ([3535b07](https://github.com/bitwise-media-group/flux-manifests/commit/3535b0777e1779de991bcd508a6912e4149ef004))
* **aws:** hand cilium off from terraform to flux after gateway API CRDs establish ([5a2d1d0](https://github.com/bitwise-media-group/flux-manifests/commit/5a2d1d01457c9d0d839256dac6a7b987df9f92ec))
* branch artifact verification on the KMS signing mode ([526c899](https://github.com/bitwise-media-group/flux-manifests/commit/526c8998e60942aebe09633f35bf54be201e4681))
* **dex:** render connectors from DEX_CONNECTORS instead of a hardcoded google entry ([9ebfbd7](https://github.com/bitwise-media-group/flux-manifests/commit/9ebfbd73b4e539759f3e48efceb5e2e4ceb9afd6))
* follow mirror-tracked image tags via per-image input providers ([9da9856](https://github.com/bitwise-media-group/flux-manifests/commit/9da985626af54a9af2b74da061534a2a4d59e2b3))
* **gateway:** install the Gateway API CRDs on aws ([7ee632d](https://github.com/bitwise-media-group/flux-manifests/commit/7ee632de72dc2fde9d1eeb903fddf025b1d90c6a))
* **gateway:** serve from an EIP-bound NLB on aws ([cc8045a](https://github.com/bitwise-media-group/flux-manifests/commit/cc8045a55320dd26a05114eaa5073575ea430994))
* **patchy:** configure the egress broker and model provider via cluster vars ([a0cf97d](https://github.com/bitwise-media-group/flux-manifests/commit/a0cf97d78bda889a2389c7fcd05e5b3bd90198a1))
* **patchy:** deploy the optional evaluation controller ([b95fa58](https://github.com/bitwise-media-group/flux-manifests/commit/b95fa585850b61a4ca6538788ec79fbab81ed584))
* **patchy:** ingest Security Command Center findings ([aa7fa71](https://github.com/bitwise-media-group/flux-manifests/commit/aa7fa710dc7e026c30843ff71e0188069a9d59ae))
* port external-dns, otel-collector and the issuers to aws ([80c4314](https://github.com/bitwise-media-group/flux-manifests/commit/80c43142ffd14b8d53d77abd54d2a2ebf14e7dd9))
* split the stack into per-cloud trees (aws / google / common) ([b3d165a](https://github.com/bitwise-media-group/flux-manifests/commit/b3d165a27afb80dd4dbadc07fad283878e852662))
* sync secrets from AWS Secrets Manager when CLOUD=aws ([05f6321](https://github.com/bitwise-media-group/flux-manifests/commit/05f632199573d6f313a6bd6d0e4429b43d9b50c3))


### Bug Fixes

* **aws:** serve each Route53 zone flavour with its own external-dns ([a7b804d](https://github.com/bitwise-media-group/flux-manifests/commit/a7b804d349650ee663af7518b70151c1a0235652))
* **aws:** sync secrets via IRSA instead of EKS Pod Identity ([62e773a](https://github.com/bitwise-media-group/flux-manifests/commit/62e773a603cdbd65f6bc72b3b828d5fd35087266))
* default cloud-branch secret-sync vars so strict envsubst passes cross-cloud ([2348f3c](https://github.com/bitwise-media-group/flux-manifests/commit/2348f3c5aa582f2c6026aded492d94fdf8be1a05))
* **deps:** update bitwise-media-group/github-workflows action to v6.1.1 ([#26](https://github.com/bitwise-media-group/flux-manifests/issues/26)) ([ea1c174](https://github.com/bitwise-media-group/flux-manifests/commit/ea1c174f96111a60aee0dd8cf7c262597b990dab))
* **deps:** update bitwise-media-group/github-workflows action to v6.2.0 ([#34](https://github.com/bitwise-media-group/flux-manifests/issues/34)) ([48982ee](https://github.com/bitwise-media-group/flux-manifests/commit/48982eee4a79c64df36aa1bce87067d037d819b2))
* **deps:** update fluxcd/flux2 action to v2.9.4 ([#27](https://github.com/bitwise-media-group/flux-manifests/issues/27)) ([d9e9c5f](https://github.com/bitwise-media-group/flux-manifests/commit/d9e9c5fccbbc9e5c7d014b88eda8ad788cff3e3b))
* **deps:** update fluxcd/flux2 action to v2.9.5 ([#56](https://github.com/bitwise-media-group/flux-manifests/issues/56)) ([0aa50e2](https://github.com/bitwise-media-group/flux-manifests/commit/0aa50e2679cfce0187b2cdb696e28c4fdfd8be4e))
* **flux-web:** admit each cloud's gateway data plane to the web UI ([697e8ae](https://github.com/bitwise-media-group/flux-manifests/commit/697e8ae57af326c513b3197c9551a78556fe123a))
* **flux-web:** probe the operator's readiness port, not the SSO UI ([1c6473f](https://github.com/bitwise-media-group/flux-manifests/commit/1c6473f1e9544e25a0ae6b2151583ab2b650ed04))
* **flux:** gate off helm-controller chart digest tracking ([91b1979](https://github.com/bitwise-media-group/flux-manifests/commit/91b1979ad1364980b14bccab5e7d4c36262b9fe6))
* read cluster vars inline in ResourceSet templates ([a78c07d](https://github.com/bitwise-media-group/flux-manifests/commit/a78c07d67da0d2cff08588ba2b957cce604ca036))
* render the optional tier on aws without the google-only cluster vars ([f08778b](https://github.com/bitwise-media-group/flux-manifests/commit/f08778bd5bcb54d8e4783b824a9330996bfcb20f))
* substitute the RSIP type from ARTIFACT_TAG_PROVIDER ([3f931fe](https://github.com/bitwise-media-group/flux-manifests/commit/3f931fe3e3b73eeed59c7648162ded41bbaf0149))

## [2.0.0](https://github.com/bitwise-media-group/flux-manifests/compare/v1.0.0...v2.0.0) (2026-07-26)


### ⚠ BREAKING CHANGES

* **patchy:** the patchy chart floor moves from 0.5.0 to 0.7.0; a cluster pinning PATCHY_SEMVER below that will fail schema validation on the agent.runners block.
* **rbac:** the devops subject group no longer holds cluster-admin; enrol cluster administrators in the admins group (RBAC_GROUP_ADMINS) instead.

### Features

* **ci:** publish edge channel on every merge to main ([136c4e1](https://github.com/bitwise-media-group/flux-manifests/commit/136c4e1c5682e241536923f5bfdc494850833eb5))
* **dex:** deploy dex as the platform OIDC provider ([1cc8c12](https://github.com/bitwise-media-group/flux-manifests/commit/1cc8c12a1e484ed423bdd38c895a6f9a31bf3283))
* **flux-web:** put the Flux status web UI behind dex on its own hostname ([ac975ef](https://github.com/bitwise-media-group/flux-manifests/commit/ac975ef8c613a17ecc98b90c48a878710a4884cf))
* **flux:** manage flux itself from the stack ([9ef920f](https://github.com/bitwise-media-group/flux-manifests/commit/9ef920f563ef44172c42cce6f698b8013ea68df6))
* **gateway:** serve the integrations, status, dex and flux hostnames ([281fb10](https://github.com/bitwise-media-group/flux-manifests/commit/281fb10e92ebbf092bbb145100a9a6f160a08d77))
* **kyverno-policies:** trust patchy's release identity for its ghcr images ([063c7dd](https://github.com/bitwise-media-group/flux-manifests/commit/063c7ddc54513285427061256e1c87c28a60525b))
* **patchy:** deploy patchy with Secret Manager-synced credentials and a mocked CMDB ([48ec9be](https://github.com/bitwise-media-group/flux-manifests/commit/48ec9be528c5f59086c976dfeaeaabb4b0c5f8c5))
* **patchy:** deploy the 0.4.0 CRD stack and the status page behind dex ([8e48c3a](https://github.com/bitwise-media-group/flux-manifests/commit/8e48c3a57ed76a229fac1ccba289c9aac53cd1c4))
* **patchy:** let the agent egress dialect resolve per cluster ([b27e3dc](https://github.com/bitwise-media-group/flux-manifests/commit/b27e3dcfdf55ccbded93702141bdb38a48dd4417))
* **patchy:** move to the per-harness agent runner surface ([d9e5581](https://github.com/bitwise-media-group/flux-manifests/commit/d9e55818f6032fecfe0a284443516663ecf12779))
* **patchy:** run every controller at info log level ([8d1f2db](https://github.com/bitwise-media-group/flux-manifests/commit/8d1f2db0c9cfa14b9f3efce693682f5c8b939b61))
* **patchy:** split the Integration/Forge CRs into the patchy-config chart ([0990de6](https://github.com/bitwise-media-group/flux-manifests/commit/0990de6ad9f38234685557670aed21205d57c6f4))
* **rbac:** bind admins to cluster-admin and drop devops to edit ([498be32](https://github.com/bitwise-media-group/flux-manifests/commit/498be323a30acec6f41b03fee62d9cd4ee1846da))
* **rbac:** bind Google Groups to cluster RBAC via a templated ResourceSet ([9b0656b](https://github.com/bitwise-media-group/flux-manifests/commit/9b0656b0ae2e115b5fef9e50c86f84ea6060dee2))
* **secrets:** prefix Secret Manager container names with SECRET_PREFIX ([e98a9bc](https://github.com/bitwise-media-group/flux-manifests/commit/e98a9bc428e503f40f2d92839d0f407bbfef14d3))
* **stack:** elect the optional tier (dex, flux-web, patchy) via STACK_COMPONENTS ([e758bbb](https://github.com/bitwise-media-group/flux-manifests/commit/e758bbbb01c99580004b0cb19016b9fc6ec2d277))


### Bug Fixes

* **ci:** log in to the registry with docker login, not flux oci login ([80dfe9a](https://github.com/bitwise-media-group/flux-manifests/commit/80dfe9a3395a051a307abcf30b9193c52711d350))
* **components:** reorder semver defaults so post-build output stays valid YAML ([8e52a83](https://github.com/bitwise-media-group/flux-manifests/commit/8e52a8360d8e9c7e74e4c6051144cc16fc4e9df4))
* **flux:** single-quote issuer in FluxInstance verify patch ([feaae54](https://github.com/bitwise-media-group/flux-manifests/commit/feaae544b2a2112413212129b36d6796eea72021))
* **kyverno-policies:** add rekor url to keyless attestors ([e611b3d](https://github.com/bitwise-media-group/flux-manifests/commit/e611b3d9b6f7b18bf2d55c3458b22158ac6aacd4))
* **kyverno-policies:** disable digest mutation to keep the policy valid under Audit ([6c6bc2a](https://github.com/bitwise-media-group/flux-manifests/commit/6c6bc2a13257f3e0f984a4c35dc18405d42cbf66))
* **kyverno-policies:** verify patchy images as sigstore bundles from the shared workflow identity ([b328d1e](https://github.com/bitwise-media-group/flux-manifests/commit/b328d1ebc418f20762ece26a84c573b840187710))
* **kyverno-policies:** verify patchy images via the legacy cosign path ([cc77c6d](https://github.com/bitwise-media-group/flux-manifests/commit/cc77c6df6652d2b384bc666ef6c4d0be92c66408))
* **kyverno:** verify the sigstore bundle format cosign v3 actually signs ([0e2d772](https://github.com/bitwise-media-group/flux-manifests/commit/0e2d77292a8f15819281ee41075c1bee01a7c543))
* **patchy:** point the gateway health check at /readyz ([a465931](https://github.com/bitwise-media-group/flux-manifests/commit/a4659314a92aa622baa727307c53cc9ba3b95b14))
* **patchy:** reorder the semver default so post-build substitution yields valid YAML ([60be918](https://github.com/bitwise-media-group/flux-manifests/commit/60be918d714de2981c5e275df7041fc2168dec83))
* set flux-operator image to use the platform registry ([2a9c734](https://github.com/bitwise-media-group/flux-manifests/commit/2a9c734af8873d736dfb1bafa6c97f2aaf3716e7))

## 1.0.0 (2026-07-17)


### Features

* GKE platform stack synced as a signed OCI artifact ([6f26a72](https://github.com/bitwise-media-group/flux-manifests/commit/6f26a72b46a28fb73ecf0b886182ac6f91f2e4e5))


### Bug Fixes

* **ci:** read the publisher SA from GCP_MANIFEST_PUBLISHER_SA ([fd6c724](https://github.com/bitwise-media-group/flux-manifests/commit/fd6c724a4806c4e320f9f584822175f66790d3d8))
