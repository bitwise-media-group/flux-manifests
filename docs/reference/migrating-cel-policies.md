# Migrating to CEL policies

Kyverno deprecates its `kyverno.io` policy kinds (`ClusterPolicy`, `kyverno.io/v2` `PolicyException`) in favour of the
CEL-based `policies.kyverno.io/v1` kinds, and will remove them. The platform's policies have moved:

| policy                                   | was             | now                                                     |
| ---------------------------------------- | --------------- | ------------------------------------------------------- |
| `verify-platform-signature`              | `ClusterPolicy` | `ImageValidatingPolicy`                                 |
| `verify-dex-client-controller-signature` | `ClusterPolicy` | `ImageValidatingPolicy` (the image-only rule folded in) |
| `dex-client-controller-images`           | `kyverno.io/v2` | `policies.kyverno.io/v1` `PolicyException`              |
| `restrict-dex-resources`                 | `ClusterPolicy` | `ValidatingPolicy`                                      |
| `auth-proxy-secrets`                     | `ClusterPolicy` | `NamespacedGeneratingPolicy` (in `auth-proxy`)          |

The cluster variables don't change. `KYVERNO_FAILURE_ACTION` keeps its values: `Audit` renders
`validationActions: [Audit]`, and `Enforce` renders `[Deny]`. The kyverno component already runs a release (1.19) that
serves the `v1` kinds.

## What applications must change

An application whose images are signed elsewhere (see [Its own image signer](../applications.md#its-own-image-signer))
ships two objects, and both change kind:

- **The exception.** Replace the `kyverno.io/v2` `PolicyException` with a `policies.kyverno.io/v1` one in `kyverno`:
  `policyRefs: [{kind: ImageValidatingPolicy, name: verify-platform-signature}]`, scoped by `matchConditions` (for
  example `request.namespace in ['my-app']`). The old exception names a `ClusterPolicy` that no longer exists, so it
  stops exempting anything.
- **Its own policy.** Replace the `ClusterPolicy` with an `ImageValidatingPolicy`. Image policies honour only
  whole-resource exceptions, so the exemption covers whole pods, and the application's policy must close over every
  image in them: match `*` (`images` holds only matched images), verify its own images against its signer, and either
  verify everything else against the platform identity or reject it. Keyless `additionalExtensions` keys such as
  `githubWorkflowRepository` work as before. Name the registry credential provider (`amazon` or `google`) if it verifies
  platform-registry images, because this kind has no global credential helper.

[dex](../components/dex.md#dex-client-controller)'s `resourceset-client-controller-policy.yaml` is a worked example.

## On a running cluster, in order

1. **Ship the application's new objects first, beside the old ones.** A `policies.kyverno.io` exception naming a policy
   that doesn't exist yet is inert, and the application's new policy verifies alongside its old one.
2. **Roll the platform.** Each ResourceSet applies the new kind and garbage-collects the old one under the same name.
   Under `Audit` nothing is denied while they swap; under `Enforce`, step 1 is what keeps the application's pods
   admitted.
3. **Check the reports.** `kubectl get policyreports -A` should show `verify-platform-signature` passing, and skipping
   the exempted pods, with no failures for the application's images.
4. **Remove the application's old objects.**

auth-proxy is new with this change, so no cluster has secrets minted by the old policy to carry over.
