---
description: "Binds the platform identity groups to the built-in cluster-admin, edit and view roles."
---

# rbac

Maps the cluster's identity groups onto Kubernetes RBAC. The platform binds only the three built-in cluster roles; what
anyone may do inside an application is the application's to bind.

|                |                                                              |
| -------------- | ------------------------------------------------------------ |
| **Tier**       | core                                                         |
| **Clouds**     | aws, google (common tier verbatim)                           |
| **Depends on** | nothing                                                      |
| **Namespace**  | `flux-system` (the ResourceSet); bindings are cluster-scoped |
| **Chart**      | none                                                         |
| **Timeout**    | 5m                                                           |

## What it deploys

| group variable       | ClusterRoleBinding     | role            | grants                                                          |
| -------------------- | ---------------------- | --------------- | --------------------------------------------------------------- |
| `RBAC_GROUP_ADMINS`  | `admins-cluster-admin` | `cluster-admin` | everything, everywhere                                          |
| `RBAC_GROUP_DEVOPS`  | `devops-cluster-edit`  | `edit`          | cluster-wide write on namespaced objects, Flux objects included |
| `RBAC_GROUP_VIEWERS` | `viewers-cluster-view` | `view`          | cluster-wide read; aggregates Flux's `flux-view` rules          |

`RBAC_GROUP_DEVELOPERS` is published but has **no platform binding**: what a developer may do is an application
decision. RBAC, CRDs and the rest of cluster-scoped administration stay with admins.

Each binding is rendered only when its group variable is non-empty (the cluster module publishes an empty string when a
role is unbound or group RBAC is off). kustomize can't emit resources conditionally, so a ResourceSet template guards
each one; an empty group renders nothing rather than an invalid empty subject. The variables are compared inline in the
template text, not through `spec.inputs`, so an empty value can't become null.

The same group names satisfy every authenticator that asserts them: the cloud's control-plane group membership, and the
`groups` claim [dex](dex.md) issues to the Flux status UI and to kubectl.

Custom resources without aggregation labels stay invisible to `view`. An application that wants its objects readable
binds its own viewer role. See [Applications](../applications.md#rbac).

## Cluster variables

`RBAC_GROUP_ADMINS`, `RBAC_GROUP_DEVOPS`, `RBAC_GROUP_VIEWERS`.

## Source

??? example "components/rbac/common/resourceset.yaml"

    ```yaml
    --8<-- "components/rbac/common/resourceset.yaml"
    ```
