---
description:
  "The verify-platform-signature ClusterPolicy: every pod image must carry the platform pipeline's cosign signature."
---

# kyverno-policies

One ClusterPolicy, `verify-platform-signature`: every Pod's images must carry a cosign signature from the platform
pipeline. It's the gate of the graph. Nearly every component that runs pods depends on it, so no platform workload can
start before the policy that checks it exists.

|                |                                                           |
| -------------- | --------------------------------------------------------- |
| **Tier**       | core                                                      |
| **Clouds**     | aws, google (one file per cloud)                          |
| **Depends on** | kyverno                                                   |
| **Namespace**  | `kyverno` (the ResourceSet); the policy is cluster-scoped |
| **Chart**      | none                                                      |

## What it deploys

A ResourceSet that renders the ClusterPolicy. It's a template rather than a plain manifest because the attestor's shape
follows the signing mode:

- **Keyless**: a `keyless` attestor matching `SIGNED_IDENTITY_IMAGES` and `SIGNED_IDENTITY_ISSUER`.
- **KMS-keyed**: a `keys.kms` attestor resolving the key through the cloud KMS API,
  `awskms:///${SIGNED_IDENTITY_KMS_KEY}` on aws and `gcpkms://${SIGNED_IDENTITY_KMS_KEY}` on google.

The two clouds' files differ only in that scheme and in the system registries they skip:

| cloud  | skipped image references                                                         |
| ------ | -------------------------------------------------------------------------------- |
| aws    | `registry.k8s.io/*`, `602401143452.dkr.ecr.*`, `*.dkr.ecr.*.amazonaws.com/eks/*` |
| google | `gke.gcr.io/*`, `gcr.io/gke-release/*`, `registry.k8s.io/*`                      |

## Design decisions

The reasoning for each is in [Signing & verification](../concepts/signing.md#the-admission-policy). In short:

- **`type: SigstoreBundle`**, because cosign v3 stores signatures as bundles through the OCI referrers API, not the
  legacy `.sig` tag. The `rekor.url` on the keyless attestor only satisfies Kyverno's CRD validation.
- **`failureAction: ${KYVERNO_FAILURE_ACTION:=Audit}`**: soak in Audit, then flip to Enforce with a cluster variable and
  no manifests release.
- **`mutateDigest: false`, `verifyDigest: false`**, because Kyverno rejects digest mutation under Audit, and the policy
  must be valid in both modes.
- **`webhookConfiguration.failurePolicy: Fail`**, with a 30-second timeout.
- **One identity, no carve-outs.** Applications signed elsewhere bring a PolicyException plus their own ClusterPolicy.
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
