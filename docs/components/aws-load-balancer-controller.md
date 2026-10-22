---
description: "Turns the Cilium Gateway's LoadBalancer Service into an NLB on the terraform-reserved addresses (EKS)."
---

# aws-load-balancer-controller

On aws, Cilium materialises the platform [Gateway](gateway.md) as a LoadBalancer Service (`cilium-gateway-platform`) and
forwards the Gateway's infrastructure annotations to it, but ships no AWS provisioning code. The
[AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) turns that Service into
the NLB. Without it the Gateway never gets an address, and external-dns has nothing to publish.

|                |                                                                                                                                                                                            |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Tier**       | core                                                                                                                                                                                       |
| **Clouds**     | aws only (GKE's Gateway is Google-managed)                                                                                                                                                 |
| **Depends on** | kyverno-policies                                                                                                                                                                           |
| **Namespace**  | `aws-load-balancer-controller`                                                                                                                                                             |
| **Chart**      | [`aws-load-balancer-controller`](https://oss.bitwisemedia.uk/flux-containers/charts/aws-load-balancer-controller/), range `AWS_LOAD_BALANCER_CONTROLLER_SEMVER` (default `<4.0.0 >=3.5.0`) |
| **Timeout**    | 5m                                                                                                                                                                                         |

## Notable values

- **No separate image train.** The chart version is the controller version, so only the image repository is remapped to
  the mirror.
- **Region and VPC pinned.** `region: ${AWS_REGION}` and `vpcId: ${VPC_ID}`. Pod Identity hands out credentials but not
  a region, and the controller's IMDS fallback is unreliable under the hardened node metadata settings.
- **Services opt in.** `enableServiceMutatorWebhook: false`. The Gateway's annotations set
  `aws-load-balancer-type: external` explicitly; the mutator would otherwise stamp a `loadBalancerClass` on every future
  LoadBalancer Service.
- **No IngressClass.** `createIngressClassResource: false`; the platform uses Gateway API only.
- **Helm-generated webhook certificate.** `enableCertManager` stays off, so cert-manager doesn't become a hard
  dependency of the bootstrap-critical ingress path.
- **Pinned ServiceAccount** `aws-load-balancer-controller`, on the system pool.

## Identity

The `aws-load-balancer-controller/aws-load-balancer-controller` ServiceAccount has a Pod Identity association with the
controller's ELB/EC2 policy, created by terraform.

## Cluster variables

`CLUSTER_NAME`, `AWS_REGION`, `VPC_ID`, `PLATFORM_REGISTRY`, `CONTAINER_REGISTRY`, `ARTIFACT_TAG_PROVIDER`,
`OCI_PROVIDER`, `SIGNED_IDENTITY_*`, `COSIGN_PUBLIC_KEY`, `AWS_LOAD_BALANCER_CONTROLLER_SEMVER`.

## Source

??? example "components/aws-load-balancer-controller/aws/input-provider.yaml"

    ```yaml
    --8<-- "components/aws-load-balancer-controller/aws/input-provider.yaml"
    ```

??? example "components/aws-load-balancer-controller/aws/resourceset.yaml"

    ```yaml
    --8<-- "components/aws-load-balancer-controller/aws/resourceset.yaml"
    ```
