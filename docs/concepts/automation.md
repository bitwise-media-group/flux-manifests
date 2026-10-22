# CI & automation

Every workflow lives in `.github/workflows/`. Most are thin callers of the org's reusable workflows in
[github-workflows](https://github.com/bitwise-media-group/github-workflows), pinned to a full commit SHA that Renovate
keeps fresh.

## On every pull request

| workflow            | what it does                                                                                                                                                                       |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ci.yaml`           | runs `mise run lint`, `test` and `build` as parallel jobs: the prose, license, workflow and kubescape checks, the [validation harness](validation.md), and this documentation site |
| `security.yaml`     | CodeQL over the GitHub Actions workflows (the repo has no other code to scan); also weekly                                                                                         |
| `merge-notice.yaml` | posts a one-time comment explaining the fast-forward merge flow                                                                                                                    |

## Merging

The repository merges by **fast-forward** so every commit (and its signature) lands on main unchanged and release-please
sees each Conventional Commit individually. A maintainer comments `/merge` on an approved, green PR, or arms it with
`/auto-merge` (or the `auto-merge` label) to merge once it's approved and every required check passes. `merge.yaml` and
`merge-review-ack.yaml` drive this through the FF Merge GitHub App.

## On main

| workflow            | trigger               | what it does                                                                                                                 |
| ------------------- | --------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `publish-edge.yaml` | push to main          | push and sign every image as `edge-next`, then move `edge` onto it                                                           |
| `release.yaml`      | push to main          | release-please keeps the release PR current; on merge it cuts `vX.Y.Z`, and the docs job publishes this site to GitHub Pages |
| `publish.yaml`      | release published     | push and sign every image at `X.Y.Z` from the release tag, move `staging`                                                    |
| `promote.yaml`      | manual (`production`) | move `stable` onto a released version after soak                                                                             |

The publish flow and its credentials are covered in [Releases & channels](releases.md).

## Housekeeping

| workflow              | what it does                                                                                  |
| --------------------- | --------------------------------------------------------------------------------------------- |
| `renovate.yaml`       | hourly self-hosted Renovate run: action pins, the toolchain submodule, the mise tool pins     |
| `add-to-project.yaml` | adds new issues and PRs to the org Roadmap project (managed from github-settings; don't edit) |

Renovate doesn't touch chart versions here: components follow the mirrored charts at runtime through their tag
providers, so a chart bump is a [flux-containers](https://oss.bitwisemedia.uk/flux-containers/) change.

## The documentation site

This site is published by the reusable release workflow's docs job, which runs whenever a release is cut and the
repository has a `zensical.toml`. The published site therefore always describes the latest release. CI builds the site
on every PR, so a broken page or a moved embedded file fails before merge. See
[Working on the docs](../reference/docs.md).
