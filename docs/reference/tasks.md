# Tasks

Every task is a [mise](https://mise.jdx.dev) task; the Makefile only forwards, so `make <task>` and `mise run <task>`
are the same. `make help` lists them.

| task           | what it does                                                                                                           |
| -------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `make test`    | the [validation harness](../concepts/validation.md): render, guard and kubeconform every tree and signing mode         |
| `make lint`    | license headers, prose, actionlint + zizmor, shellcheck, kubescape over the overlays                                   |
| `make fmt`     | format prose and inject license headers                                                                                |
| `make build`   | `patchy build --all --dry-run`: package every artifact `patchy.yaml` lists, without publishing                         |
| `make publish` | `patchy build`: package, push and sign every artifact (needs a registry config + login; CI publishes via release.yaml) |
| `docs-build`   | build this documentation site into `site/` (`zensical build`)                                                          |
| `make serve`   | serve this site with live reload on <http://localhost:8004>                                                            |
| `make ci`      | `lint`, `test`, `build`, `docs-build`                                                                                  |
| `make pr`      | the full local gate before a pull request: `fmt`, `lint`, `test`, `build`, `docs-build`, `commit`                      |

The reusable CI runs `lint`, `test` and `build` as jobs of their own.

## Where they come from

Three task files are layered, each included after the last so a later same-named task replaces an earlier one whole:

1. **`.mise/common/tasks.toml`** from the shared [toolchain](https://oss.bitwisemedia.uk/toolchain/) submodule: the
   prose, license, workflow, shell and container checks every repository runs, and the docs site (`docs-build`,
   `serve`).
2. **`.mise/archetypes/containers/tasks.toml`**: the
   [containers archetype](https://oss.bitwisemedia.uk/toolchain/archetypes/containers/), whose `build` and `publish` run
   `patchy build` over `patchy.yaml`, and whose Flux helpers (`flux-substitute.sh`, `kubeconform.sh`) the harness calls.
3. **`tasks.toml`**: the repository's own surface, below.

The root `mise.toml` only selects them: every tool, including the harness's kustomize, kubeconform, yq and the
flux-operator CLI, is a shared toolchain pin. Renovate keeps the pins fresh in the toolchain.

```toml title="tasks.toml"
--8<-- "tasks.toml"
```
