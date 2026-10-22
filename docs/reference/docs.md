# Working on the docs

This site is [Zensical](https://zensical.org), built with uv through the toolchain's python archetype. Its look is the
[flux-containers](https://oss.bitwisemedia.uk/flux-containers/) site's: the same `docs/stylesheets/extra.css` tokens and
header partials, with a landing page in `overrides/home.html`.

```sh
make serve   # http://localhost:8004, live reload for docs/ edits
make build   # render into site/
```

## Layout

```text
zensical.toml              site config and the nav
docs/                      the pages
  stylesheets/extra.css    the BitWise Media Group palette and the landing styles
  assets/logo-mark.svg
overrides/
  home.html                the landing page (hero, marquee, component cards)
  main.html, partials/     header and drawer lockups
pyproject.toml · uv.lock   the Zensical pin
```

The landing page reads its component marquee, count and cards from the **Components** section of the `nav` in
`zensical.toml`, and each card's blurb from that page's `description` front matter. Adding a component page to the nav
is all the landing needs.

## Pages that embed live files

Component and reference pages include repository files directly with `--8<-- "<path>"` (`pymdownx.snippets`), so the
source listings can't fall out of date:

````markdown
??? example "components/kyverno/common/resourceset.yaml"

    ```yaml
    ;--8<-- "components/kyverno/common/resourceset.yaml"
    ```
````

Snippet paths resolve against `docs/` and the repository root (`base_path` in `zensical.toml`). `check_paths` is on, so
a page embedding a file that was moved or deleted fails the build. CI builds the site on every PR.

The prose around an embed is still hand-written. When a change alters what a component deploys, its dependencies or the
variables it reads, update its page in the same PR.

## Linting

Prose under `docs/` follows the house prettier and markdownlint rules (`make lint`). `docs/.markdownlint.yaml` relaxes
the fenced-code rule, because admonition and tab bodies need a 4-space indent that a CommonMark parser reads as an
indented code block. The root `.markdownlint-cli2.yaml` ignores the build output (`site/`, `.cache/`).

Avoid nested lists and code blocks inside list items: prettier re-indents list content to the marker width, while
Python-Markdown needs four spaces. Put the content after the list instead, or in an admonition.

## Publishing

The org's reusable release workflow (`release.yaml`) has a docs job that runs `uv run zensical build` and deploys the
result to GitHub Pages whenever a release is cut and a `zensical.toml` is present. The published site at
<https://oss.bitwisemedia.uk/flux-manifests/> therefore describes the latest release. Changes merged since then appear
with the next release. Pages must be set to **Settings → Pages → Source → GitHub Actions**.
