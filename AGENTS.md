# Agent instructions

flux-manifests is the GitOps platform every BitWise Media Group cluster syncs: an entrypoint (`platform/<cloud>/`) plus
one OCI image per component (`components/<name>/`), all cosign-signed and followed by each cluster's FluxInstance on a
release channel. The documentation site under `docs/` (Zensical, `zensical.toml`) is the long-form description of all of
it. `README.md` is a short overview that links into it.

## Keep the docs current

**Every change that alters behaviour, layout, contracts or workflow must update the docs in the same change.** The docs
are published from each release, so a PR that changes the platform without its docs ships a site that's wrong.

Component and reference pages embed the live files (`--8<-- "<path>"`), so source listings update themselves. The prose
around them doesn't. Use this table to find what to touch:

| when you change…                                                                      | update                                                                                                                                                                                                                                          |
| ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| a component's values, objects or behaviour (`components/<name>/`)                     | `docs/components/<name>.md`                                                                                                                                                                                                                     |
| a component's dependencies, timeout, election or tier (`platform/*/resourceset.yaml`) | the component's page, `docs/components/index.md` (catalogue table), the graph in `docs/concepts/graph.md` and `README.md`                                                                                                                       |
| add a component                                                                       | new `docs/components/<name>.md` with a `description` in its front matter, its line in the **Components** `nav` of `zensical.toml`, the catalogue row, the graph, and any table it belongs in (e.g. charts in `docs/concepts/chart-delivery.md`) |
| remove or rename a component                                                          | delete or rename its page and nav entry, and every link to it (`grep -rn '<name>' docs README.md`)                                                                                                                                              |
| a cluster variable (new, removed, renamed, new default, new consumer)                 | `docs/reference/cluster-vars.md`, the consuming component pages, and `tests/{aws,google}{,.keyed}.env`                                                                                                                                          |
| a semver range default (`*_SEMVER`, `*_IMAGE_SEMVER`)                                 | the facts table on the component's page                                                                                                                                                                                                         |
| signing, verification or the admission policy                                         | `docs/concepts/signing.md`, `docs/components/kyverno-policies.md`                                                                                                                                                                               |
| secret sync (either cloud's dialect, a new consumer)                                  | `docs/concepts/secret-sync.md` and the consumer's page                                                                                                                                                                                          |
| `scripts/validate.sh`, the guards, fixtures or schemas                                | `docs/concepts/validation.md`; `docs/getting-started/adding-a-component.md` if the steps for a new component change                                                                                                                             |
| `scripts/publish.sh`, a publish/promote workflow, channels or signing identities      | `docs/concepts/releases.md`, `docs/concepts/automation.md`                                                                                                                                                                                      |
| any other workflow under `.github/workflows/`                                         | `docs/concepts/automation.md`                                                                                                                                                                                                                   |
| tasks (`tasks.toml`, `mise.toml`, the `Makefile`)                                     | `docs/reference/tasks.md` (the file itself is embedded; the summary table isn't)                                                                                                                                                                |
| the application contract (seed, host, identity, exceptions, secrets, runners)         | `docs/applications.md`                                                                                                                                                                                                                          |
| an operational procedure or caveat                                                    | `docs/reference/operations.md`                                                                                                                                                                                                                  |
| a breaking change for running clusters                                                | a migration section (follow `docs/reference/migrating-3x.md`) and the changed contract tables                                                                                                                                                   |
| the docs tooling itself                                                               | `docs/reference/docs.md`                                                                                                                                                                                                                        |

If an embedded file moves, update its `--8<--` path; the build fails (`check_paths`) until you do. Remove a statement
rather than leave it wrong.

## Writing the docs

- Match the existing pages: short declarative sentences, British spelling, contractions, sentence-case headings, and a
  `| | |` facts table at the top of each component page.
- Explain why, not just what. The YAML comments in the manifests usually carry the reasoning; distil it, don't paste it.
- No nested lists and no code blocks inside list items: prettier re-indents list content to the marker width, which
  Python-Markdown misreads. Content under `!!! note` / `??? example` / `=== "tab"` takes a 4-space indent.
- To show a snippet marker literally, escape it as `;--8<--`.
- Link between pages with relative `.md` paths, including the anchor when pointing at a section.

## Checking your work

```sh
make test    # the validation harness: required for any manifest change
make lint    # license headers, prose, workflows, shell, kubescape
make build   # the docs site (zensical build); fails on a missing embed
make serve   # preview on http://localhost:8004
make pr      # all of the above plus fmt
```

The `build` task runs in CI, so a broken page fails the PR. Running mise tools can rewrite `.mise/mise.lock` and create
`.mise/locks/` inside the toolchain submodule; restore it (`git -C .mise checkout -- mise.lock && rm -rf .mise/locks`)
before committing, and never commit submodule changes from here.

## Repository rules worth knowing

- `components/*/common/` must stay cloud-neutral: only variables both clouds publish, a single-cloud variable only
  behind `:=`, and no branching on the cloud. Per-cloud overlays must not keep `:=` defaults on variables their own
  cloud always publishes. `make test` enforces both.
- Ordering, timeouts, elections and release pins live only in `platform/<tree>/resourceset.yaml`.
- A variable that can be empty must never sit in a bare quoted scalar in structured YAML (see
  `docs/concepts/substitution.md`).
- The platform names no application. Anything application-specific belongs in that application's own image.
- Commits use Conventional Commits scoped to the component (`fix(dex): …`); release-please derives versions from them,
  and `docs:` commits don't cut a release on their own.
