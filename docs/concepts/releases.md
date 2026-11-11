# Releases & channels

Clusters never follow a branch, and no tag ever moves. Every build is published under immutable tags, and a cluster
follows its **channel**, chosen in terraform (`flux.sync.ref`): the newest build in the channel's semver range, narrowed
by a tag regexp. The cluster module publishes the range and the regexp as `FLUX_SYNC_SEMVER` and
`FLUX_SYNC_SEMVER_FILTER`.

| channel  | each build is tagged                                   | published when                          | typical clusters |
| -------- | ------------------------------------------------------ | --------------------------------------- | ---------------- |
| `edge`   | `<next version>-edge.<yyyymmddhhmmss>.g<short commit>` | every push to main that cuts no release | dev, sandbox     |
| `stable` | `vX.Y.Z`, added to the newest `X.Y.Z` edge build       | the release PR merges and cuts `vX.Y.Z` | production       |

Edge is followed as `>=0.0.0-0` with a regexp matching only edge builds
(`^[0-9]+[.][0-9]+[.][0-9]+-edge[.][0-9]{14}[.]g[0-9a-f]{7,40}$`); stable as `>=0.0.0`, which excludes pre-releases. An
edge build is based on the **next** version, the open release PR's, so the order is consistent everywhere: `1.3.2` <
`1.4.0-edge.*` < `1.4.0`. The timestamp is the commit's own time in UTC. Edge builds also carry `sha-<commit>`.

Every artifact follows the same channel: each component's `manifests/<name>` and the entrypoint `manifests/platform`.
Each `platform-<name>` OCIRepository the entrypoint emits takes `FLUX_SYNC_SEMVER` and `FLUX_SYNC_SEMVER_FILTER`, unless
that component is pinned to a tag with its `<NAME>_MANIFESTS_REF` variable.

## What gets published

`patchy.yaml` lists what [`patchy build`](https://oss.bitwisemedia.uk/patchy/supply-chain/build/) publishes: every
`components/<name>` as `manifests/<name>`, then `platform/` as `manifests/platform`. `make build` packages every
artifact without publishing, and needs no registry configured; CI runs it on every pull request. A new component needs
its entry in `patchy.yaml`, and the validation harness fails until it has one. Entries publish in order, so a platform
build never references a component build that isn't there yet.

Publishing is the release workflow's `publish` job, which runs the
[`patchy-publish`](https://oss.bitwisemedia.uk/github-workflows/actions/patchy-publish/) action after release-please:

1. **No release cut → edge.** Every artifact is built and pushed under its edge tag, then signed. Builds are
   deterministic, so re-running a publish reports `skipped-current` and signs nothing twice.
2. **Release cut → stable.** Merging the release PR cuts `vX.Y.Z`. The action finds the newest `X.Y.Z-edge.*` build of
   every artifact, checks that it was built from a commit whose tree matches the release commit's (a release commit only
   bumps the changelog and version), verifies its signature, and adds `vX.Y.Z` to it. Nothing is rebuilt: production
   runs exactly the digests edge clusters have been running.

The publish job runs one at a time, in push order, so an edge build never races a promotion. The registry and the
signing config are org variables, never committed; registry URLs are masked in the job's logs.

## Signing

Both channels carry the same signature, made by this repository's release workflow on `main`
(`…/flux-manifests/.github/workflows/release.yaml@refs/heads/main`). The channels are told apart by tag, and a stable
cluster's `>=0.0.0` never matches an edge build. See [Signing & verification](signing.md#the-manifests-identity).

## Credentials

The publish job holds no long-lived secrets. Its GitHub OIDC token is exchanged for:

- a GCP access token through Workload Identity Federation, impersonating the manifest-publisher service account
  (`GOOGLE_WORKLOAD_IDENTITY_PROVIDER`, `GOOGLE_MANIFEST_PUBLISHER_SA`), whose trust admits this repository's `main`
  branch,
- and the Fulcio signing certificate.

The platform registry is the `GOOGLE_PLATFORM_REGISTRY` org variable. An AWS platform registry joins when
`AWS_PLATFORM_REGISTRY`, `AWS_MANIFEST_PUBLISHER_ROLE` and `AWS_REGION` are set; `SIGNING_KMS_KEY` switches signing to a
KMS key.

## Versioning

Versions come from Conventional Commits: `fix:` is a patch, `feat:` a minor, and `!` or a `BREAKING CHANGE:` footer a
major. Treat a change as breaking when a running cluster would need action to take it: a removed or renamed cluster
variable, a removed component, or a contract change for applications. The
[3.x → 4.0 migration](../reference/migrating-3x.md) is the largest example.
