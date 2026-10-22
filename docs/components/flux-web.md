---
description:
  "The Flux status UI behind dex SSO: its Web Config sync, the flux. HTTPRoute and the edge admission policy."
---

# flux-web

The Flux status web UI is served by flux-operator itself. This component is everything that puts it on the platform edge
behind single sign-on: the Web Config Secret that configures SSO, the `flux.` HTTPRoute, the network policy that admits
the Gateway's traffic, and the label that lets `flux-system` attach routes to the Gateway.

|                |                                                                   |
| -------------- | ----------------------------------------------------------------- |
| **Tier**       | electable; also requires `dex` to be elected                      |
| **Clouds**     | aws, google (common tier + per-cloud overlay)                     |
| **Depends on** | gateway, dex; and secret-sync on aws                              |
| **Namespace**  | `flux-system`                                                     |
| **Chart**      | none (the UI is part of the [flux](flux.md) component's operator) |
| **Timeout**    | 5m                                                                |
| **Host**       | `flux.${PLATFORM_DOMAIN}`                                         |

## What it deploys

**Common tier:**

- **HTTPRoute `flux-web`**: `flux.${PLATFORM_DOMAIN}` through `gateway/platform` to the `flux-operator` Service on
  port 9080. It lives here rather than in the operator's values because terraform bootstraps the operator before the
  Gateway exists; the platform owns everything that depends on its edge.
- **Namespace `flux-system`**, adopted through server-side apply purely to add the `gateway-access` label.

**Per-cloud overlay:**

- **ServiceAccount `flux-web-secrets`**, the identity the sync runs as (IRSA-annotated on aws, a direct Workload
  Identity grant on google). It's in the overlay rather than the core because the sync impersonates it, so it must exist
  in the same reconcile.
- **`flux-web-secrets` ResourceSet**: a SecretProviderClass and SecretSync producing `flux-system/flux-web-auth` from
  the `${SECRET_PREFIX}flux-web-auth-config` container. See [Secret sync](../concepts/secret-sync.md).
- **Edge admission**, which differs by cloud:

=== "aws"

    **CiliumNetworkPolicy `flux-web-gateway`** admitting TCP 9080 from the `ingress` entity. The chart's own
    NetworkPolicy admits 9080 from cluster namespaces only, and the Cilium Gateway's data plane is the node-local Envoy,
    whose traffic carries Cilium's reserved `ingress` identity rather than a pod's, so no Kubernetes NetworkPolicy
    selector can match it. Without this the connection times out at the edge. Kubelet probes on 8081 arrive as the
    `host` entity, which is already allowed.

=== "google"

    - **NetworkPolicy `flux-web-gfe`** admitting TCP 9080 and 8081 from the Google Front End ranges (`130.211.0.0/22`,
      `35.191.0.0/16`), which no namespace selector matches.
    - **HealthCheckPolicy `flux-web`** pointing the load balancer's health check at `/readyz` on 8081. By default it
      would probe `GET /` on 9080, the SSO-fronted UI, which doesn't answer 200 to an anonymous request. The NEG
      endpoints would never go healthy, the pods' `load-balancer-neg-ready` readiness gate would never pass, and the
      flux HelmRelease would time out waiting for the operator Deployment.

## The Web Config document

flux-operator is started with `--web-config-secret-name=flux-web-auth` (set by the [flux](flux.md) component) and
hot-reloads its Web Config from that Secret's `config.yaml` key. The operator needs the OAuth2 client secret **inline**
in that document, so terraform composes the whole `config.yaml` in the cluster root and stores it in the
`flux-web-auth-config` container, embedding an ephemeral random client secret that never lands in terraform state. dex's
`flux-web` static client reads the same random from the sibling `dex-client-flux-web` container, so the pair can't
drift.

## Un-electing it

!!! danger "Never remove the prune label from the namespace"

    Adopting `flux-system` makes this Kustomization the namespace's Flux owner. Its manifest carries
    `kustomize.toolkit.fluxcd.io/prune: disabled`, so un-electing flux-web leaves the namespace (label included) in
    place. Without that marker, un-electing flux-web would garbage-collect `flux-system` itself: the controllers, the
    FluxInstance, everything.

## Cluster variables

`PLATFORM_DOMAIN`, `SECRET_PREFIX`, `GCP_PROJECT` (google), `AWS_REGION` and `SECRETS_ROLE_PREFIX` (aws).

## Source

??? example "components/flux-web/common/httproute.yaml"

    ```yaml
    --8<-- "components/flux-web/common/httproute.yaml"
    ```

??? example "components/flux-web/common/namespace.yaml"

    ```yaml
    --8<-- "components/flux-web/common/namespace.yaml"
    ```

=== "aws"

    ```yaml
    --8<-- "components/flux-web/aws/service-accounts.yaml"
    ```

    ```yaml
    --8<-- "components/flux-web/aws/resourceset-secrets.yaml"
    ```

    ```yaml
    --8<-- "components/flux-web/aws/network-policy.yaml"
    ```

=== "google"

    ```yaml
    --8<-- "components/flux-web/google/service-accounts.yaml"
    ```

    ```yaml
    --8<-- "components/flux-web/google/resourceset-secrets.yaml"
    ```

    ```yaml
    --8<-- "components/flux-web/google/network-policy.yaml"
    ```

    ```yaml
    --8<-- "components/flux-web/google/health-check.yaml"
    ```
