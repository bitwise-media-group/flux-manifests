#!/usr/bin/env bash
# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Render and validate everything each cluster would apply, once per tree
# and signing mode ({google,aws} x {keyless,keyed}):
#   1. kustomize-build every component's overlay for the tree
#      (components/<name>/<tree>, which pulls in ../common) and the
#      platform entrypoint (platform/<tree>)
#   2. substitute cluster-vars the way the Kustomizations do (postBuild),
#      faithfully to the controller's roundtrip -- so an empty var that
#      would become null on a cluster becomes null (and fails) here (the
#      toolchain's flux-substitute.sh)
#   3. render ResourceSets with sample inputs (flux-operator CLI), the
#      platform entrypoint included (every component elected, and the
#      reserved "none" election)
#   4. kubeconform the results against Flux + flux-operator + component CRD
#      schemas (the toolchain's kubeconform.sh)
# plus the structural guards that keep the layout honest:
#   - components/*/common may not branch on cloud, and may reference a var
#     published by only one cloud's module solely through a := default
#   - a per-cloud overlay (or entrypoint) may not carry a := default whose
#     only purpose was to survive the other cloud's strict substitution
#   - no ${VAR}-bearing quoted scalar may substitute to null (the guard
#     self-tests at startup, so it cannot rot)
#   - the entrypoint is complete: every component overlay the tree ships is
#     emitted by the platform ResourceSet, and every dependsOn it emits
#     resolves to a Kustomization something emits
#   - the core tier is election-independent: the "none" election still
#     emits every non-electable component
#   - every component is published: patchy.yaml's build.manifests lists
#     each components/<name>, and the platform entrypoint last
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build"
# The containers archetype's Flux helpers: postBuild substitution with the
# strict check and null guard, and kubeconform with the house schema catalog.
HELPERS="$ROOT/.mise/archetypes/containers/scripts"
rm -rf "$BUILD" && mkdir -p "$BUILD"

