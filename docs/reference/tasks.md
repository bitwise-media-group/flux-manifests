# Tasks

Every task is a [mise](https://mise.jdx.dev) task; the Makefile only forwards, so `make <task>` and `mise run <task>`
are the same. `make help` lists them.

| task         | what it does                                                                                                   |
| ------------ | -------------------------------------------------------------------------------------------------------------- |
| `make test`  | the [validation harness](../concepts/validation.md): render, guard and kubeconform every tree and signing mode |
| `make lint`  | license headers, prose (prettier + markdownlint), actionlint + zizmor, shellcheck, kubescape over the overlays |
| `make fmt`   | format prose and inject license headers                                                                        |
| `make build` | build this documentation site into `site/` (`zensical build`)                                                  |
| `make serve` | serve this site with live reload on <http://localhost:8004>                                                    |
| `make ci`    | what CI runs: `lint`, `test`, `build`                                                                          |
| `make pr`    | the full local gate before a pull request: `fmt`, `lint`, `test`, `build`                                      |

## Where they come from

Three task files are layered, each included after the last so a later same-named task replaces an earlier one whole:

1. **`.mise/common/tasks.toml`** from the shared [toolchain](https://oss.bitwisemedia.uk/toolchain/) submodule: the
   prose, license, workflow, shell and container checks every repository runs.
2. **`.mise/archetypes/python/tasks.toml`**: the docs site (`sync`, `docs-build`, `serve`, `build`). It's here only for
   this site; the repository has no Python.
3. **`tasks.toml`**: the repository's own surface, below.

The root `mise.toml` selects them and pins the validation-only tools (kustomize, kubeconform, yq and the flux-operator
CLI). Don't run a repo-wide `mise upgrade`: it would write into the toolchain submodule. Renovate keeps the pins fresh.

```toml title="tasks.toml"
--8<-- "tasks.toml"
```
