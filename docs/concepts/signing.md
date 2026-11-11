# Signing & verification

Every artifact a cluster pulls is signature-verified, and every pod image must be signed by the platform pipeline to be
admitted. Nothing on the path from registry to running pod is trusted by location alone.

## What's verified, by whom

| artifact                              | signed by                         | verified by                                             | identity variable           |
| ------------------------------------- | --------------------------------- | ------------------------------------------------------- | --------------------------- |
| `manifests/platform` (the entrypoint) | this repo's release workflow      | source-controller, via the FluxInstance verify patch    | `SIGNED_IDENTITY_MANIFESTS` |
| `manifests/<component>`               | this repo's release workflow      | source-controller, each `platform-<name>` OCIRepository | `SIGNED_IDENTITY_MANIFESTS` |
| `charts/<chart>`                      | flux-containers' publish workflow | source-controller, each chart OCIRepository             | `SIGNED_IDENTITY_CHARTS`    |
| `images/<path>` (every pod image)     | flux-containers' publish workflow | Kyverno, `verify-platform-signature` ClusterPolicy      | `SIGNED_IDENTITY_IMAGES`    |

The issuer for all keyless identities is `SIGNED_IDENTITY_ISSUER`, GitHub Actions' OIDC issuer.

## Two signing modes

The cluster module chooses the mode, and every verify point in the platform follows it.

=== "Keyless (default)"

    Each publish workflow signs with its GitHub OIDC identity through Fulcio: no key exists anywhere. Clusters pin the
    exact certificate identity as a regular expression:

    ```yaml
    verify:
      provider: cosign
      matchOIDCIdentity:
        - issuer: '${SIGNED_IDENTITY_ISSUER}'
          subject: '${SIGNED_IDENTITY_MANIFESTS}'
    ```

    `SIGNED_IDENTITY_KMS_KEY` is published empty.

=== "KMS-keyed"

    When `SIGNED_IDENTITY_KMS_KEY` is set, artifacts are signed with a cloud KMS key and the keyless identity variables
    are published empty. Verification switches shape:

    - **OCIRepositories** verify against a `cosign-pub` Secret. In `flux-system` it's delivered by the bootstrap; in
      every other component namespace the component's ResourceSet renders it from the `COSIGN_PUBLIC_KEY` variable
      (the base64 PEM of the key's public half).
    - **Kyverno** resolves the key through the cloud KMS API at admission (`awskms:///<arn>` on aws,
      `gcpkms://<resource>` on google). terraform grants the Kyverno controllers `GetPublicKey`/`Verify` on the key.

Because the verify block's shape changes, every OCIRepository that verifies lives in a `resourcesTemplate` with a
`$keyed` branch. See [Chart delivery](chart-delivery.md#the-resourceset).

## The manifests identity

Every artifact is signed by the release workflow of the repository that publishes it, on `main`, through the
[`patchy-publish`](https://oss.bitwisemedia.uk/github-workflows/actions/patchy-publish/) action. The certificate subject
is the workflow path plus the ref it ran on:

```text
https://github.com/bitwise-media-group/flux-manifests/.github/workflows/release.yaml@refs/heads/main
```

Edge builds and stable releases carry the same signature, because a release is the newest edge build promoted, not
rebuilt: the channel is told apart by the tag a cluster follows, and a stable cluster follows `>=0.0.0`, which never
matches an edge build. A cluster's `SIGNED_IDENTITY_MANIFESTS` (the artifact-store module's
`signed_identity_subjects.manifests`) trusts the release workflow of every repository in the org,
`^https://github\.com/bitwise-media-group/[^/]+/\.github/workflows/release\.yaml@refs/heads/main$`. Only a repository in
the org can produce that identity. The same identity covers the entrypoint and every component image. See
[Releases & channels](releases.md).

## The admission policy

The [kyverno-policies](../components/kyverno-policies.md) component installs one ClusterPolicy,
`verify-platform-signature`. Every Pod's images must carry a cosign signature from the platform pipeline:

- **One identity, no carve-outs.** The policy knows only the platform's signer. An application whose images are signed
  elsewhere ships a `PolicyException` in the `kyverno` namespace, scoped to its own namespaces, beside its own
  ClusterPolicy verifying its signer. Every image is still verified by exactly one policy, and the platform never learns
  the application's registry. See [Applications](../applications.md). The platform's one first-party ghcr image,
  [dex-client-controller](../components/dex.md#dex-client-controller), uses the same pattern from inside the dex
  component, scoped to the controller's own pods.
- **Cloud system images are skipped by registry**: `registry.k8s.io/*` everywhere, the EKS add-on registries on aws,
  `gke.gcr.io/*` and `gcr.io/gke-release/*` on google. Registries are the stable contract; new managed namespaces appear
  with cluster features. `kube-system` is also excluded at the webhook level by the kyverno chart.
- **Sigstore bundles.** The platform signs with cosign v3, which stores signatures as sigstore bundles through the OCI
  referrers API, so the policy uses `type: SigstoreBundle`. The transparency-log entry travels in the bundle and is
  checked offline against the sigstore trusted root. Flux verifies the same bundles independently (source-controller
  v1.8 / Flux 2.8 and later).
- **Audit first.** `failureAction` comes from `KYVERNO_FAILURE_ACTION`, defaulting to `Audit`. Soak a fresh cluster,
  review the PolicyReports, then set it to `Enforce`. See
  [Operations](../reference/operations.md#enforcing-the-signature-policy).
- **No digest mutation.** Kyverno rejects `mutateDigest` under `Audit`, and the policy must be valid in both modes, so
  digest rewriting and `verifyDigest` are off. What's verified is the signature on whatever the tag resolves to at
  admission.