command -v kustomize >/dev/null || { echo "kustomize not found" >&2; exit 1; }
command -v kubeconform >/dev/null || { echo "kubeconform not found" >&2; exit 1; }
command -v flux-operator >/dev/null || { echo "flux-operator CLI not found" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq not found" >&2; exit 1; }

# The electable tier: the only components the platform ResourceSet gates on
# PLATFORM_COMPONENTS. Everything else under components/ is core and must
# be emitted whatever the election says (the election-independence guard).
ELECTABLE="dex flux-web arc kube-prometheus-stack auth-proxy"

# --- the per-cloud env contracts -------------------------------------------
# Each cloud's variable NAME set (base + keyed overlay) doubles as the
# machine-readable record of what that cluster module publishes; the
# neutrality and dead-default guards below compare manifests against it.
env_var_names() { # env_var_names <env-file>...
  grep -hE '^[A-Z][A-Z0-9_]*=' "$@" | cut -d= -f1 | sort -u
}
AWS_VARS="$(env_var_names "$ROOT/tests/aws.env" "$ROOT/tests/aws.keyed.env")"
GOOGLE_VARS="$(env_var_names "$ROOT/tests/google.env" "$ROOT/tests/google.keyed.env")"

in_set() { # in_set <name> <newline-separated-set>
  printf '%s\n' "$2" | grep -qx "$1"
}

# Scalar values across every document of a multi-document file, minus
# the document separators yq prints between them.
yq_values() { # yq_values <expression> <file>...
  local expr="$1"
  shift
  yq ea "$expr" "$@" | grep -v '^---$' | sort -u || true
}

# Every component the tree ships an overlay for.
shipped_components() { # shipped_components <tree>
  find "$ROOT/components" -mindepth 2 -maxdepth 2 -type d -name "$1" -exec dirname {} + | while IFS= read -r dir; do basename "$dir"; done | sort -u
}

# Substitute cluster vars the way kustomize-controller's postBuild does on a
# real cluster: strict (a bare ${VAR} that this cloud's env never sets
# fails, as it would fail the Kustomization), through the controller's
# parse/re-serialize/substitute/re-parse round trip, then the null guard (no
# ${VAR}-bearing scalar may substitute to null -- fix at the source per the
# empty-var convention: gate the key absent, template-quote (`| quote`), or
# move the value into a resourcesTemplate block scalar). Each tree's passes
# run under only that cloud's env, so they fail the way its cluster would.
substitute() { # substitute <in-file> <out-file>
  "$HELPERS/flux-substitute.sh" "$1" "$2"
}

# components/*/common serves both clusters verbatim: no cloud branching,
# and any var only one cloud's module publishes may be referenced solely
# through a := default (that is the per-cluster election mechanism -- the
# other cloud's passes render the election-absent arm, and the null guard
# proves it renders safely). A BARE single-cloud ${VAR} would fail strict
# substitution on the other cluster.
check_common_neutral() {
  local hits var bad=0 dirs
  dirs="$(find "$ROOT/components" -mindepth 2 -maxdepth 2 -type d -name common)"
  [[ -n "$dirs" ]] || return 0
  # shellcheck disable=SC2016,SC2086 # grep pattern; the directory list is deliberately word-split
  if hits="$(grep -REn 'inputs\.cloud|\$\{CLOUD[:}]' $dirs 2>/dev/null)"; then
    { echo "components/*/common must not branch on cloud:"; printf '%s\n' "$hits" | sed 's/^/  /'; } >&2
    exit 1
  fi
  # shellcheck disable=SC2016,SC2086 # grep pattern, not an expansion; the directory list is deliberately word-split
  while IFS= read -r var; do
    [[ -n "$var" ]] || continue
    if in_set "$var" "$AWS_VARS" && ! in_set "$var" "$GOOGLE_VARS"; then
      echo "common neutrality: bare \${$var} but $var is only in the aws env contract -- google's strict substitution would fail; guard it with a := default" >&2
      bad=1
    elif in_set "$var" "$GOOGLE_VARS" && ! in_set "$var" "$AWS_VARS"; then
      echo "common neutrality: bare \${$var} but $var is only in the google env contract -- aws's strict substitution would fail; guard it with a := default" >&2
      bad=1
    fi
  done < <(grep -RhoE '\$\{[A-Z][A-Z0-9_]*\}' $dirs | tr -d '${}' | sort -u)
  [[ "$bad" -eq 0 ]] || exit 1
}

# In a per-cloud overlay (or the tree's entrypoint), a := default over a
# var that tree's own module ALWAYS publishes -- and the other cloud's
# never does -- is dead code left over from the shared-tree era, kept
# alive only to survive the other cloud's strict substitution. Genuinely
# caller-optional defaults (vars in neither contract, or in both) stay.
check_dead_defaults() { # check_dead_defaults <tree> <own-set> <other-set>
  local tree="$1" own="$2" other="$3" var bad=0 dirs
  dirs="$(find "$ROOT/components" -mindepth 2 -maxdepth 2 -type d -name "$tree"; echo "$ROOT/platform/$tree")"
  # shellcheck disable=SC2086 # the directory list is deliberately word-split
  while IFS= read -r var; do
    [[ -n "$var" ]] || continue
    if in_set "$var" "$own" && ! in_set "$var" "$other"; then
      echo "dead default: \${$var:=...} under a $tree overlay but $var is in $tree's env contract alone -- the default only survived the other cloud; make it a bare \${$var}" >&2
      bad=1
    fi
  done < <(grep -RhoE '\$\{[A-Z][A-Z0-9_]*:=' $dirs | sed 's/^..//; s/:=$//' | sort -u)
  [[ "$bad" -eq 0 ]] || exit 1
}

# Render one ResourceSet under every fixture that matches it, searching
# the fixture directories in order (first match wins per basename). Two
# fixture shapes: a plain list of input sets (--inputs-from), or Static
# ResourceSetInputProvider manifests (--inputs-from-provider) for
# ResourceSets using the Permute strategy -- Permute namespaces inputs by
# provider name, and only provider-shaped fixtures reproduce that in the
# render.
render_one() { # render_one <substituted-rs> <name> <file> <fixture-dir>...
  local rs="$1" name="$2" file="$3" out variants vbase inputs variant inputs_flag dir
  shift 3
  out="$(dirname "$rs")"
  # The primary fixture plus any <file>.<variant>.yaml siblings: each
  # renders the same ResourceSet with a different input set, so every
  # side of an input branch (elections) gets rendered and
  # kubeconform-validated.
  variants="$( { for dir in "$@"; do ls "$dir" 2>/dev/null || true; done; } \
    | grep -E "^$file(\.[A-Za-z0-9-]+)?\.yaml$" | sort -u )"
  [[ -n "$variants" ]] || { echo "missing test inputs $file.yaml for $name under: $*" >&2; exit 1; }
  for vbase in $variants; do
    inputs=""
    for dir in "$@"; do
      [[ -f "$dir/$vbase" ]] && { inputs="$dir/$vbase"; break; }
    done
    variant="$(basename "$vbase" .yaml)"
    inputs_flag="--inputs-from"
    if grep -q "^kind: ResourceSetInputProvider$" "$inputs"; then
      inputs_flag="--inputs-from-provider"
    fi
    # A fixture may sit on the empty side of an input branch (a disabled
    # election) and legitimately render nothing -- the CLI treats that as
    # an error, so allow exactly that failure and keep the empty render
    # for kubeconform.
    if ! flux-operator build resourceset -f "$rs" "$inputs_flag" "$inputs" \
      > "$out/rendered-$name-$variant.yaml" 2> "$out/rendered-$name-$variant.err"; then
      grep -q "no objects were generated" "$out/rendered-$name-$variant.err" \
        || { cat "$out/rendered-$name-$variant.err" >&2; exit 1; }
      : > "$out/rendered-$name-$variant.yaml"
    fi
    rm -f "$out/rendered-$name-$variant.err"
  done
}

# Every component ResourceSet must have a matching inputs fixture:
# tests/inputs/<component>/{<tree>,common}/<file>[.<variant>].yaml, the
# tree directory shadowing common per basename. The entrypoint's fixtures
# live at tests/inputs/platform/<tree>/.
render_resourcesets() { # render_resourcesets <tree> <out-dir>
  local tree="$1" out="$2" rs comp file
  for rs in "$ROOT/components"/*/common/resourceset*.yaml "$ROOT/components"/*/"$tree"/resourceset*.yaml; do
    [[ -f "$rs" ]] || continue
    comp="$(basename "$(dirname "$(dirname "$rs")")")"
    file="$(basename "$rs" .yaml)"
    substitute "$rs" "$out/rs-$comp-$file.yaml"
    render_one "$out/rs-$comp-$file.yaml" "$comp" "$file" "$ROOT/tests/inputs/$comp/$tree" "$ROOT/tests/inputs/$comp/common"
  done
  substitute "$ROOT/platform/$tree/resourceset.yaml" "$out/rs-platform-resourceset.yaml"
  render_one "$out/rs-platform-resourceset.yaml" "platform" "resourceset" "$ROOT/tests/inputs/platform/$tree"
}

run_pass() { # run_pass <tree> <mode: keyless|keyed>
  local tree="$1" mode="$2" dir name
  local out="$BUILD/$tree-$mode"
  mkdir -p "$out"
  echo ">> [$tree/$mode] building components"
  for dir in "$ROOT/components"/*/"$tree"/; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$(dirname "$dir")")"
    kustomize build "$dir" > "$out/raw-$name.yaml"
    substitute "$out/raw-$name.yaml" "$out/component-$name.yaml"
  done
  echo ">> [$tree/$mode] building the platform entrypoint"
  kustomize build "$ROOT/platform/$tree" > "$out/raw-platform.yaml"
  substitute "$out/raw-platform.yaml" "$out/component-platform.yaml"
  echo ">> [$tree/$mode] rendering resourcesets with sample inputs"
  render_resourcesets "$tree" "$out"
}

# The entrypoint is the graph, so it must be complete: every component
# overlay the tree ships is pulled by an emitted OCIRepository
# (platform-<name>) under the all-elected render, nothing is emitted that
# the tree does not ship, and every dependsOn it emits names a
# Kustomization that something emits -- the entrypoint itself, or a
# component ResourceSet (gateway-api-crds rides the gateway component's
# resourceset-crds.yaml). A dangling dependsOn freezes the dependant
# forever, which is exactly what this guard exists to catch. Every one of
# those Kustomizations must also find its path in the image it reads:
# platform-<name> carries components/<name>, flux-system carries
# platform/. A path that is not in the image fails only on a cluster.
check_entrypoint_complete() { # check_entrypoint_complete <tree> <render-dir>
  local tree="$1" out="$2" rendered="$2/rendered-platform-resourceset.yaml" shipped emitted name dep bad=0 known
  shipped="$(shipped_components "$tree")"
  emitted="$(yq_values 'select(.kind == "OCIRepository") | .metadata.name' "$rendered" | sed 's/^platform-//')"
  for name in $shipped; do
    in_set "$name" "$emitted" || { echo "entrypoint completeness: components/$name/$tree exists but platform/$tree emits no platform-$name OCIRepository" >&2; bad=1; }
  done
  for name in $emitted; do
    in_set "$name" "$shipped" || { echo "entrypoint completeness: platform/$tree emits platform-$name but components/$name/$tree does not exist" >&2; bad=1; }
  done
  # Every Flux Kustomization anything emits for this tree (the
  # entrypoint's plus the component ResourceSets').
  known="$(yq_values 'select(.kind == "Kustomization" and .apiVersion == "kustomize.toolkit.fluxcd.io/v1") | .metadata.name' "$out"/rendered-*.yaml)"
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    in_set "$dep" "$known" || { echo "entrypoint completeness: a dependsOn names $dep but nothing emits a Kustomization by that name on $tree" >&2; bad=1; }
  done < <(yq_values 'select(.kind == "Kustomization") | .spec.dependsOn[]?.name' "$rendered")
  local ks source path image
  while IFS=' ' read -r ks source path; do
    [[ -n "$ks" ]] || continue
    case "$source" in
      platform-*) image="components/${source#platform-}" ;;
      flux-system) image="platform" ;;
      *) echo "entrypoint completeness: Kustomization $ks reads $source, which is neither platform-<name> nor flux-system" >&2; bad=1; continue ;;
    esac
    [[ -f "$ROOT/$image/${path#./}/kustomization.yaml" ]] || { echo "entrypoint completeness: Kustomization $ks reads $path from $source, but $image/${path#./} has no kustomization.yaml" >&2; bad=1; }
  done < <(yq e 'select(.kind == "Kustomization" and .apiVersion == "kustomize.toolkit.fluxcd.io/v1") | [.metadata.name, .spec.sourceRef.name, .spec.path] | join(" ")' "$out"/rendered-*.yaml | grep -v '^---$' | sort -u)
  [[ "$bad" -eq 0 ]] || exit 1
}

# The core tier deploys whatever the election says: under the reserved
# "none" election the entrypoint must still emit every non-electable
# component, and nothing electable.
check_election_independent() { # check_election_independent <tree> <render-dir>
  local tree="$1" none="$2/rendered-platform-resourceset.none.yaml" shipped emitted electable name bad=0
  shipped="$(shipped_components "$tree")"
  emitted="$(yq_values 'select(.kind == "OCIRepository") | .metadata.name' "$none" | sed 's/^platform-//')"
  # shellcheck disable=SC2086 # the list is deliberately word-split
  electable="$(printf '%s\n' $ELECTABLE)"
  for name in $shipped; do
    if in_set "$name" "$electable"; then
      ! in_set "$name" "$emitted" || { echo "election independence: $name is electable but platform/$tree emits it under the none election" >&2; bad=1; }
    else
      in_set "$name" "$emitted" || { echo "election independence: $name is core but platform/$tree drops it under the none election" >&2; bad=1; }
    fi
  done
  [[ "$bad" -eq 0 ]] || exit 1
}

# patchy.yaml lists what `patchy build` publishes, one entry per artifact, in
# publish order. A component missing there would ship in the tree but never
# reach a registry, so every components/<name> must have an entry, and the
# entrypoint must come last so it never references a component build that is
# not there yet.
check_publish_complete() {
  local listed name bad=0
  listed="$(yq '.build.manifests[].path' "$ROOT/patchy.yaml")"
  for name in $(find "$ROOT/components" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort); do
    in_set "components/$name" "$listed" || { echo "publish completeness: components/$name has no build.manifests entry in patchy.yaml" >&2; bad=1; }
  done
  [[ "$(printf '%s\n' "$listed" | tail -n 1)" == "platform" ]] || { echo "publish completeness: the platform entrypoint must be the last build.manifests entry in patchy.yaml" >&2; bad=1; }
  [[ "$bad" -eq 0 ]] || exit 1
}

# The null guard is the regression fence for a bug class local rendering
# used to hide; prove it still fires before trusting a green run.
echo ">> null-guard self-test"
"$HELPERS/flux-substitute.sh" --self-test

echo ">> publish completeness"
check_publish_complete

echo ">> common neutrality + per-tree dead-default guards"
check_common_neutral
check_dead_defaults aws "$AWS_VARS" "$GOOGLE_VARS"
check_dead_defaults google "$GOOGLE_VARS" "$AWS_VARS"

for tree in google aws; do
  for mode in keyless keyed; do
    # Each pass runs in a subshell so one cloud's env can never leak into
    # the other's render -- absence of the other cloud's vars is part of
    # what is being tested.
    (
      set -a
      # shellcheck disable=SC1090
      source "$ROOT/tests/$tree.env"
      if [[ "$mode" == "keyed" ]]; then
        # shellcheck disable=SC1090
        source "$ROOT/tests/$tree.keyed.env"
      fi
      set +a
      run_pass "$tree" "$mode"
    )
  done
  echo ">> [$tree] entrypoint completeness + election independence"
  check_entrypoint_complete "$tree" "$BUILD/$tree-keyless"
  check_election_independent "$tree" "$BUILD/$tree-keyless"
done

echo ">> kubeconform"
# Component CRD schemas are vendored under tests/schemas (converted from
# upstream CRDs); refresh with:
#   curl <crd-yaml> | yq -o=json '.spec.versions[0].schema.openAPIV3Schema'
# CustomResourceDefinition is skipped (kubeconform.sh's default): the
# standalone schema catalogs carry no schema for it, and the vendored gateway
# CRDs are upstream-generated and arrive verbatim.
KUBECONFORM_SCHEMAS="$ROOT/tests/schemas" "$HELPERS/kubeconform.sh" \
  "$BUILD"/*/component-*.yaml "$BUILD"/*/rendered-*.yaml

echo ">> validation clean"
