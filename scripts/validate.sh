#!/usr/bin/env bash
# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Render and validate everything each cluster would apply, once per tree
# and signing mode ({google,aws} x {keyless,keyed}):
#   1. kustomize-build each component (common/ + the tree's) and the tree root
#   2. substitute cluster-vars the way the Kustomizations do (postBuild),
#      faithfully to the controller's roundtrip -- so an empty var that
#      would become null on a cluster becomes null (and fails) here
#   3. render ResourceSets with sample inputs (flux-operator CLI)
#   4. kubeconform the results against Flux + flux-operator + component CRD
#      schemas
# plus the structural guards that keep the tree split honest:
#   - common/ may not branch on cloud, and may reference a var published by
#     only one cloud's module solely through a := default
#   - a per-cloud tree may not carry a := default whose only purpose was to
#     survive the other cloud's strict substitution
#   - no ${VAR}-bearing quoted scalar may substitute to null (the guard
#     self-tests at startup, so it cannot rot)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build"
rm -rf "$BUILD" && mkdir -p "$BUILD"

command -v kustomize >/dev/null || { echo "kustomize not found" >&2; exit 1; }
command -v kubeconform >/dev/null || { echo "kubeconform not found" >&2; exit 1; }
command -v flux-operator >/dev/null || { echo "flux-operator CLI not found" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq not found" >&2; exit 1; }

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

# common/ serves both clusters verbatim: no cloud branching, and any var
# only one cloud's module publishes may be referenced solely through a :=
# default (that is the per-cluster election mechanism -- the other cloud's
# passes render the election-absent arm, and the null guard proves it
# renders safely). A BARE single-cloud ${VAR} would fail strict
# substitution on the other cluster.
check_common_neutral() {
  local hits var bad=0
  # shellcheck disable=SC2016 # grep pattern
  if hits="$(grep -REn 'inputs\.cloud|\$\{CLOUD[:}]' "$ROOT/common" 2>/dev/null)"; then
    { echo "common/ must not branch on cloud:"; printf '%s\n' "$hits" | sed 's/^/  /'; } >&2
    exit 1
  fi
  # shellcheck disable=SC2016 # the dollar-brace is the grep pattern, not an expansion
  while IFS= read -r var; do
    [[ -n "$var" ]] || continue
    if in_set "$var" "$AWS_VARS" && ! in_set "$var" "$GOOGLE_VARS"; then
      echo "common/ neutrality: bare \${$var} but $var is only in the aws env contract -- google's strict substitution would fail; guard it with a := default" >&2
      bad=1
    elif in_set "$var" "$GOOGLE_VARS" && ! in_set "$var" "$AWS_VARS"; then
      echo "common/ neutrality: bare \${$var} but $var is only in the google env contract -- aws's strict substitution would fail; guard it with a := default" >&2
      bad=1
    fi
  done < <(grep -RhoE '\$\{[A-Z][A-Z0-9_]*\}' "$ROOT/common" | tr -d '${}' | sort -u)
  [[ "$bad" -eq 0 ]] || exit 1
}

# In a per-cloud tree, a := default over a var that tree's own module
# ALWAYS publishes -- and the other cloud's never does -- is dead code left
# over from the shared-tree era, kept alive only to survive the other
# cloud's strict substitution. Genuinely caller-optional defaults (vars in
# neither contract, or in both) stay.
check_dead_defaults() { # check_dead_defaults <tree> <own-set> <other-set>
  local tree="$1" own="$2" other="$3" var bad=0
  while IFS= read -r var; do
    [[ -n "$var" ]] || continue
    if in_set "$var" "$own" && ! in_set "$var" "$other"; then
      echo "dead default: \${$var:=...} under $tree/ but $var is in $tree's env contract alone -- the default only survived the other cloud; make it a bare \${$var}" >&2
      bad=1
    fi
  done < <(grep -RhoE '\$\{[A-Z][A-Z0-9_]*:=' "$ROOT/$tree" | sed 's/^..//; s/:=$//' | sort -u)
  [[ "$bad" -eq 0 ]] || exit 1
}

# Every ResourceSet must have a matching inputs fixture:
# tests/inputs/{<tree>,common}/<component>/<file>[.<variant>].yaml, the tree
# directory shadowing common per basename. Two fixture shapes: a plain list
# of input sets (--inputs-from), or Static ResourceSetInputProvider
# manifests (--inputs-from-provider) for ResourceSets using the Permute
# strategy -- Permute namespaces inputs by provider name, and only
# provider-shaped fixtures reproduce that in the render.
render_resourcesets() { # render_resourcesets <tree> <out-dir>
  local tree="$1" out="$2" rs comp file primary vbase variants inputs variant inputs_flag
  for rs in "$ROOT/common/components"/*/resourceset*.yaml "$ROOT/$tree/components"/*/resourceset*.yaml; do
    [[ -f "$rs" ]] || continue
    comp="$(basename "$(dirname "$rs")")"
    file="$(basename "$rs" .yaml)"
    primary=""
    if [[ -f "$ROOT/tests/inputs/$tree/$comp/$file.yaml" ]]; then
      primary="$ROOT/tests/inputs/$tree/$comp/$file.yaml"
    elif [[ -f "$ROOT/tests/inputs/common/$comp/$file.yaml" ]]; then
      primary="$ROOT/tests/inputs/common/$comp/$file.yaml"
    fi
    [[ -n "$primary" ]] || { echo "missing test inputs tests/inputs/{$tree,common}/$comp/$file.yaml for $rs" >&2; exit 1; }
    substitute "$rs" "$out/rs-$comp-$file.yaml"
    # The primary fixture plus any <file>.<variant>.yaml siblings: each
    # renders the same ResourceSet with a different input set, so every
    # side of an input branch (elections) gets rendered and
    # kubeconform-validated.
    variants="$( { ls "$ROOT/tests/inputs/common/$comp/" 2>/dev/null || true; ls "$ROOT/tests/inputs/$tree/$comp/" 2>/dev/null || true; } \
      | grep -E "^$file(\.[A-Za-z0-9-]+)?\.yaml$" | sort -u )"
    for vbase in $variants; do
      if [[ -f "$ROOT/tests/inputs/$tree/$comp/$vbase" ]]; then
        inputs="$ROOT/tests/inputs/$tree/$comp/$vbase"
      else
        inputs="$ROOT/tests/inputs/common/$comp/$vbase"
      fi
      variant="$(basename "$vbase" .yaml)"
      inputs_flag="--inputs-from"
      if grep -q "^kind: ResourceSetInputProvider$" "$inputs"; then
        inputs_flag="--inputs-from-provider"
      fi
      # A fixture may sit on the empty side of an input branch (a disabled
      # election) and legitimately render nothing — the CLI treats that as
      # an error, so allow exactly that failure and keep the empty render
      # for kubeconform.
      if ! flux-operator build resourceset -f "$out/rs-$comp-$file.yaml" "$inputs_flag" "$inputs" \
        > "$out/rendered-$comp-$variant.yaml" 2> "$out/rendered-$comp-$variant.err"; then
        grep -q "no objects were generated" "$out/rendered-$comp-$variant.err" \
          || { cat "$out/rendered-$comp-$variant.err" >&2; exit 1; }
        : > "$out/rendered-$comp-$variant.yaml"
      fi
      rm -f "$out/rendered-$comp-$variant.err"
    done
  done
}

run_pass() { # run_pass <tree> <mode: keyless|keyed>
  local tree="$1" mode="$2" dir name
  local out="$BUILD/$tree-$mode"
  mkdir -p "$out"
  echo ">> [$tree/$mode] building components"
  for dir in "$ROOT/common/components"/*/ "$ROOT/$tree/components"/*/; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"
    kustomize build "$dir" > "$out/raw-$name.yaml"
    substitute "$out/raw-$name.yaml" "$out/component-$name.yaml"
  done
  echo ">> [$tree/$mode] rendering resourcesets with sample inputs"
  render_resourcesets "$tree" "$out"
}

echo ">> null-guard self-test"
null_guard_selftest

echo ">> common/ neutrality + per-tree dead-default guards"
check_common_neutral
check_dead_defaults aws "$AWS_VARS" "$GOOGLE_VARS"
check_dead_defaults google "$GOOGLE_VARS" "$AWS_VARS"

for tree in google aws; do
  echo ">> building the $tree tree root"
  kustomize build "$ROOT/$tree" > "$BUILD/stack-$tree.yaml"
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
done

echo ">> kubeconform"
# Component CRD schemas are vendored (converted from upstream CRDs); refresh with:
#   curl <crd-yaml> | yq -o=json '.spec.versions[0].schema.openAPIV3Schema'
# CustomResourceDefinition is skipped: the standalone schema catalogs carry no
# schema for it (the vendored gateway-crds are upstream-generated and arrive
# verbatim — validating them here would only re-check kubebuilder's output).
kubeconform -strict -summary \
  -skip CustomResourceDefinition \
  -schema-location default \
  -schema-location "https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/{{ .ResourceKind }}{{ .KindSuffix }}.json" \
  -schema-location "$ROOT/tests/schemas/{{ .ResourceKind }}-{{ .Group }}-{{ .ResourceAPIVersion }}.json" \
  "$BUILD"/*/component-*.yaml "$BUILD"/*/rendered-*.yaml "$BUILD"/stack-*.yaml

echo ">> validation clean"
