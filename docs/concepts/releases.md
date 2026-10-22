# Releases & channels

Clusters never follow a branch. They follow a **channel tag** on the published images, chosen in terraform
(`flux.sync.ref`, published as `FLUX_SYNC_CHANNEL`):

| channel   | moves when                   | typical clusters | signed by (subject)                 |
| --------- | ---------------------------- | ---------------- | ----------------------------------- |
| `edge`    | every merge to main          | dev, sandbox     | `publish-edge.yaml@refs/heads/main` |
| `staging` | a release is cut             | staging          | `publish.yaml@refs/tags/v*`         |
| `stable`  | a soaked release is promoted | production       | `publish.yaml@refs/tags/v*`         |

A channel tag moves on **every** image at once: each component's `manifests/<name>` and the entrypoint
`manifests/platform`. Each `platform-<name>` OCIRepository the entrypoint emits follows the same channel, unless that
component is pinned with its `<NAME>_MANIFESTS_REF` variable.

## What gets published

`scripts/publish.sh` is the one place images are pushed and tagged, used by all three workflows:

```sh
publish.sh push <tag> <revision>   # push + sign every component, then the entrypoint LAST
publish.sh tag <from> <to>         # re-tag every image (components first, entrypoint last)
```

- **One image per directory.** Every `components/<name>` becomes `manifests/<name>`, and `platform/` becomes
  `manifests/platform`. A new component is picked up automatically.
- **The entrypoint goes last.** A tag never points at an entrypoint whose components aren't there yet.
- **Sign before moving on.** Each digest is signed (keylessly, or with `COSIGN_KEY` for KMS mode) right after its push.
- **Retagging pulls first.** `tag` pulls each source image before tagging, so a typo can never strand a channel on
  nothing.
- **Every registry.** The script pushes to each prefix in `REGISTRIES`: the GCP platform registry always, and the AWS
  one when the org's `AWS_MANIFEST_PUBLISHER_ROLE` variable is set.

## The release flow

1. **Merge to main → edge.** `publish-edge.yaml` pushes every image as `edge-next`, signs it, and only then retags
   `edge-next` as `edge`. An edge cluster can therefore never pull an artifact whose signature isn't attached yet.
2. **Release → staging.** release-please keeps a release PR open from the Conventional Commit history. Merging it cuts
   `vX.Y.Z`; `publish.yaml` checks out the tag, pushes every image as `X.Y.Z` and moves `staging` onto it.
3. **Promote → stable.** After soak, run the **Promote Manifests** workflow (`promote.yaml`) with the version. It's
   gated by the `production` environment's required reviewers, and moves `stable` onto the same digests. The images and
   their signatures are untouched; verification follows the digest.

The edge workflow is a separate file on purpose. The Fulcio certificate subject is the workflow path plus the ref, so
edge artifacts carry a distinct identity that only edge clusters trust, while staging and stable clusters keep matching
`publish.yaml@refs/tags/v*` only. See [Signing & verification](signing.md#the-manifests-identity-per-channel).

## Credentials

The workflows hold no long-lived secrets. The job's GitHub OIDC token is exchanged for:

- a GCP access token through Workload Identity Federation, impersonating the manifest-publisher service account
  (`GCP_WIF_PROVIDER`, `GCP_MANIFEST_PUBLISHER_SA`),
- AWS credentials for the artifact-store module's `manifest_publishers` role (`AWS_MANIFEST_PUBLISHER_ROLE`, in
  `AWS_REGION`), whose push grant covers `manifests/*`,
- and the Fulcio signing certificate.

The publisher identities' trust policies admit exactly the subjects above: `refs/tags/v*` for `publish.yaml`,
`refs/heads/main` for `publish-edge.yaml`, and the `production` environment for `promote.yaml`. These values are
org-level Actions variables mirrored from the terraform artifact-store outputs.

## Versioning

Versions come from Conventional Commits: `fix:` is a patch, `feat:` a minor, and `!` or a `BREAKING CHANGE:` footer a
major. Treat a change as breaking when a running cluster would need action to take it: a removed or renamed cluster
variable, a removed component, or a contract change for applications. The
[3.x → 4.0 migration](../reference/migrating-3x.md) is the largest example.
