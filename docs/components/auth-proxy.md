---
description:
  "dex SSO in front of web UIs with no login of their own, one oauth2-proxy per upstream, open only to named groups."
---

# auth-proxy

Some useful UIs have no login at all: anyone who can reach them sees everything. auth-proxy puts dex SSO in front of
them. Each protected upstream gets its own [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/) instance at
`<host>.${PLATFORM_DOMAIN}`, open only to the groups it names. The first upstream is the [Hubble UI](cilium.md#hubble),
on aws.

|                |                                                                                                                                            |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| **Tier**       | electable; also requires `dex`                                                                                                             |
| **Clouds**     | aws, google (common tier; upstreams per cloud, none on google yet)                                                                         |
| **Depends on** | kyverno-policies, gateway, dex                                                                                                             |
| **Namespace**  | `auth-proxy`                                                                                                                               |
| **Chart**      | [`oauth2-proxy`](https://oss.bitwisemedia.uk/flux-containers/charts/oauth2-proxy/), range `AUTH_PROXY_SEMVER` (default `<11.0.0 >=10.7.4`) |
| **Timeout**    | 5m                                                                                                                                         |

## Upstreams are data

An upstream is a `Static` `ResourceSetInputProvider` in `auth-proxy`, labelled
`auth-proxy.platform.bitwisemedia.uk/upstream: "true"`. The `auth-proxy-upstreams` ResourceSet selects every such
provider and renders one instance per provider. Most upstreams exist on one cloud only, so the overlays ship them:

| value      | meaning                                                                                     |
| ---------- | ------------------------------------------------------------------------------------------- |
| `name`     | the instance name; the release, `DexClient`, Secret and route derive from it                |
| `title`    | the name dex shows when signing in                                                          |
| `host`     | the hostname under `PLATFORM_DOMAIN`                                                        |
| `upstream` | the in-cluster URL requests are forwarded to                                                |
| `groups`   | comma-separated groups allowed in; usually `RBAC_GROUP_*` variables, and blanks are skipped |

For each upstream it renders:

- **A trigger ConfigMap**, `<name>-auth-proxy`, which kyverno mints the instance's Secret from.
- **A `DexClient`** with client ID `auth-proxy-<name>` and its `secretRef` on the minted Secret, so dex and the proxy
  share one client secret.
- **An oauth2-proxy HelmRelease** reading `client-id`, `client-secret` and `cookie-secret` from that Secret. It signs in
  through dex with PKCE, sends visitors straight there (no provider button), and admits only the upstream's groups.
  Sessions live in a sealed cookie, so the proxy is stateless and needs no Redis.
- **An HTTPRoute** at `<host>.${PLATFORM_DOMAIN}`. The `auth-proxy` namespace carries the `gateway-access` label, the
  wildcard certificate covers the host and external-dns publishes the record.

## Fail closed

With no groups, oauth2-proxy would admit anyone dex can sign in. So if every group an upstream names is unpublished (the
cluster module publishes an empty `RBAC_GROUP_*` when RBAC is off), the instance renders without its HTTPRoute and the
upstream stays unpublished. `make test` renders both cases.

## Secrets minted in the cluster

Each instance needs two random values that must stay put: the OAuth client secret it shares with dex, and the key that
seals its cookies (changing it signs everyone out). A Flux render is deterministic, so nothing in it can mint a value
once and keep it. kyverno can: the `auth-proxy-secrets` NamespacedGeneratingPolicy (Kyverno's CEL kind, confined to this
namespace) generates `<name>-auth-proxy` from the trigger ConfigMap using CEL's `random()`, and never touches it again.
Generating over an existing Secret replaces it, so the policy is built to mint once: it triggers on `CREATE` only,
synchronisation is off, and `generateExisting` catches a trigger created before the policy was admitted. That scan runs
once, when the policy is created, so deleting and recreating the policy would rotate every instance's secrets. A Role in
`auth-proxy` lets kyverno's background controller write Secrets there and nowhere else. No secret lands in git,
terraform state or a cloud secret store. To rotate one, see
[Operations](../reference/operations.md#rotating-an-auth-proxy-secret).

## The Hubble upstream

On aws, `upstream-hubble` publishes the Hubble UI at `hubble.${PLATFORM_DOMAIN}` to `RBAC_GROUP_ADMINS` and
`RBAC_GROUP_DEVOPS`. Those groups already hold cluster-wide admin or edit, and the UI shows every flow in every
namespace with no authorization of its own. The [cilium](cilium.md#hubble) component's NetworkPolicy admits only this
namespace's proxies to the UI, so the proxy is the only way in.

## Adding an upstream

Ship a `Static` provider in the overlay for each cloud the upstream exists on, with the label and the five values above.
On google, also ship a `HealthCheckPolicy` aiming the GKE load balancer at the proxy's `/ping` on port 4180, because its
`/` redirects to dex. If the upstream should accept callers only through the proxy, give it a NetworkPolicy admitting
the `auth-proxy` namespace, as cilium does for Hubble.

Upstreams are platform UIs. An application signs its own users in through its own `DexClient` instead; see
[An identity](../applications.md#an-identity).

## Provenance

The oauth2-proxy chart is keyless-signed by its release workflow. Its image is published unsigned, so the mirror's
signature, verified here and by the admission policy, is the first provenance it gets.

## Cluster variables

`PLATFORM_COMPONENTS` (to elect it, with `dex`), `AUTH_PROXY_SEMVER`, `PLATFORM_DOMAIN` (the hosts and dex issuer),
`RBAC_GROUP_ADMINS` and `RBAC_GROUP_DEVOPS` (the Hubble upstream's groups), the usual registry and signing variables.

## Source

??? example "components/auth-proxy/common/resourceset-upstreams.yaml"

    ```yaml
    --8<-- "components/auth-proxy/common/resourceset-upstreams.yaml"
    ```

??? example "components/auth-proxy/common/secrets-policy.yaml"

    ```yaml
    --8<-- "components/auth-proxy/common/secrets-policy.yaml"
    ```

??? example "components/auth-proxy/common/resourceset.yaml"

    ```yaml
    --8<-- "components/auth-proxy/common/resourceset.yaml"
    ```

??? example "components/auth-proxy/aws/upstream-hubble.yaml"

    ```yaml
    --8<-- "components/auth-proxy/aws/upstream-hubble.yaml"
    ```
