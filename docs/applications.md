# Applications

The platform knows no application by name. An application is a manifest image of its own,
`oci://<registry>/manifests/<app>`, published by the application's repository through its own path-scoped publisher. The
cluster module **seeds** it once, and from its first reconcile the application owns itself.

Everything an application needs from the platform is a contract it consumes from its own image. None of it is a branch
inside a platform component.

## The seed

The cluster module creates two objects in `flux-system`, both named `<app>-manifests` and both labelled
`kustomize.toolkit.fluxcd.io/prune: disabled`:

- a **ResourceSetInputProvider** listing the application's manifest image tags, and
- a **ResourceSet** emitting the `OCIRepository <app>-manifests` (tag and digest from the provider, cosign verify) and
  the `Kustomization <app>`: path `./deploy/<PLATFORM_TREE>`, `dependsOn` whichever platform components it names, and
  `substituteFrom` the `cluster-vars` ConfigMap plus the optional `<app>-vars` ConfigMap.

The application's image ships **the same two objects** under `flux/`, with the same names, and its
`deploy/<tree>/kustomization.yaml` includes `../../flux`. On the first reconcile the application adopts its own seed
through server-side apply, and from then on owns its version range, verify identity and dependency graph.

!!! warning "Keep the prune label on the image's copies"

    Without `kustomize.toolkit.fluxcd.io/prune: disabled` on the image's own copies, an image that dropped `flux/`
    would prune its own parent.

Removing the application from the cluster module uninstalls the seed. The ResourceSet's finalizer garbage-collects the
Kustomization, whose finalizer prunes the application.

## From its own terraform root

An application doesn't have to be declared in the cluster's root. Both cluster modules ship `modules/application`, which
publishes one application to an existing cluster from a root of its own (another state, another repository, another
team). It reads the cluster through the cluster root's `application_target` output and creates the same seed, the
`<app>-vars` ConfigMap, any namespaces the application needs ahead of Flux, and the application's cloud identities:

```hcl
module "my_app" {
  # terraform-google-gke-flux//modules/application on GKE
  source = "git::https://github.com/bitwise-media-group/terraform-aws-eks-flux.git//modules/application?ref=vX.Y.Z"

  name    = "my-app"
  cluster = data.terraform_remote_state.cluster.outputs.application_target

  image = {
    url    = "oci://<registry>/manifests/my-app"
    semver = "<1.0.0 >=0.1.0"
    verify = { subject = "^https://github\\.com/bitwise-media-group/my-app-manifests/.+$" }
  }

  vars       = { MY_APP_DOMAIN = "my-app.example.com" }
  namespaces = ["my-app"]
}
```

