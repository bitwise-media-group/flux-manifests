---
description: "Let's Encrypt production and staging ClusterIssuers, solving DNS-01 in Route53 or Cloud DNS."
---

# cert-manager-issuers

The Let's Encrypt ClusterIssuers [cert-manager](cert-manager.md) issues from. They're a separate component because they
need cert-manager's CRDs and webhook to exist first.

|                |                                  |
| -------------- | -------------------------------- |
| **Tier**       | core                             |
| **Clouds**     | aws, google (one file per cloud) |
| **Depends on** | cert-manager                     |
| **Namespace**  | cluster-scoped                   |
| **Chart**      | none                             |

## What it deploys

Two ClusterIssuers, identical apart from the ACME server:

| issuer                | ACME server              | use                                                       |
| --------------------- | ------------------------ | --------------------------------------------------------- |
| `letsencrypt-prod`    | Let's Encrypt production | the platform wildcard certificate and anything else real  |
| `letsencrypt-staging` | Let's Encrypt staging    | debugging issuance without burning production rate limits |

Both register with `ACME_EMAIL` and solve **DNS-01**, the only challenge that can prove a wildcard. There's no
credential `secretRef`: ClusterIssuers may use ambient credentials, and the cert-manager controller's cloud identity
carries the DNS permissions.

=== "aws"

    The solver is `route53` in `AWS_REGION`, pinned to `hostedZoneID: ${DNS_PUBLIC_ZONE_ID}`, the **public** zone.
    Let's Encrypt resolves the challenge over public DNS, so under split-horizon the record must land in the public
    zone, never the private one shadowing it inside the VPC. A cluster with only a private zone can't satisfy DNS-01 at
    all, and the empty zone id failing the render is the intended outcome there.

=== "google"

    The solver is `cloudDNS` in `GCP_PROJECT`.

## Cluster variables

`ACME_EMAIL`, plus `AWS_REGION` and `DNS_PUBLIC_ZONE_ID` on aws, `GCP_PROJECT` on google.

## Source

=== "aws"

    ```yaml
    --8<-- "components/cert-manager-issuers/aws/cluster-issuers.yaml"
    ```

=== "google"

    ```yaml
    --8<-- "components/cert-manager-issuers/google/cluster-issuers.yaml"
    ```
