---
description:
  "Prometheus, Alertmanager and Grafana through the Prometheus Operator, with cluster rules, alerts and dashboards."
---

# kube-prometheus-stack

[kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
installs the Prometheus Operator and its CRDs, one Prometheus, one Alertmanager, Grafana, kube-state-metrics and
node-exporter, plus the upstream recording rules, alerts and dashboards for the cluster itself. Prometheus watches every
namespace, so applications bring their own monitors. With dex elected, Grafana is published at `grafana.<domain>` behind
SSO.

|                |                                                                                                                                                                         |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Tier**       | electable                                                                                                                                                               |
| **Clouds**     | aws, google (common tier plus a per-cloud values ConfigMap)                                                                                                             |
| **Depends on** | kyverno-policies, cert-manager; gateway and dex while dex is elected                                                                                                    |
| **Namespace**  | `monitoring`                                                                                                                                                            |
| **Chart**      | [`kube-prometheus-stack`](https://oss.bitwisemedia.uk/flux-containers/charts/kube-prometheus-stack/), range `KUBE_PROMETHEUS_STACK_SEMVER` (default `<94.0.0 >=93.2.2`) |
| **Timeout**    | 10m                                                                                                                                                                     |

## Notable values

- **Every namespace's monitors.** The `*SelectorNilUsesHelmValues: false` settings make Prometheus select every
  `ServiceMonitor`, `PodMonitor`, `Probe`, `ScrapeConfig` and `PrometheusRule` in the cluster, not only those carrying
  this release's label. An application ships its monitors beside its workloads, and the platform never names it. See
  [Applications](../applications.md#monitoring).
- **No control-plane scrapes.** EKS and GKE expose no controller-manager, scheduler or etcd endpoints, and neither cloud
  runs a scrapeable kube-proxy (cilium replaces it on aws, Dataplane V2 on google). Those scrapes are off, and the chart
  drops their alerts with them, so nothing fires for a target that can't exist.
- **DNS differs per cloud.** EKS runs CoreDNS and GKE runs kube-dns, which serve metrics on different ports. Each
  overlay ships a `kube-prometheus-stack-cloud` ConfigMap that turns on the matching scrape, and the HelmRelease reads
  it through `valuesFrom`. The ConfigMap carries the `reconcile.fluxcd.io/watch` label, so a change reconciles the
  release straight away.
- **Webhook certificates from cert-manager.** The operator's admission webhook certificate comes from a self-signed
  `Issuer` the chart creates in `monitoring`, rather than the `kube-webhook-certgen` hook jobs. That's why it depends on
  cert-manager, and why the mirror doesn't carry the certgen image.
- **CRDs `CreateReplace`**, so the prometheus-operator CRDs always match the operator the chart runs.
- **One injected image.** The operator adds `prometheus-config-reloader` to every Prometheus and Alertmanager pod. Its
  registry is overridden like every other image, and the mirror carries it as an extra image.
- **Ephemeral by default.** With `KUBE_PROMETHEUS_STACK_STORAGE_SIZE` unset, Prometheus keeps its 10-day TSDB in an
  `emptyDir` and loses it whenever the pod moves. A default StorageClass isn't guaranteed (the EBS CSI driver is an
  optional add-on on aws), so a claim is only rendered when you ask for one. Set the variable to a size such as `50Gi`
  to get a `PersistentVolumeClaim` from the cluster's default StorageClass.
- **Alertmanager routes nowhere yet.** It runs with the chart's default config, which sends every alert to a `null`
  receiver. Alerts show in the Alertmanager UI but notify no one.
- **Placement.** Everything but node-exporter runs on the system pool. node-exporter is a DaemonSet with no
  `nodeSelector`, and the subchart tolerates every `NoSchedule` taint, so it reaches every node, Karpenter's included.

## Grafana

With dex elected, Grafana is published at `https://grafana.${PLATFORM_DOMAIN}` and signs people in through dex. Without
dex there's no route at all, so Grafana is never exposed behind its local login alone. Reach it with
`kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80` instead.

- **A DexClient, like any application.** The component ships a `DexClient` named `grafana` in `monitoring`, so its
  client ID is `monitoring-grafana`. [dex-client-controller](dex.md#dex-client-controller) writes the credentials to the
  `grafana-dex-client` Secret, and Grafana reads them as `GF_AUTH_GENERIC_OAUTH_*` environment variables, so they never
  appear in its rendered config. See [An identity](../applications.md#an-identity).
- **Roles follow the platform's groups.** dex resolves the same group names the [rbac](rbac.md) component binds.
  `RBAC_GROUP_ADMINS` becomes Grafana Admin (server admin), `RBAC_GROUP_DEVOPS` Editor, and `RBAC_GROUP_DEVELOPERS` and
  `RBAC_GROUP_VIEWERS` Viewer. `role_attribute_strict` refuses anyone in none of them rather than defaulting them to
  Viewer.
- **SSO is the front door.** `oauth_auto_login` sends visitors straight to dex. The chart-generated admin password in
  the `kube-prometheus-stack-grafana` Secret is the break-glass login, at `/login?disableAutoLogin=true` or through a
  port-forward.
- **The edge.** The `monitoring` namespace carries the `gateway-access` label, so the route attaches to the platform
  Gateway by hostname, the wildcard certificate covers it and external-dns publishes the record. On google, a
  `HealthCheckPolicy` points the load balancer at `/api/health`, because Grafana answers `/` with a redirect to its
  login page and the NEG would otherwise never go healthy.
- **The graph follows the election.** While dex is elected, the entrypoint adds `gateway` and `dex` to this component's
  dependencies, so the route has a Gateway and the `DexClient` kind exists before anything renders. Without dex, they're
  left out, so nothing waits on a Kustomization that doesn't exist.

## Dashboards

Beyond the chart's own Kubernetes dashboards, Grafana carries the upstream dashboards for the platform components that
publish one. Each lands in a folder named after its component.

| folder       | dashboards                                                                                 | source                                                 | scraped by                                                    |
| ------------ | ------------------------------------------------------------------------------------------ | ------------------------------------------------------ | ------------------------------------------------------------- |
| Flux         | Flux Performance, Flux Kubernetes API Performance                                          | flux-operator's monitoring kit, vendored here          | PodMonitor `flux-controllers`, ServiceMonitor `flux-operator` |
| Kyverno      | Kyverno Metrics                                                                            | the kyverno chart (`grafana.enabled`)                  | ServiceMonitor `kyverno`                                      |
| Cilium       | Cilium Metrics, Cilium Operator (aws)                                                      | the cilium chart (`dashboards`, `operator.dashboards`) | PodMonitors `cilium-agent`, `cilium-operator`                 |
| Hubble (aws) | Hubble Metrics and Monitoring, DNS Overview, Network Overview, L7 HTTP Metrics by Workload | the cilium chart (`hubble.metrics.dashboards`)         | PodMonitor `cilium-agent` (its `hubble-metrics` port)         |
| Karpenter    | Karpenter Capacity v1, Karpenter Performance v1 (aws)                                      | Karpenter's getting-started dashboards, vendored here  | ServiceMonitor `karpenter`                                    |

- **The sidecar, not grafana-operator.** The Grafana subchart's `k8s-sidecar` loads every ConfigMap labelled
  `grafana_dashboard` in any namespace, and files it under the folder its `grafana_folder` annotation names. That's the
  format kyverno and cilium already ship, so their dashboards stay versioned with their charts. grafana-operator would
  add a controller, CRDs and another mirrored chart to get status conditions on dashboards, and it would want to own the
  Grafana instance. Revisit it if alerting, contact points or teams need managing as code too.
- **Charts first, vendored otherwise.** kyverno and cilium render their dashboards from their own charts, as inert
  ConfigMaps on a cluster without Grafana. Flux and Karpenter publish theirs as JSON in their repositories, so
  `scripts/vendor-dashboards.sh` pins them to the version the platform runs and this component ships them as ConfigMaps.
  See [Operations](../reference/operations.md#refreshing-the-vendored-dashboards).
- **No `${…}` in vendored JSON.** Grafana reads `$var` and `${var}` alike, but Flux's post-build substitution rewrites
  the braced form. The vendoring script rewrites every braced variable to its bare form, and the ConfigMaps carry
  `kustomize.toolkit.fluxcd.io/substitute: disabled` as well.
- **Monitors live here.** The components install before this one, so a chart-rendered `ServiceMonitor` would find no CRD
  on a fresh cluster. The `platform-monitors` ResourceSet (and `platform-monitors-aws` on aws) waits for the
  `monitoring.coreos.com` CRDs instead. The monitors add the labels the dashboards filter on: a `cluster` label for
  kyverno's and the cilium and Hubble scrapes, and `k8s_app` and `io_cilium_app` from the cilium pods.
- **Not every component has one.** cert-manager, external-dns, dex, the load balancer controller and secret-sync publish
  no upstream dashboard. ARC publishes a sample its maintainers say they won't keep up to date, and it depends on
  listener metrics each application's scale set configures, so it isn't shipped.

## Provenance

The prometheus-operator images are keyless-signed by their release workflow, and kube-state-metrics by the Kubernetes
release promoter. The chart, Prometheus, Alertmanager, node-exporter, Grafana and the dashboard sidecar are published
unsigned. For those, the mirror's signature, verified here and by the admission policy, is the first provenance they
get. See the [mirror page](https://oss.bitwisemedia.uk/flux-containers/charts/kube-prometheus-stack/).

## Cluster variables

`PLATFORM_COMPONENTS` (to elect it, and whether dex is elected), `KUBE_PROMETHEUS_STACK_SEMVER`,
`KUBE_PROMETHEUS_STACK_STORAGE_SIZE` (optional), `PLATFORM_DOMAIN` (the Grafana host and dex endpoints), the
`RBAC_GROUP_*` variables (Grafana roles), `CLUSTER_NAME` (the kyverno scrape's `cluster` label), `KARPENTER_NAMESPACE`
(aws, the karpenter scrape), the usual registry and signing variables.

## Source

??? example "components/kube-prometheus-stack/common/input-provider.yaml"

    ```yaml
    --8<-- "components/kube-prometheus-stack/common/input-provider.yaml"
    ```

??? example "components/kube-prometheus-stack/common/resourceset.yaml"

    ```yaml
    --8<-- "components/kube-prometheus-stack/common/resourceset.yaml"
    ```

??? example "components/kube-prometheus-stack/aws/values-cloud.yaml"

    ```yaml
    --8<-- "components/kube-prometheus-stack/aws/values-cloud.yaml"
    ```

??? example "components/kube-prometheus-stack/google/values-cloud.yaml"

    ```yaml
    --8<-- "components/kube-prometheus-stack/google/values-cloud.yaml"
    ```

??? example "components/kube-prometheus-stack/google/health-check.yaml"

    ```yaml
    --8<-- "components/kube-prometheus-stack/google/health-check.yaml"
    ```

??? example "components/kube-prometheus-stack/common/resourceset-monitors.yaml"

    ```yaml
    --8<-- "components/kube-prometheus-stack/common/resourceset-monitors.yaml"
    ```

??? example "components/kube-prometheus-stack/aws/resourceset-monitors-aws.yaml"

    ```yaml
    --8<-- "components/kube-prometheus-stack/aws/resourceset-monitors-aws.yaml"
    ```
