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
#      would become null on a cluster becomes null (and fails) here
#   3. render ResourceSets with sample inputs (flux-operator CLI), the
#      platform entrypoint included (every component elected, and the
#      reserved "none" election)
#   4. kubeconform the results against Flux + flux-operator + component CRD
#      schemas
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
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build"
rm -rf "$BUILD" && mkdir -p "$BUILD"

command -v kustomize >/dev/null || { echo "kustomize not found" >&2; exit 1; }
command -v kubeconform >/dev/null || { echo "kubeconform not found" >&2; exit 1; }
command -v flux-operator >/dev/null || { echo "flux-operator CLI not found" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq not found" >&2; exit 1; }

# The electable tier: the only components the platform ResourceSet gates on
# PLATFORM_COMPONENTS. Everything else under components/ is core and must
# be emitted whatever the election says (the election-independence guard).
ELECTABLE="dex flux-web arc"

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

# kustomize-controller substitutes in STRICT mode: a bare ${VAR} fails the
# whole Kustomization on any cluster whose cluster-vars never publishes VAR
# (a ${VAR:=default} never does -- := satisfies strict even when unset).
# Mirror that here so each tree's passes, run under only that cloud's env,
# fail the same way the cluster would.
check_strict() { # check_strict <in-file>
  local var
  # shellcheck disable=SC2016 # the dollar-brace is the grep pattern, not an expansion
  while IFS= read -r var; do
    # ${!var+x}: set-ness via indirect expansion ([[ -v ]] needs bash 4+,
    # and macOS ships 3.2)
    [[ -n "${!var+x}" ]] || { echo "strict substitution: \${$var} in $1 but $var is not set in the env" >&2; exit 1; }
  done < <(grep -oE '\$\{[A-Z][A-Z0-9_]*\}' "$1" | tr -d '${}' | sort -u)
}

# After substitution, no path that held a ${VAR}-bearing string may hold
# null: that is exactly the cluster failure mode where the controller's
# roundtrip strips redundant quotes and an empty value re-parses as null
# (helm schemas and CRDs then reject the key). Fix at the source per the
# empty-var convention: gate the key absent, template-quote (`| quote`),
# or move the value into a resourcesTemplate block scalar.
null_guard() { # null_guard <pre-file> <post-file>
  local pre nulls hits
  # shellcheck disable=SC2016 # yq expressions, not shell expansions
  pre="$(yq ea '.. | select(tag == "!!str") | select(test("\$\{[A-Z]")) | ([document_index] + path | join("/"))' "$1" | sort -u)"
  nulls="$(yq ea '.. | select(tag == "!!null") | ([document_index] + path | join("/"))' "$2" | sort -u)"
  hits="$(comm -12 <(printf '%s\n' "$pre") <(printf '%s\n' "$nulls") | grep -v '^$' || true)"
  if [[ -n "$hits" ]]; then
    {
      echo "null substitution in $2 -- these \${VAR}-bearing scalars became null (doc/path):"
      printf '%s\n' "$hits" | sed 's/^/  /'
      echo "an empty var in a bare quoted scalar round-trips to null on the cluster;"
      echo "gate the key absent, use << \"\${VAR:=}\" | quote >>, or move it into a"
      echo "resourcesTemplate block (see README: the empty-var convention)"
    } >&2
    exit 1
  fi
}

# Substitute cluster vars the way kustomize-controller's postBuild does on a
# real cluster: the resource is parsed, re-serialized (AsYAML -- redundant
# quotes drop, styles normalize), TEXTUALLY envsubst-ed, and re-parsed.
# Faithfulness matters: substituting structurally (into parsed string
# values) would preserve string types that the cluster loses, hiding the
# empty-var null bug class this harness exists to catch. yq's envsubst also
# eats bare $VAR (dex's $-refs, Go template $variables) where the
# controller only substitutes the braced form -- shield those behind a
# sentinel so the render matches the cluster.
substitute() { # substitute <in-file> <out-file>
  check_strict "$1"
  # shellcheck disable=SC2016 # yq expression
  yq ea '(.. | select(kind == "scalar")) style=""' "$1" > "$2.norm"
  # shellcheck disable=SC2016 # ${1} and $$ are yq syntax; single quotes are deliberate
  IN_FILE="$2.norm" yq -n 'load_str(strenv(IN_FILE)) | sub("\$([^{])"; "@BARE_DOLLAR@${1}") | envsubst | sub("@BARE_DOLLAR@"; "$$")' > "$2"
  null_guard "$2.norm" "$2"
  rm -f "$2.norm"
}

# The null guard is the regression fence for a bug class local rendering
# used to hide; prove it still fires before trusting a green run.
null_guard_selftest() {
  local dir="$BUILD/selftest"
  mkdir -p "$dir"
  cat > "$dir/canary.yaml" <<'YAML'
canary:
  trip: "${VALIDATE_SELFTEST_EMPTY}"
  control: "${VALIDATE_SELFTEST_PRESENT}"
YAML
  export VALIDATE_SELFTEST_EMPTY="" VALIDATE_SELFTEST_PRESENT="present"
  if (substitute "$dir/canary.yaml" "$dir/canary.out.yaml") 2> /dev/null; then
    echo "self-test: null_guard did NOT trip on an empty-var quoted scalar -- the guard has rotted, aborting" >&2
    exit 1
  fi
  export VALIDATE_SELFTEST_EMPTY="non-empty"
  substitute "$dir/canary.yaml" "$dir/canary.out.yaml" \
    || { echo "self-test: substitute failed its positive control" >&2; exit 1; }
  unset VALIDATE_SELFTEST_EMPTY VALIDATE_SELFTEST_PRESENT
  rm -rf "$dir"
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
# forever, which is exactly what this guard exists to catch.
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

echo ">> null-guard self-test"
null_guard_selftest

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
# Component CRD schemas are vendored (converted from upstream CRDs); refresh with:
#   curl <crd-yaml> | yq -o=json '.spec.versions[0].schema.openAPIV3Schema'
# CustomResourceDefinition is skipped: the standalone schema catalogs carry no
# schema for it (the vendored gateway CRDs are upstream-generated and arrive
# verbatim -- validating them here would only re-check kubebuilder's output).
kubeconform -strict -summary \
  -skip CustomResourceDefinition \
  -schema-location default \
  -schema-location "https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/{{ .ResourceKind }}{{ .KindSuffix }}.json" \
  -schema-location "$ROOT/tests/schemas/{{ .ResourceKind }}-{{ .Group }}-{{ .ResourceAPIVersion }}.json" \
  "$BUILD"/*/component-*.yaml "$BUILD"/*/rendered-*.yaml

echo ">> validation clean"
