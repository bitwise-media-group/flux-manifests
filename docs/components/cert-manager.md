---
description:
  "Certificates from Let's Encrypt via DNS-01 with ambient cloud credentials, with the Gateway API integration on."
---

# cert-manager

[cert-manager](https://cert-manager.io) issues the platform's TLS certificates: in practice the one wildcard certificate
the [Gateway](gateway.md) terminates with. It solves DNS-01 challenges in the cluster's delegated zone with ambient
cloud credentials, so no DNS credential is ever stored in the cluster. The issuers themselves are the
[cert-manager-issuers](cert-manager-issuers.md) component.

|                |                                                                                                                                             |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| **Tier**       | core                                                                                                                                        |
| **Clouds**     | aws, google (common tier verbatim)                                                                                                          |
| **Depends on** | kyverno-policies                                                                                                                            |
| **Namespace**  | `cert-manager`                                                                                                                              |
| **Chart**      | [`cert-manager`](https://oss.bitwisemedia.uk/flux-containers/charts/cert-manager/), range `CERT_MANAGER_SEMVER` (default `<2.0.0 >=1.18.0`) |
| **Timeout**    | 10m                                                                                                                                         |

## Notable values

- **CRDs installed and kept.** `crds.enabled: true` and `crds.keep: true`: the CRDs survive a release uninstall, because
  certificates aren't disposable. CRDs are also `CreateReplace` on install and upgrade.
- **Every image mirrored**, including the ACME solver image (`acmesolver.image`) that the controller launches solver
  pods from. flux-containers mirrors it through the chart's `images.extra`.
- **Gateway API integration on.** `config.enableGatewayAPI: true`: cert-manager watches Gateways and can issue into
  listener secrets.
- **Public resolvers for DNS-01 self-checks.** `--dns01-recursive-nameservers-only` with `8.8.8.8:53,1.1.1.1:53`. The
  VPC-internal resolver would answer for private (split-horizon) zones and mask whether the public record has
  propagated.
- **Pinned ServiceAccount** `cert-manager`, and the system pool for the controller, webhook and cainjector.

## Identity

The `cert-manager/cert-manager` ServiceAccount carries the DNS permissions: a direct Workload Identity grant for
`roles/dns.admin` on google, a Pod Identity association with the Route53 change/read role on aws. Both are created by
terraform. No annotation is needed in the values.

## Cluster variables

`PLATFORM_REGISTRY`, `CONTAINER_REGISTRY`, `ARTIFACT_TAG_PROVIDER`, `OCI_PROVIDER`, `SIGNED_IDENTITY_*`,
`COSIGN_PUBLIC_KEY`, `CERT_MANAGER_SEMVER`.

## Source

??? example "components/cert-manager/common/input-provider.yaml"

    ```yaml
    --8<-- "components/cert-manager/common/input-provider.yaml"
    ```

??? example "components/cert-manager/common/resourceset.yaml"

    ```yaml
    --8<-- "components/cert-manager/common/resourceset.yaml"
    ```
