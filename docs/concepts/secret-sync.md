# Secret sync

No credential lives in this repository or in terraform state. Every Secret the platform consumes (dex's connector fields
and client secrets, the Flux status UI's Web Config document) is held in the cloud's secret manager and **synced** into
the cluster by a `SecretProviderClass` / `SecretSync` pair in the component's per-cloud overlay.

The mapping is identical on both clouds: the same source names, the same target Secret names (the ones the charts
hardcode), the same consuming `*-secrets` ServiceAccounts. Only the dialect differs.

=== "aws"

    - **Machinery.** The Secrets Store CSI driver and its AWS provider arrive as the
      `aws-secrets-store-csi-driver-provider` EKS add-on (terraform). The missing piece, the upstream
      [secrets-store-sync-controller](https://github.com/kubernetes-sigs/secrets-store-sync-controller), which
      materialises Secrets **without** a pod mounting a CSI volume, is the platform's
      [secret-sync](../components/secret-sync.md) component. Every consumer depends on it.
    - **Source.** Secrets Manager, `objectName: ${SECRET_PREFIX}<name>` in `AWS_REGION`.
    - **Kinds.** `SecretProviderClass` with `provider: aws` and `usePodIdentity: "false"`; `SecretSync` from
      `secret-sync.x-k8s.io/v1alpha1`.
    - **Identity.** The controller requests each `SecretSync`'s ServiceAccount token with the `sts.amazonaws.com`
      audience, so the reader is the **consumer's** IRSA role, never the controller's own. Each sync ServiceAccount
      carries `eks.amazonaws.com/role-arn: ${SECRETS_ROLE_PREFIX}<namespace>-<serviceaccount>`, naming the reader role
      the cluster module creates.

=== "google"

    - **Machinery.** GKE Integrated Secret Synchronization, enabled by the gke module's `secret_sync` toggle. Nothing
      for the platform to install.
    - **Source.** Secret Manager, `resourceName: projects/${GCP_PROJECT}/secrets/${SECRET_PREFIX}<name>/versions/latest`.
    - **Kinds.** `SecretProviderClass` with `provider: gke`; `SecretSync` from `secret-sync.gke.io/v1`.
    - **Identity.** The `*-secrets` ServiceAccounts hold direct Workload Identity `secretAccessor` grants, made beside
      the secret containers.

## Why IRSA and not Pod Identity on aws

Pod Identity is used everywhere else on aws, but the syncs are **podless**. The controller mints a token for a
ServiceAccount through the TokenRequest API, and a token with no pod behind it lacks the `kubernetes.io/pod` claim that
Pod Identity's `AssumeRoleForPodIdentity` requires. IRSA only needs the ServiceAccount's OIDC token and the role ARN in
its annotation, so it works.

## Consumers

| component                             | Secret                      | sources                                                                                  | ServiceAccount                 |
| ------------------------------------- | --------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------ |
| [dex](../components/dex.md)           | `dex/dex-env`               | `dex-<connector>-<field>` per connector field, `dex-client-<id>` per confidential client | `dex/dex-secrets`              |
| [flux-web](../components/flux-web.md) | `flux-system/flux-web-auth` | `flux-web-auth-config` (the whole Web Config document)                                   | `flux-system/flux-web-secrets` |

The dex sync is a template over `DEX_CONNECTORS` and `DEX_CLIENTS`, so it only references containers that were actually
declared. terraform never creates a container nothing declared, and a reference to a missing one would wedge the whole
sync.

Applications sync their own credentials the same way, in their own namespaces. See [Applications](../applications.md).
