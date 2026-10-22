---
description:
  "The shared platform Gateway: one wildcard HTTPS listener on terraform-reserved addresses, with its certificate."
---

# gateway

The shared platform Gateway, `gateway/platform`, that every platform and application host is served through. It has one
listener: HTTPS on `*.${PLATFORM_DOMAIN}`, terminating with a single wildcard certificate. Hosts are never enumerated
here. A component or an application gets a host by publishing an HTTPRoute for it; nothing else changes.

|                |                                     |
| -------------- | ----------------------------------- |
| **Tier**       | core                                |
| **Clouds**     | aws, google (one overlay per cloud) |
| **Depends on** | cert-manager-issuers                |
| **Namespace**  | `gateway`                           |
| **Chart**      | none                                |
| **Timeout**    | 5m                                  |

## What it deploys

- **Certificate `platform-wildcard`** for `*.${PLATFORM_DOMAIN}` from `letsencrypt-prod`, into the Secret
  `platform-tls`. It's fully declarative: on cluster recreation cert-manager re-issues into the same Secret and the
  listener serves valid TLS again with no manual step.
- **Gateway `platform`** with one listener, `https` on 443, `hostname: "*.${PLATFORM_DOMAIN}"`, terminating with
  `platform-tls`, admitting routes from any namespace labelled `platform.bitwisemedia.uk/gateway-access: "true"`.

Routes attach by hostname with no `sectionName`; the wildcard listener admits them and the wildcard certificate covers
them. [external-dns](external-dns.md) publishes the records. See [Applications](../applications.md#a-host).

=== "aws"

    - **`gatewayClassName: cilium`.** Cilium materialises a LoadBalancer Service, and the
      [AWS Load Balancer Controller](aws-load-balancer-controller.md) turns it into an NLB. The Gateway's
      `infrastructure.annotations` carry `aws-load-balancer-type: external`, the scheme (`GATEWAY_NLB_SCHEME`), the
      subnets (`GATEWAY_SUBNETS`) and the target type (`GATEWAY_NLB_TARGET_TYPE`; `instance` is all the controller
      supports off the VPC CNI).
    - **Two shapes.** Internet-facing on the public subnets, pinned to terraform-reserved Elastic IPs by
      `GATEWAY_EIP_ALLOCATIONS`; or internal on the node subnets, where EIPs can't apply. An internal NLB needs the
      EIP annotation absent, not empty, which is why the Gateway is rendered by a ResourceSet that gates it. Reachability
      for a private Gateway comes from the private zone's records (split-horizon external-dns).
    - **Gateway API CRDs.** EKS ships none, so the overlay vendors the standard channel (v1.6.1, the seven CRDs Cilium
      requires) under `crds/`. The `gateway-crds` ResourceSet emits a `gateway-api-crds` Kustomization for them while
      `GATEWAY_API_CRDS` is `true`. It reads `./aws/crds` from this component's own image (`platform-gateway`), so the
      CRDs follow the gateway's channel or pin, and it sets `prune: false`: when the toggle is switched off (AWS shipping
      the CRDs natively), the CRDs are orphaned for EKS to adopt rather than deleted, which would take every Gateway and
      HTTPRoute with them. [cilium](cilium.md) depends on that Kustomization.

=== "google"

    - **`gatewayClassName: gke-l7-global-external-managed`**: a Google-managed global external Application Load
      Balancer, with no ingress controller pods.
    - **`NamedAddress: ${GATEWAY_ADDRESS_NAME}`** attaches the terraform-reserved global static IP. Verify the accepted
      `spec.addresses.type` on the cluster's GKE version at first apply; `networking.gke.io` annotations are the
      fallback.
    - Gateway API CRDs ship with GKE.

Either way, cluster destroy and recreate converge back to the same addresses, so DNS barely blips even before
external-dns reconverges.

## Cluster variables

`PLATFORM_DOMAIN`; on aws `GATEWAY_NLB_SCHEME`, `GATEWAY_NLB_TARGET_TYPE`, `GATEWAY_SUBNETS`, `GATEWAY_EIP_ALLOCATIONS`,
`GATEWAY_API_CRDS`; on google `GATEWAY_ADDRESS_NAME`.

## Source

=== "aws"

    ```yaml
    --8<-- "components/gateway/aws/certificate.yaml"
    ```

    ```yaml
    --8<-- "components/gateway/aws/resourceset-gateway.yaml"
    ```

    ```yaml
    --8<-- "components/gateway/aws/resourceset-crds.yaml"
    ```

    ```yaml
    --8<-- "components/gateway/aws/crds/kustomization.yaml"
    ```

=== "google"

    ```yaml
    --8<-- "components/gateway/google/certificate.yaml"
    ```

    ```yaml
    --8<-- "components/gateway/google/gateway.yaml"
    ```
