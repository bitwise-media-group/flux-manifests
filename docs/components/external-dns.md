---
description: "Publishes every HTTPRoute host into the cluster's delegated zone, with per-cluster ownership and pruning."
---

# external-dns

[external-dns](https://kubernetes-sigs.github.io/external-dns/) publishes a DNS record for every HTTPRoute host on the
platform [Gateway](gateway.md), platform and application hosts alike, into the cluster's delegated zone. Records are
owned per cluster and pruned when routes go away, which is what lets a destroyed and recreated cluster land on the same
domain with no manual DNS work.

|                |                                                                                                                                             |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| **Tier**       | core                                                                                                                                        |
| **Clouds**     | aws, google (one overlay per cloud)                                                                                                         |
| **Depends on** | kyverno-policies                                                                                                                            |
| **Namespace**  | `external-dns`                                                                                                                              |
| **Chart**      | [`external-dns`](https://oss.bitwisemedia.uk/flux-containers/charts/external-dns/), range `EXTERNAL_DNS_SEMVER` (default `<2.0.0 >=1.15.0`) |
| **Image**      | tracked independently, range `EXTERNAL_DNS_IMAGE_SEMVER` (default `<1.0.0 >=0.21.0`)                                                        |
| **Timeout**    | 5m                                                                                                                                          |

## What it deploys

- **Two input providers**: the chart, and the mirrored `registry.k8s.io/external-dns/external-dns` image, which the
  mirror tracks on its own release train so a fixed image ships without waiting for a chart release. The ResourceSet
  joins them with `Permute` and feeds the image pick into `image.tag`. See
  [Tracked images](../concepts/chart-delivery.md#tracked-images).
- **One HelmRelease per zone flavour**, reading `service` and `gateway-httproute` sources, with `policy: sync` (not
  upsert-only) so records for deleted routes are removed, and `domainFilters: [${DNS_DOMAIN}]`.

=== "aws"

    - **`external-dns-public`** always: `--zone-id-filter=${DNS_PUBLIC_ZONE_ID}` and `--aws-zone-type=public`, owner
      `${CLUSTER_NAME}-public`. The public zone always exists, because cert-manager's DNS-01 needs it even on a fully
      internal cluster.
    - **`external-dns-private`** when `DNS_PRIVATE_ZONE_ID` is set (split-horizon): the same records into the private
      zone, owner `${CLUSTER_NAME}-private`. It reuses the public release's ServiceAccount.
    - `AWS_DEFAULT_REGION` is set from `AWS_REGION`: Pod Identity provides credentials but not a region.

    Why two releases rather than one with both zones: the AWS provider flattens every matched zone into one record view
    before planning, so a record present in either zone reads as present in both, and the missing copy is never
    created. Each instance must see exactly one zone. The zone-type filter backs up the id filter so the two can never
    cross streams. (The chart has no `zoneIdFilters` value, which is a Bitnami chart name; filters ride in `extraArgs`.)

=== "google"

    One release, `external-dns`, with `--google-project=${GCP_PROJECT}`, `--google-zone-visibility=public` and
    `--zone-id-filter=${DNS_ZONE_NAME}`, owner `${CLUSTER_NAME}`.

## Identity

The `external-dns/external-dns` ServiceAccount (pinned in values) carries zone access: a direct Workload Identity grant
for `roles/dns.admin` on google, a Pod Identity association with the Route53 change/read role on aws.

## Cluster variables

`CLUSTER_NAME`, `DNS_DOMAIN`, plus `DNS_PUBLIC_ZONE_ID`, `DNS_PRIVATE_ZONE_ID`, `AWS_REGION` on aws and `GCP_PROJECT`,
`DNS_ZONE_NAME` on google; the usual registry and signing variables; `EXTERNAL_DNS_SEMVER`, `EXTERNAL_DNS_IMAGE_SEMVER`.

## Source

=== "aws"

    ```yaml
    --8<-- "components/external-dns/aws/input-provider.yaml"
    ```

    ```yaml
    --8<-- "components/external-dns/aws/resourceset.yaml"
    ```

=== "google"

    ```yaml
    --8<-- "components/external-dns/google/input-provider.yaml"
    ```

    ```yaml
    --8<-- "components/external-dns/google/resourceset.yaml"
    ```
