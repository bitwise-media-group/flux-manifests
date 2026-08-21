#!/usr/bin/env bash
# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Render and validate everything a cluster would apply:
#   1. kustomize-build each component and the stack
#   2. substitute cluster-vars the way the Kustomizations do (postBuild)
#   3. render ResourceSets with sample inputs (flux-operator CLI)
#   4. kubeconform the results against Flux + flux-operator + component CRD schemas
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build"
rm -rf "$BUILD" && mkdir -p "$BUILD"

command -v kustomize >/dev/null || { echo "kustomize not found" >&2; exit 1; }
command -v kubeconform >/dev/null || { echo "kubeconform not found" >&2; exit 1; }
command -v flux-operator >/dev/null || { echo "flux-operator CLI not found" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq not found" >&2; exit 1; }

# Substitute dollar-brace vars the way kustomize-controller postBuild does:
# structurally, into parsed string values (textual envsubst would break
# quoting of values like ">=1.18.0 <2.0.0"). yq re-quotes scalars correctly on
# output. kustomize-controller only substitutes the braced ${VAR} form, but
# yq's envsubst also eats bare $VAR (dex's $-refs, Go template $variables) --
# shield those behind a sentinel so the render matches the cluster.
substitute() { # substitute <in-file> <out-file>
  # shellcheck disable=SC2016 # ${1} and $$ are yq syntax; single quotes are deliberate
  yq ea '(.. | select(tag == "!!str")) |= (sub("\$([^{])"; "@BARE_DOLLAR@${1}") | envsubst | sub("@BARE_DOLLAR@"; "$$"))' "$1" > "$2"
}

# Load the sample cluster-vars into the environment for envsubst.
set -a
# shellcheck disable=SC1091
source "$ROOT/tests/cluster-vars.env"
set +a

echo ">> building components"
for dir in "$ROOT"/components/*/; do
  [[ -d "$dir" ]] || continue
  name="$(basename "$dir")"
  kustomize build "$dir" > "$BUILD/raw-$name.yaml"
  substitute "$BUILD/raw-$name.yaml" "$BUILD/component-$name.yaml"
done

echo ">> building the stack"
kustomize build "$ROOT/stack" > "$BUILD/stack.yaml"

# Every ResourceSet must have a matching inputs fixture: tests/inputs/<component>/<file>.yaml
# Two fixture shapes: a plain list of input sets (--inputs-from), or Static
# ResourceSetInputProvider manifests (--inputs-from-provider) for ResourceSets
# using the Permute strategy -- Permute namespaces inputs by provider name, and
# only provider-shaped fixtures reproduce that in the render.
render_resourcesets() { # render_resourcesets <prefix>
  local prefix="$1" rs comp file inputs variant inputs_flag
  for rs in "$ROOT"/components/*/resourceset*.yaml; do
    comp="$(basename "$(dirname "$rs")")"
    file="$(basename "$rs" .yaml)"
    [[ -f "$ROOT/tests/inputs/$comp/$file.yaml" ]] || { echo "missing test inputs tests/inputs/$comp/$file.yaml for $rs" >&2; exit 1; }
    substitute "$rs" "$BUILD/rs-$prefix$comp-$file.yaml"
    # The primary fixture plus any <file>.<variant>.yaml siblings (e.g.
    # resourceset-secrets.aws.yaml): each renders the same ResourceSet with a
    # different input set, so both sides of an input branch (CLOUD, elections)
    # get rendered and kubeconform-validated.
    for inputs in "$ROOT/tests/inputs/$comp/$file.yaml" "$ROOT/tests/inputs/$comp/$file".*.yaml; do
      [[ -f "$inputs" ]] || continue
      variant="$(basename "$inputs" .yaml)"
      inputs_flag="--inputs-from"
      if grep -q "^kind: ResourceSetInputProvider$" "$inputs"; then
        inputs_flag="--inputs-from-provider"
      fi
      # A fixture may sit on the empty side of an input branch (the CRDs
      # install on google, a disabled election) and legitimately render
      # nothing — the CLI treats that as an error, so allow exactly that
      # failure and keep the empty render for kubeconform.
      if ! flux-operator build resourceset -f "$BUILD/rs-$prefix$comp-$file.yaml" "$inputs_flag" "$inputs" \
        > "$BUILD/rendered-$prefix$comp-$variant.yaml" 2> "$BUILD/rendered-$prefix$comp-$variant.err"; then
        grep -q "no objects were generated" "$BUILD/rendered-$prefix$comp-$variant.err" \
          || { cat "$BUILD/rendered-$prefix$comp-$variant.err" >&2; exit 1; }
        : > "$BUILD/rendered-$prefix$comp-$variant.yaml"
      fi
      rm -f "$BUILD/rendered-$prefix$comp-$variant.err"
    done
  done
}

echo ">> rendering resourcesets with sample inputs"
render_resourcesets ""

echo ">> rendering resourcesets with the keyed-signing cluster vars"
# Substitution branches (KMS signing mode, the aws provider election) live in
# ${VAR}s baked in BEFORE the inputs render, so they need a second env, not a
# fixture variant: overlay the keyed convention and render everything again.
set -a
# shellcheck disable=SC1091
source "$ROOT/tests/cluster-vars-keyed.env"
set +a
render_resourcesets "keyed-"

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
  "$BUILD"/component-*.yaml "$BUILD"/stack.yaml "$BUILD"/rendered-*.yaml

echo ">> validation clean"
