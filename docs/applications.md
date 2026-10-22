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

Declare dex clients through the cluster module (`applications[*].dex_clients`). The cluster module composes them into
`DEX_CLIENTS` beside the platform's own, mints a `dex-client-<id>` secret container for every confidential client, and
the [dex](components/dex.md) component registers the client and syncs its secret. The application syncs the same
container (`${SECRET_PREFIX}dex-client-<id>`) into its own namespace, so both sides read the same value.

## Its own image signer

The platform's [signature policy](components/kyverno-policies.md) verifies every pod image against the platform
pipeline's identity, with no carve-outs. An application whose images are signed elsewhere ships, in its own image:

- a `PolicyException` in the `kyverno` namespace, scoped to its own namespaces and images, excusing them from
  `verify-platform-signature`, and
- its own `ClusterPolicy` verifying its signer.

Every image is still verified by exactly one policy, and the platform never learns the application's registry or signer.

## RBAC

Bind the application's own roles (a status page's verbs, a findings viewer) as RoleBindings in its own namespaces,
against the same `RBAC_GROUP_*` variables the [rbac](components/rbac.md) component uses. The platform binds only the
built-in cluster roles, and gives `RBAC_GROUP_DEVELOPERS` nothing: that's the application's call.

## Secrets

Ship a `SecretProviderClass` / `SecretSync` pair per credential in the cloud's dialect (see
[Secret sync](concepts/secret-sync.md)). On aws, annotate the sync ServiceAccount with
`eks.amazonaws.com/role-arn: ${SECRETS_ROLE_PREFIX}<namespace>-<serviceaccount>`; the cluster module creates that reader
role from the application's declared `secret_readers`. Depend on `secret-sync` when `${PLATFORM_TREE}` is `aws`.

## GitHub Actions runners

With [arc](components/arc.md) elected, ship a `gha-runner-scale-set` HelmRelease in the application's namespace:

- its own tag provider over the mirrored `gha-runner-scale-set` chart, on the same `ARC_SEMVER` range (the two charts
  release in lockstep, and a scale set can't run against a different controller version),
- `controllerServiceAccount: {namespace: arc-systems, name: arc-gha-rs-controller}`,
- and `dependsOn: [arc, secret-sync]` for the GitHub App credential sync.
