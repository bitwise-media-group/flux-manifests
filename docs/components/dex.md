---
description:
  "The platform's OIDC identity provider: data-driven connectors, platform clients from the cloud and application
  clients from DexClient objects."
---

# dex

[Dex](https://dexidp.io) is the platform's OpenID Connect identity provider. The Flux status UI, kubectl and any
application that ships a `DexClient` sign people in through it. It's entirely data-driven: the upstream connectors and
the platform's own clients arrive as JSON cluster variables, and applications register their clients as `DexClient`
objects in their own namespaces, which [dex-client-controller](#dex-client-controller) reconciles into dex. dex never
learns an application's name.

|                |                                                                                                                                                          |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Tier**       | electable, included by the cluster module exactly when its `sso` toggle is on                                                                            |
| **Clouds**     | aws, google (common tier + per-cloud secret sync)                                                                                                        |
| **Depends on** | kyverno-policies, cert-manager, gateway; and secret-sync on aws                                                                                          |
| **Namespace**  | `dex`                                                                                                                                                    |
| **Chart**      | [`dex`](https://oss.bitwisemedia.uk/flux-containers/charts/dex/), range `DEX_SEMVER` (default `<1.0.0 >=0.24.0`)                                         |
| **Image**      | tracked independently, range `DEX_IMAGE_SEMVER` (default `<3.0.0 >=2.44.0`)                                                                              |
| **Controller** | [`dex-client-controller`](https://oss.bitwisemedia.uk/dex-client-controller/) from ghcr, range `DEX_CLIENT_CONTROLLER_SEMVER` (default `<0.2.0 >=0.1.0`) |
| **Timeout**    | 5m                                                                                                                                                       |
| **Host**       | `dex.${PLATFORM_DOMAIN}` (the issuer)                                                                                                                    |

## What it deploys

**Common tier:**

- **Two input providers**, the chart and the mirrored `ghcr.io/dexidp/dex` image, joined with `Permute`. The chart's
  `appVersion` lags dex image releases by months, so the mirror tracks the image on its own train and the ResourceSet
  feeds the pick into `image.tag`. See [Tracked images](../concepts/chart-delivery.md#tracked-images).
- **The HelmRelease**, configured as described [below](#the-helmrelease).
- **The gRPC PKI** (`pki.yaml`): a self-signed root behind a namespaced CA Issuer `dex-grpc`, signing dex's serving
  certificate and the controller's client certificate. See [The gRPC API](#the-grpc-api).
- **dex-client-controller**: its own input provider over ghcr, a ResourceSet with the verified OCIRepository and
  HelmRelease, the image exception and policy, and the `restrict-dex-resources` policy. See
  [dex-client-controller](#dex-client-controller).

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
- **Static clients**, one per `DEX_CLIENTS` entry (`{id, name, public, redirectURIs}`): the platform's own (`flux-web`,
  kubectl), never an application's. A confidential client reads its secret from `secretEnv: DEX_CLIENT_<ID>`; a public
  client (authorization code + PKCE, for kubectl or a CLI) has none, and with no registered redirect URIs dex accepts
  loopback redirects on any port.
- **`envFrom: dex-env`**, the synced credentials Secret. dex expands `$VAR` in its config; those references are
  deliberately brace-less so Flux's substitution leaves them alone.
- **ServiceAccount `dex`**, annotated with `iam.gke.io/gcp-service-account: ${DEX_DIRECTORY_SA}` only when that variable
  is set (the annotation map is empty otherwise, never null). This lets a google connector read group membership from
  the Directory API keylessly, through Workload Identity and domain-wide delegation. The namespace/name/annotation
  triple is the contract with `dex.tf` in the cluster module.
- **The gRPC API** on port 5557, behind mutual TLS. See below.

## The gRPC API

dex-client-controller drives dex through its gRPC API, which has no authentication beyond TLS client certificates:
whoever holds a certificate dex's `tlsClientCA` trusts administers every client and connector. So the CA is local to the
`dex` namespace. A self-signed root (`dex-grpc-ca`) backs a namespaced CA Issuer (`dex-grpc`) that only objects in `dex`
can reference, and it signs exactly two leaves: dex's serving certificate (`dex-grpc`, for `dex.dex.svc` and
`dex.dex.svc.cluster.local`) and the controller's client certificate (`dex-client-controller-dex-tls`). Each Secret
carries the root as `ca.crt`, which is all either side needs to verify the other.

The `dex-grpc` Secret is mounted at `/etc/dex/grpc`, and `config.grpc` points `tlsCert`, `tlsKey` and `tlsClientCA` at
it. dex reloads those files when the Secret changes and the controller re-reads its own on reconnect, so cert-manager's
renewals need no restarts. This is why dex depends on cert-manager.

## dex-client-controller

[dex-client-controller](https://oss.bitwisemedia.uk/dex-client-controller/) reconciles namespaced `DexClient` objects
into dex through the gRPC API. An application ships a `DexClient` in its own manifest image, and the controller
registers the client and writes its credentials to a Secret beside it (`<name>-dex-client` by default, keys `clientID`,
`clientSecret` and `issuer`). No terraform, no cloud secret and no dex restart are involved. See
[An identity](../applications.md#an-identity) for the recipe.

- **First-party, straight from ghcr.** The chart is listed and pulled from ghcr (`OCIArtifactTag`, `provider: generic`)
  rather than mirrored, and verified keylessly against the controller repository's own release identity on every
  cluster, KMS-keyed or not. The release runs the chart's default image. See
  [First-party charts](../concepts/chart-delivery.md#first-party-charts).
- **Its own image signer.** The controller image is signed by the shared release workflow, not the platform pipeline, so
  the component ships the application pattern: a `PolicyException` in `kyverno` exempting only the
  `dex-client-controller-*` pods in `dex` from `verify-platform-signature`, and the
  `verify-dex-client-controller-signature` ClusterPolicy verifying those same pods' image against its own identity and
  admitting no other image into them. dex's own pods stay under the platform rule.
- **Values**: `dex.address: dex.dex.svc.cluster.local:5557`, `dex.issuer: https://dex.${PLATFORM_DOMAIN}` (written into
  every generated Secret), the CRDs installed and kept on uninstall, DexClient write access aggregated into the built-in
  `edit` and `admin` roles, and the system node pool. The release depends on the dex HelmRelease.
- **Platform clients stay static.** Static clients are read-only through dex's API, so no `DexClient` can take over
  `flux-web` or kubectl.

The `restrict-dex-resources` ClusterPolicy closes what RBAC can't. A `DexClient`'s `spec.clientID` must be omitted (the
controller then uses `<namespace>-<name>`) or start with `<namespace>-`, so client IDs are partitioned by namespace and
no application can claim another's. `DexConnector` objects are admitted only in `dex`: connectors stay platform-owned,
set through `DEX_CONNECTORS`. It's enforced from the start rather than following `KYVERNO_FAILURE_ACTION`, since a soak
would leave the takeover open. It rides a ResourceSet that waits for both CRDs, because kyverno rejects a policy for a
kind it can't resolve.

## Credentials

The `dex-env` Secret carries two kinds of credential as environment variables:

| source container                          | env var               | created by                                                                                           |
| ----------------------------------------- | --------------------- | ---------------------------------------------------------------------------------------------------- |
| `${SECRET_PREFIX}dex-<connector>-<field>` | `<CONNECTOR>_<FIELD>` | out of band, one per field a connector lists in its `secrets` (an OAuth client can't be terraformed) |
| `${SECRET_PREFIX}dex-client-<id>`         | `DEX_CLIENT_<ID>`     | terraform, one per confidential platform client in `DEX_CLIENTS` (an ephemeral random, write-only)   |

The sync is a template over the same two lists, so it references only containers that were declared. A reference to a
container that doesn't exist would wedge the whole sync. With nothing declared, the sync's `data` is an empty list, so
an elected dex without SSO configured is still valid.

Each platform client's consumer syncs the same `dex-client-<id>` container into its own namespace, so dex and the client
always agree on the secret. Application clients never pass through here: the controller generates their secrets and
keeps them in the application's namespace.

## Cluster variables

`PLATFORM_DOMAIN`, `DEX_CONNECTORS`, `DEX_CLIENTS`, `SECRET_PREFIX`, `DEX_DIRECTORY_SA` (google), `GCP_PROJECT`
(google), `AWS_REGION` and `SECRETS_ROLE_PREFIX` (aws), the usual registry and signing variables, `DEX_SEMVER`,
`DEX_IMAGE_SEMVER`, `DEX_CLIENT_CONTROLLER_SEMVER`, `KYVERNO_FAILURE_ACTION` (the controller image policy).

## Source

??? example "components/dex/common/input-provider.yaml"

    ```yaml
    --8<-- "components/dex/common/input-provider.yaml"
    ```

??? example "components/dex/common/resourceset.yaml"

    ```yaml
    --8<-- "components/dex/common/resourceset.yaml"
    ```

??? example "components/dex/common/pki.yaml"

    ```yaml
    --8<-- "components/dex/common/pki.yaml"
    ```

??? example "components/dex/common/resourceset-client-controller.yaml"

    ```yaml
    --8<-- "components/dex/common/resourceset-client-controller.yaml"
    ```

??? example "components/dex/common/policy-client-controller.yaml"

    ```yaml
    --8<-- "components/dex/common/policy-client-controller.yaml"
    ```

??? example "components/dex/common/resourceset-policy.yaml"

    ```yaml
    --8<-- "components/dex/common/resourceset-policy.yaml"
    ```

=== "aws secret sync"

    ```yaml
    --8<-- "components/dex/aws/resourceset-secrets.yaml"
    ```

=== "google secret sync"

    ```yaml
    --8<-- "components/dex/google/resourceset-secrets.yaml"
    ```