- **Identities.** `workload_grants` maps a namespace and ServiceAccount to cloud permissions: an IAM role bound through
  Pod Identity on aws, project IAM roles bound to the Workload Identity principal on google. On aws, `secret_readers`
  creates the podless secret-sync reader roles (see [Secrets](#secrets)); on google, grant the sync ServiceAccount
  access on the application's own Secret Manager containers in the same root.
- **One root only.** Every name matches what the cluster root mints for an application it seeds itself, so an
  application lives in the cluster root **or** its own root, never both.
- **No capacity.** The module owns no nodes. An application that needs dedicated capacity declares it beside the module
  call, from the same `application_target`. See [Dedicated capacity](#dedicated-capacity).

The module's README in each repository lists every input.

## Its variables

Application-specific settings arrive through the application's own `<app>-vars` ConfigMap (`application_vars` on the
cluster module), substituted after `cluster-vars`. Applications may read any platform variable; `PLATFORM_TREE` tells
them which of their own overlays the platform selected. The reverse isn't allowed: a platform manifest reading an
application variable fails strict substitution in `make test`.

## A host

Label the route's namespace `platform.bitwisemedia.uk/gateway-access: "true"` and attach the HTTPRoute to `platform` in
`gateway` by hostname, with no `sectionName`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-app # labelled platform.bitwisemedia.uk/gateway-access: "true"
spec:
  parentRefs:
    - name: platform
      namespace: gateway
  hostnames:
    - my-app.${PLATFORM_DOMAIN}
  rules:
    - backendRefs:
        - name: my-app
          port: 8080
```

The wildcard listener admits it, the wildcard certificate covers it, and [external-dns](components/external-dns.md)
publishes the record.

## An identity

With [dex](components/dex.md) elected, ship a `DexClient` in the application's own namespace.
[dex-client-controller](components/dex.md#dex-client-controller) registers it in dex and writes the client's credentials
to a Secret beside it, so nothing outside the application's image is involved:

```yaml
apiVersion: dex.bitwisemedia.uk/v1alpha1
kind: DexClient
metadata:
  name: status
  namespace: patchy
spec:
  name: Patchy status
  redirectURIs:
    - https://patchy.${PLATFORM_DOMAIN}/oauth2/callback
```

- **The client ID** is `<namespace>-<name>` (`patchy-status` here). An explicit `spec.clientID` must start with
  `<namespace>-`; the `restrict-dex-resources` policy rejects anything else, so no application can claim another's
  client.
- **The Secret** is `<name>-dex-client` (`status-dex-client`), with keys `clientID`, `clientSecret` and `issuer`. Point
  the application's OIDC configuration at it. It's owned by the `DexClient`, so deleting the client deletes it.
- **A public client** (a CLI, authorization code + PKCE) sets `public: true` and gets no secret.
- **Readiness.** `kubectl get dexclient -A` shows each client's ID and `Ready` condition. Gate on `dex` (a Kustomization
  `dependsOn`, or `has "dex" (splitList "," "${PLATFORM_COMPONENTS}")` in a template) since the kind only exists where
  dex is elected.

Connectors stay platform-owned: a `DexConnector` outside the `dex` namespace is rejected, and connectors are configured
through the cluster module (`DEX_CONNECTORS`).

## Its own image signer

The platform's [signature policy](components/kyverno-policies.md) verifies every pod image against the platform
pipeline's identity, with no carve-outs. An application whose images are signed elsewhere ships, in its own image:

- a `policies.kyverno.io/v1` `PolicyException` in the `kyverno` namespace whose `policyRefs` name the
  `ImageValidatingPolicy` `verify-platform-signature`, with `matchConditions` on `request.namespace` scoping it to its
  own pods, and
- its own `ImageValidatingPolicy` verifying its signer, matching those same pods.

Image policies honour only whole-resource exceptions (an exception that lists `images` is ignored), so the exemption
covers whole pods. The application's own policy must therefore close over every image in them: match `*` and verify
platform-mirrored images against the platform identity as well, or reject anything not from its own signer. Kyverno also
checks the Deployments and ReplicaSets that own the pods, so the exception's `matchConditions` must match those too.
Scoping by namespace does this for free; scoping by pod name has to cover the controllers' names as well (dex's
`generateName` check is the example). Every image is still verified by exactly one policy, and the platform never learns
the application's registry or signer. Before the CEL migration this was a `kyverno.io` exception plus a ClusterPolicy;
see [Migrating to CEL policies](reference/migrating-cel-policies.md).

## RBAC

Bind the application's own roles (a status page's verbs, a findings viewer) as RoleBindings in its own namespaces,
against the same `RBAC_GROUP_*` variables the [rbac](components/rbac.md) component uses. The platform binds only the
built-in cluster roles, and gives `RBAC_GROUP_DEVELOPERS` nothing: that's the application's call.

## Secrets

Ship a `SecretProviderClass` / `SecretSync` pair per credential in the cloud's dialect (see
[Secret sync](concepts/secret-sync.md)). On aws, annotate the sync ServiceAccount with
`eks.amazonaws.com/role-arn: ${SECRETS_ROLE_PREFIX}<namespace>-<serviceaccount>`; the cluster module creates that reader
role from the application's declared `secret_readers`. Depend on `secret-sync` when `${PLATFORM_TREE}` is `aws`.

## Dedicated capacity

Most applications run on the cluster's shared workload capacity. One that needs nodes of its own (a runner scale set on
isolated scale-to-zero nodes, a GPU or Arm workload) declares them beside the application, never inside a platform
component:

=== "aws"

    - **Karpenter NodePools in the application's image.** The usual choice. Ship a `NodePool` whose `nodeClassRef` is
      `{group: karpenter.k8s.aws, kind: EC2NodeClass, name: default}`, the platform's
      [shared node class](components/karpenter.md#ec2nodeclass-default). It inherits the node role, subnets, security
      groups and AMI, and adds only the application's requirements, labels, taints and limits. Karpenter scales it from
      zero. Depend on `karpenter` so the CRDs exist when it applies.
    - **`modules/node-group` beside the application.** For capacity Karpenter can't express, such as extra security
      groups or Windows nodes: one EKS managed node group, called from the application's root with the node facts in
      `application_target`.

=== "google"

    - **`modules/node-pool` beside the application.** One GKE node pool on the cluster, called from the application's
      root with the node facts in `application_target`. `min_size = 0` gives a scale-to-zero pool across all its zones.
      Node auto-provisioning still serves everything else.

Whichever you use, keep other workloads off the capacity and keep the application on it:

- **Taint the capacity and label it.** The taint keeps everything else off; the application's pods tolerate it.
- **Select the capacity explicitly.** Tolerating a taint only allows a pod onto the nodes; a `nodeSelector` or required
  node affinity puts it there. On aws select the NodePool (`karpenter.sh/nodepool: <name>`) or your own label. On google
  select `cloud.google.com/gke-nodepool: <name>`, which also stops node auto-provisioning creating a look-alike pool
  when yours is at its maximum.
- **Arm nodes on google carry a taint of their own.** GKE adds `kubernetes.io/arch=arm64:NoSchedule` to every Arm node,
  so arm64 pods must tolerate it as well as the pool's own taint. Karpenter adds no such taint; select
  `kubernetes.io/arch` instead.
- **Repeat the Cilium bootstrap taint on aws.** Cilium must give a new node an address before anything schedules on it.
  terraform's node groups and the platform's default NodePool carry `node.cilium.io/agent-not-ready=true:NoExecute`,
  which the Cilium operator removes once the agent is ready. A Karpenter NodePool lists it under `startupTaints`.
- **Bound it.** Give a NodePool `limits`, and a node pool or node group its `max_size`. Disruptive consolidation
  (`WhenEmptyOrUnderutilized`) evicts running pods to repack them, so capacity for long-running jobs such as CI runners
  usually wants `consolidationPolicy: WhenEmpty`.

??? example "An arm64 runner NodePool on aws"

    ```yaml
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: my-app-runners-arm64
    spec:
      template:
        metadata:
          labels:
            workload: my-app-runners
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          taints:
            - key: workload
              value: my-app-runners
              effect: NoSchedule
          startupTaints:
            - key: node.cilium.io/agent-not-ready
              value: "true"
              effect: NoExecute
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["arm64"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand"]
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["c", "m"]
      limits:
        cpu: "32"
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 5m
    ```

    The runner pods then select `karpenter.sh/nodepool: my-app-runners-arm64` and tolerate `workload=my-app-runners`.

## GitHub Actions runners

With [arc](components/arc.md) elected, ship a `gha-runner-scale-set` HelmRelease in the application's namespace:

- its own tag provider over the mirrored `gha-runner-scale-set` chart, on the same `ARC_SEMVER` range (the two charts
  release in lockstep, and a scale set can't run against a different controller version),
- `controllerServiceAccount: {namespace: arc-systems, name: arc-gha-rs-controller}`,
- the runner image from the mirror, `${CONTAINER_REGISTRY}/images/ghcr.io/actions/actions-runner:<tag>`, since
  `verify-platform-signature` admits only mirrored images,
- and `dependsOn: [arc]`, plus `secret-sync` on aws only, where the GitHub App credential arrives through the
  secret-sync controller. On google there's no `secret-sync` Kustomization to depend on; GKE syncs natively.

Docker-in-Docker (`containerMode.type: dind`) adds a sidecar running `dockerd`, and that changes what the scale set
needs:

- **Privileged pods.** The chart runs the `dind` sidecar with `privileged: true`. A job with the Docker socket is
  effectively root on its node, so run dind scale sets on [dedicated capacity](#dedicated-capacity) that nothing else
  shares.
- **A Kyverno PolicyException for any pod-security rule.** The platform itself enforces only
  `verify-platform-signature`, which mirrored images satisfy, so on a stock cluster nothing rejects the privileged
  sidecar. A cluster that adds a Kyverno rule against privileged containers needs a `PolicyException` in the `kyverno`
  namespace, shipped in the application's own image and scoped to the runner namespace and its pods (the same shape as
  [Its own image signer](#its-own-image-signer)). Never except the runners from `verify-platform-signature`.
- **The mirrored dind image.** The chart hardcodes `docker:dind` from Docker Hub, which the signature policy rejects.
  The mirror carries it as `${CONTAINER_REGISTRY}/images/docker.io/library/docker:dind`; point the sidecar there, for
  example with a HelmRelease `postRenderers` patch on the `AutoscalingRunnerSet`, or spell out the dind pod template
  with `containerMode` unset.

## Monitoring

With [kube-prometheus-stack](components/kube-prometheus-stack.md) elected, ship `ServiceMonitor`, `PodMonitor` or
`PrometheusRule` objects in the application's own namespaces. Prometheus selects them in every namespace with no release
label, so the platform needs no change to scrape a new application.

- Depend on `kube-prometheus-stack`, since the `monitoring.coreos.com` CRDs arrive with it. A cluster that hasn't
  elected it has no such CRDs, so gate the monitors behind the application's own election or leave them out there.
- A `PrometheusRule` is evaluated by the shared Prometheus and routed by the shared Alertmanager, so keep its alerts
  scoped to the application's own series.
