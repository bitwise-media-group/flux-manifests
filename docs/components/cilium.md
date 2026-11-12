---
description:
  "Cilium managing Cilium on EKS: adopts terraform's bootstrap release and turns on its Gateway API controller."
---

# cilium

Cilium is the CNI on aws clusters, and the implementation behind the platform [Gateway](gateway.md) there. terraform
installs it once to bootstrap the cluster (a `helm_release` with `ignore_changes = all`); this component adopts that
release by name, so from then on the chart version follows the mirror like every other component.

|                |                                                                                                                           |
| -------------- | ------------------------------------------------------------------------------------------------------------------------- |
| **Tier**       | core                                                                                                                      |
| **Clouds**     | aws only (GKE ships Dataplane V2)                                                                                         |
| **Depends on** | `gateway-api-crds`, while `GATEWAY_API_CRDS` is `true`                                                                    |
| **Namespace**  | `kube-system`                                                                                                             |
| **Chart**      | [`cilium`](https://oss.bitwisemedia.uk/flux-containers/charts/cilium/), range `CILIUM_SEMVER` (default `<2.0.0 >=1.20.1`) |
| **Timeout**    | 15m                                                                                                                       |

## What it deploys

The chart's input provider, OCIRepository and a HelmRelease named `cilium` in `kube-system`, matching terraform's
bootstrap release so helm-controller takes over its storage instead of installing a second copy.

The values reproduce terraform's `local.cilium_values` verbatim, so the hand-off changes nothing on the wire:

- ENI IPAM (`ipam.mode: eni`, `eni.enabled`, `eni.subnetIDsFilter: ${CILIUM_POD_SUBNET_IDS}`), native routing, and
  `egressMasqueradeInterfaces: eth+`.
- Kube-proxy replacement, with `k8sServiceHost: ${CILIUM_K8S_SERVICE_HOST}` (the EKS API endpoint) on port 443.
- `gatewayAPI.enabled: true`, the reason this component exists.
- `nodeinit` on, one operator replica.

## Metrics and dashboards

`prometheus.enabled` serves the agent's metrics on each pod's `prometheus` port (9962, a hostPort); the operator's are
on by default. `dashboards` and `operator.dashboards` render the chart's agent and operator dashboards as
`grafana_dashboard` ConfigMaps in `kube-system`, filed under the Cilium folder. Both stay inert unless
[kube-prometheus-stack](kube-prometheus-stack.md#dashboards) is elected, which scrapes them. Its scrape can't come from
the chart, because cilium installs long before the `monitoring.coreos.com` CRDs exist.

## Hubble

Hubble records every flow the agents see. The component turns on three parts of it:

- **Flow metrics.** `hubble.metrics.enabled` serves DNS, drop, TCP, flow, ICMP, port-distribution and HTTP metrics on
  each agent's `hubble-metrics` port (9965, a hostPort). Their contexts are the labels the chart's four Hubble
  dashboards group by: source and destination workload (or reserved identity, for world and host traffic) and namespace.
  Per-IP labels are left out; the dashboards never use them and they're the cardinality risk. HTTP metrics only appear
  for traffic under an L7 policy, so the L7 dashboard stays empty until an application opts in.
- **Dashboards.** `hubble.metrics.dashboards` renders the overview, DNS, network and L7 HTTP dashboards into the Hubble
  folder, scraped and shown by [kube-prometheus-stack](kube-prometheus-stack.md#dashboards) where it's elected.
- **The relay and UI.** `hubble.relay` aggregates every agent's flows and `hubble.ui` renders them as a service map.
  Unlike the agent, operator and Envoy, which still run terraform's bootstrap values verbatim and pull from quay.io,
  these are new workloads, so they run the mirrored images (the chart pins them by digest, which the mirror preserves).
  They run on the system pool.

The UI has no login and shows every flow in every namespace, so the `hubble-ui` NetworkPolicy admits only
[auth-proxy](auth-proxy.md#the-hubble-upstream)'s proxies, which publish it at `hubble.${PLATFORM_DOMAIN}` to admins and
devops. Without auth-proxy elected, reach it with `kubectl -n kube-system port-forward svc/hubble-ui 12000:80`;
port-forwarding enters the pod through the kubelet, which the NetworkPolicy doesn't filter.

## The Gateway API CRDs ordering problem

EKS ships no `gateway.networking.k8s.io` CRDs, so the [gateway](gateway.md) component installs them on aws. But Cilium
only turns on its Gateway API controller if the CRDs exist when the agent and operator start, and on a fresh cluster
terraform's Cilium release starts first.

Two things close the gap:

- **On bootstrap**, the entrypoint makes `cilium` depend on `gateway-api-crds` while `GATEWAY_API_CRDS` holds, so the
  first-ever Flux reconcile of the adopted release (which rolls the pods) lands only after the CRDs are established.
- **On every later CRD bump**, `operator.podAnnotations` and `podAnnotations` carry
  `patchy.bitwisemedia.uk/gateway-api-crds-version`, kept in lockstep with the vendored CRDs' version in
  `components/gateway/aws/crds/kustomization.yaml`. Changing it forces a rollout, so agent and operator re-check for the
  CRDs.

When AWS ships the CRDs natively, the cluster module's `gateway.install_crds` toggle turns `GATEWAY_API_CRDS` off and
the dependency disappears with it.

## Before pointing an existing cluster at it

!!! warning

    The first reconcile jumps straight to the newest mirrored tag in range. On a cluster whose terraform-installed
    Cilium predates this component:

    - Confirm the live version is inside the range (`helm get metadata cilium -n kube-system`), or raise the floor with
      `CILIUM_SEMVER` first.
    - Confirm the cluster's terraform sets no `var.cilium.helm_values` overrides (`helm get values cilium -n
      kube-system`). They're deliberately not reproduced here, and the first reconcile would silently remove them.

## Cluster variables

`CILIUM_K8S_SERVICE_HOST`, `CILIUM_POD_SUBNET_IDS`, `GATEWAY_API_CRDS` (in the entrypoint), `PLATFORM_REGISTRY`,
`ARTIFACT_TAG_PROVIDER`, `OCI_PROVIDER`, `SIGNED_IDENTITY_*`, `COSIGN_PUBLIC_KEY`, `CILIUM_SEMVER`.

## Source

??? example "components/cilium/aws/input-provider.yaml"

    ```yaml
    --8<-- "components/cilium/aws/input-provider.yaml"
    ```

??? example "components/cilium/aws/resourceset.yaml"

    ```yaml
    --8<-- "components/cilium/aws/resourceset.yaml"
    ```

??? example "components/cilium/aws/network-policy-hubble-ui.yaml"

    ```yaml
    --8<-- "components/cilium/aws/network-policy-hubble-ui.yaml"
    ```
