---
description: "The Actions Runner Controller, controller half only: applications bring their own runner scale sets."
---

# arc

The [Actions Runner Controller](https://github.com/actions/actions-runner-controller), **controller half only**: the
`actions.github.com` CRDs, the manager Deployment and its RBAC, watching every namespace. Runner scale sets are
application-level; an application ships its own in its own namespace.

|                |                                                                                                                                                                          |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Tier**       | electable                                                                                                                                                                |
| **Clouds**     | aws, google (common tier verbatim)                                                                                                                                       |
| **Depends on** | kyverno-policies                                                                                                                                                         |
| **Namespace**  | `arc-systems`                                                                                                                                                            |
| **Chart**      | [`gha-runner-scale-set-controller`](https://oss.bitwisemedia.uk/flux-containers/charts/gha-runner-scale-set-controller/), range `ARC_SEMVER` (default `<1.0.0 >=0.14.0`) |
| **Timeout**    | 5m                                                                                                                                                                       |

## Notable values

- **Release name `arc`.** The chart derives the controller ServiceAccount's name from it, so the controller runs as
  `arc-systems/arc-gha-rs-controller`, the name every scale set's `controllerServiceAccount` must give.
- **`flags.watchSingleNamespace: ""`**: cluster-wide, because scale sets live in application namespaces the platform
  doesn't know about.
- **CRDs `CreateReplace`**, so a scale set from a newer chart always finds the newer CRDs.
- **One image covers the listeners.** The controller launches listener pods with its own image, so the one mirrored
  image covers every listener a scale set creates.
- **First provenance.** Upstream publishes the chart and image unsigned; the mirror's signature, verified here and by
  the admission policy, is the first provenance anything on this path gets.

## Running a scale set

An application that wants runners ships a `gha-runner-scale-set` HelmRelease in its own namespace:

- its **own tag provider** over the mirrored `gha-runner-scale-set` chart, on the **same `ARC_SEMVER` range**. The two
  charts release in lockstep (the mirror bumps both in one PR), and a scale set can't run against a different controller
  version.
- `controllerServiceAccount: {namespace: arc-systems, name: arc-gha-rs-controller}`.
- `dependsOn: [arc, secret-sync]`, for the GitHub App credential sync.

See [Applications](../applications.md#github-actions-runners).

## Cluster variables

`PLATFORM_COMPONENTS` (to elect it), `ARC_SEMVER`, the usual registry and signing variables.

## Source

??? example "components/arc/common/input-provider.yaml"

    ```yaml
    --8<-- "components/arc/common/input-provider.yaml"
    ```

??? example "components/arc/common/resourceset.yaml"

    ```yaml
    --8<-- "components/arc/common/resourceset.yaml"
    ```
