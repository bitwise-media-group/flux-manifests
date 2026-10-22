---
description:
  "The platform's OIDC identity provider: data-driven connectors and clients, credentials synced from the cloud."
---

# dex

[Dex](https://dexidp.io) is the platform's OpenID Connect identity provider. The Flux status UI, kubectl and any
application that declares a client sign people in through it. It's entirely data-driven: the upstream connectors and the
relying-party clients both arrive as JSON cluster variables, so dex never learns an application's name.

|                |                                                                                                                  |
| -------------- | ---------------------------------------------------------------------------------------------------------------- |
| **Tier**       | electable, included by the cluster module exactly when its `sso` toggle is on                                    |
| **Clouds**     | aws, google (common tier + per-cloud secret sync)                                                                |
| **Depends on** | kyverno-policies, gateway; and secret-sync on aws                                                                |
| **Namespace**  | `dex`                                                                                                            |
| **Chart**      | [`dex`](https://oss.bitwisemedia.uk/flux-containers/charts/dex/), range `DEX_SEMVER` (default `<1.0.0 >=0.24.0`) |
| **Image**      | tracked independently, range `DEX_IMAGE_SEMVER` (default `<3.0.0 >=2.44.0`)                                      |
| **Timeout**    | 5m                                                                                                               |
| **Host**       | `dex.${PLATFORM_DOMAIN}` (the issuer)                                                                            |

## What it deploys

**Common tier:**

- **Two input providers**, the chart and the mirrored `ghcr.io/dexidp/dex` image, joined with `Permute`. The chart's
  `appVersion` lags dex image releases by months, so the mirror tracks the image on its own train and the ResourceSet
  feeds the pick into `image.tag`. See [Tracked images](../concepts/chart-delivery.md#tracked-images).
- **The HelmRelease**, configured as described [below](#the-helmrelease).

**Per-cloud overlay:**

- **Namespace `dex`**, labelled `platform.bitwisemedia.uk/gateway-access: "true"` so its HTTPRoute is admitted by the
  Gateway. It rides the overlay so the namespace and the credential Secret land in the same reconcile as the release.
- **`dex-secrets` ResourceSet**: the `dex-secrets` ServiceAccount, a SecretProviderClass and a SecretSync producing the
  `dex-env` Secret, in the cloud's dialect. See [Secret sync](../concepts/secret-sync.md).

## The HelmRelease

- **Issuer** `https://dex.${PLATFORM_DOMAIN}`, served through the platform Gateway by the chart's own HTTPRoute
  (`parentRefs: gateway/platform`).
- **Storage** `kubernetes` (CRD-backed, in-cluster): no database to run, and state survives restarts.
- **`skipApprovalScreen: true`**: the relying parties are first-party, and a consent screen between two internal pages
  is friction.
- **Connectors**, one per `DEX_CONNECTORS` entry (`{id, type, name, config}`), with `config` rendered as single-line
  JSON so real types survive.
- **Static clients**, one per `DEX_CLIENTS` entry (`{id, name, public, redirectURIs}`). A confidential client reads its
  secret from `secretEnv: DEX_CLIENT_<ID>`; a public client (authorization code + PKCE, for kubectl or a CLI) has none,
  and with no registered redirect URIs dex accepts loopback redirects on any port.
- **`envFrom: dex-env`**, the synced credentials Secret. dex expands `$VAR` in its config; those references are
  deliberately brace-less so Flux's substitution leaves them alone.
- **ServiceAccount `dex`**, annotated with `iam.gke.io/gcp-service-account: ${DEX_DIRECTORY_SA}` only when that variable
  is set (the annotation map is empty otherwise, never null). This lets a google connector read group membership from
  the Directory API keylessly, through Workload Identity and domain-wide delegation. The namespace/name/annotation
  triple is the contract with `dex.tf` in the cluster module.

## Credentials

The `dex-env` Secret carries two kinds of credential as environment variables:

| source container                          | env var               | created by                                                                                           |
| ----------------------------------------- | --------------------- | ---------------------------------------------------------------------------------------------------- |
| `${SECRET_PREFIX}dex-<connector>-<field>` | `<CONNECTOR>_<FIELD>` | out of band, one per field a connector lists in its `secrets` (an OAuth client can't be terraformed) |
| `${SECRET_PREFIX}dex-client-<id>`         | `DEX_CLIENT_<ID>`     | terraform, one per confidential `DEX_CLIENTS` entry (an ephemeral random, write-only)                |

The sync is a template over the same two lists, so it references only containers that were declared. A reference to a
container that doesn't exist would wedge the whole sync. With nothing declared, the sync's `data` is an empty list, so
an elected dex without SSO configured is still valid.

Each client's consumer syncs the same `dex-client-<id>` container into its own namespace, so dex and the client always
agree on the secret.

## Cluster variables

`PLATFORM_DOMAIN`, `DEX_CONNECTORS`, `DEX_CLIENTS`, `SECRET_PREFIX`, `DEX_DIRECTORY_SA` (google), `GCP_PROJECT`
(google), `AWS_REGION` and `SECRETS_ROLE_PREFIX` (aws), the usual registry and signing variables, `DEX_SEMVER`,
`DEX_IMAGE_SEMVER`.

## Source

??? example "components/dex/common/input-provider.yaml"

    ```yaml
    --8<-- "components/dex/common/input-provider.yaml"
    ```

??? example "components/dex/common/resourceset.yaml"

    ```yaml
    --8<-- "components/dex/common/resourceset.yaml"
    ```

=== "aws secret sync"

    ```yaml
    --8<-- "components/dex/aws/resourceset-secrets.yaml"
    ```

=== "google secret sync"

    ```yaml
    --8<-- "components/dex/google/resourceset-secrets.yaml"
    ```
