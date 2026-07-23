# Changelog

## [2.0.0](https://github.com/bitwise-media-group/flux-manifests/compare/v1.0.0...v2.0.0) (2026-07-23)


### ⚠ BREAKING CHANGES

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
