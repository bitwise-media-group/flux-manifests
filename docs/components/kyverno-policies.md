---
description:
  "The verify-platform-signature ImageValidatingPolicy: every pod image must carry the platform pipeline's cosign
  signature."
---

# kyverno-policies

One ImageValidatingPolicy, `verify-platform-signature`: every Pod's images must carry a cosign signature from the
platform pipeline. It's the gate of the graph. Nearly every component that runs pods depends on it, so no platform
workload can start before the policy that checks it exists.

|                |                                                           |
| -------------- | --------------------------------------------------------- |
| **Tier**       | core                                                      |
| **Clouds**     | aws, google (one file per cloud)                          |
| **Depends on** | kyverno                                                   |
| **Namespace**  | `kyverno` (the ResourceSet); the policy is cluster-scoped |
| **Chart**      | none                                                      |

## What it deploys

A ResourceSet that renders a `policies.kyverno.io/v1` `ImageValidatingPolicy`, Kyverno's CEL image-verification kind
(the `kyverno.io` ClusterPolicy it replaces is deprecated). It's a template rather than a plain manifest because the
attestor's shape and the action follow cluster variables:

- **Keyless**: a cosign `keyless` attestor matching `SIGNED_IDENTITY_IMAGES` and `SIGNED_IDENTITY_ISSUER`.
- **KMS-keyed**: a cosign `key.kms` attestor resolving the key through the cloud KMS API,
  `awskms:///${SIGNED_IDENTITY_KMS_KEY}` on aws and `gcpkms://${SIGNED_IDENTITY_KMS_KEY}` on google.
- **The action**: `KYVERNO_FAILURE_ACTION` keeps its values. `Audit` renders `validationActions: [Audit]` and `Enforce`
  renders `[Deny]`.

The two clouds' files differ in that scheme, the registry credential provider (`amazon` or `google`), and the system
registries they skip:

| cloud  | skipped image references                                                                                  |
| ------ | --------------------------------------------------------------------------------------------------------- |
| aws    | `registry.k8s.io/`, `602401143452.dkr.ecr.`, `*.dkr.ecr.*.amazonaws.com/eks/`                             |
| google | `gke.gcr.io/`, `gcr.io/gke-release/`, `<region>-artifactregistry.gcr.io/gke-release/`, `registry.k8s.io/` |

## Design decisions

The reasoning for each is in [Signing & verification](../concepts/signing.md#the-admission-policy). In short:

- **Skipping is matching.** The system registries are excluded through `matchImageReferences`, whose CEL expressions see
  the image as `ref`. The policy's `images` variable carries only matched images, so the validation never sees the
  system ones, and `required` fails any matched image no policy in the request verified.
- **Sigstore bundles, detected.** cosign v3 stores signatures as bundles through the OCI referrers API; the image
  verifier finds and verifies them (transparency-log entry included) with no `type` to set.
- **Per-policy registry credentials.** This kind has no global credential helper, so the policy names the cloud's
  provider, which uses kyverno's existing workload identity on the platform registry.
- **Soak, then enforce**: `[Audit]` until `KYVERNO_FAILURE_ACTION` is `Enforce`, with no manifests release.
- **`mutateDigest: false`, `verifyDigest: false`**. This kind rewrites tags to digests by default, which would change
  pods the policy is only meant to report on under Audit.
- **`failurePolicy: Fail`**, with a 30-second webhook timeout.
- **One identity, no carve-outs.** Applications signed elsewhere bring a `policies.kyverno.io` PolicyException plus
  their own ImageValidatingPolicy, as does the dex component for [dex-client-controller](dex.md#dex-client-controller)'s
  ghcr image. Image policies honour only whole-resource exceptions, so an exemption is by pod.
- **Variables compared inline**, not through `spec.inputs`, so an empty key can't become null.

## Cluster variables

`SIGNED_IDENTITY_IMAGES`, `SIGNED_IDENTITY_ISSUER`, `SIGNED_IDENTITY_KMS_KEY`, `KYVERNO_FAILURE_ACTION`.

## Source

=== "aws"

    ```yaml
    --8<-- "components/kyverno-policies/aws/resourceset.yaml"
    ```

=== "google"

    ```yaml
    --8<-- "components/kyverno-policies/google/resourceset.yaml"
    ```
