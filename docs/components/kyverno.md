---
description: "The admission policy engine that enforces the platform image-signature policy, PolicyExceptions enabled."
---

# kyverno

[Kyverno](https://kyverno.io) is the platform's admission policy engine. Its job here is to enforce one policy,
[`verify-platform-signature`](kyverno-policies.md): every pod image must be signed by the platform pipeline. It's the
first component on every cluster, and almost everything else waits for it.

|                |                                                                                                                             |
| -------------- | --------------------------------------------------------------------------------------------------------------------------- |
| **Tier**       | core                                                                                                                        |
| **Clouds**     | aws, google (common tier verbatim)                                                                                          |
| **Depends on** | nothing (the root of the graph)                                                                                             |
| **Namespace**  | `kyverno`                                                                                                                   |
| **Chart**      | [`kyverno`](https://oss.bitwisemedia.uk/flux-containers/charts/kyverno/), range `KYVERNO_SEMVER` (default `<4.0.0 >=3.8.0`) |
| **Timeout**    | 10m                                                                                                                         |

## What it deploys

- The `kyverno` namespace. Kyverno's own namespace is excluded from its webhooks by the chart, so the engine can always
  restart itself even when its admission webhook is down.
- The chart's input provider, OCIRepository and HelmRelease (see [Chart delivery](../concepts/chart-delivery.md)), with
  CRDs `CreateReplace` on install and upgrade.

## Notable values

- **Mirrored images.** `global.image.registry` points at `${CONTAINER_REGISTRY}/images/reg.kyverno.io`; the chart's
  per-controller repositories resolve beneath it.
- **HA admission.** `admissionController.replicas: 3`. The webhook has `failurePolicy: Fail`, so it's in every pod's
  critical path.
- **No hook jobs.** `webhooksCleanup` and `policyReportsCleanup` are disabled, keeping the image set identical to the
  mirror's discovery render. Without the pre-delete cleanup hook, webhook configurations linger if the release is ever
  uninstalled and have to be removed by hand.
- **PolicyExceptions on, in one namespace.** `features.policyExceptions` is enabled with `namespace: kyverno`. An
  application signed by a different identity ships its exception here, beside its own verifying ClusterPolicy. Limiting
  exceptions to one namespace makes an exception a platform-reviewed policy decision rather than something any workload
  namespace can grant itself. See [Applications](../applications.md#its-own-image-signer).

## Identity

Registry credentials for signature fetches come from terraform-created identity grants on the
`kyverno/kyverno-admission-controller` and `kyverno/kyverno-reports-controller` ServiceAccounts. In KMS mode, the same
grants allow `GetPublicKey`/`Verify` on the signing key.

## Cluster variables

`PLATFORM_REGISTRY`, `CONTAINER_REGISTRY`, `ARTIFACT_TAG_PROVIDER`, `OCI_PROVIDER`, `SIGNED_IDENTITY_*`,
`COSIGN_PUBLIC_KEY`, `KYVERNO_SEMVER`.

## Source

??? example "components/kyverno/common/input-provider.yaml"

    ```yaml
    --8<-- "components/kyverno/common/input-provider.yaml"
    ```

??? example "components/kyverno/common/resourceset.yaml"

    ```yaml
    --8<-- "components/kyverno/common/resourceset.yaml"
    ```
