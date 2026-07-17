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
# output.
substitute() { # substitute <in-file> <out-file>
  yq ea '(.. | select(tag == "!!str")) |= envsubst' "$1" > "$2"
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

echo ">> rendering resourcesets with sample inputs"
# Every ResourceSet must have a matching inputs fixture: tests/inputs/<component>/<file>.yaml
for rs in "$ROOT"/components/*/resourceset*.yaml; do
  comp="$(basename "$(dirname "$rs")")"
  file="$(basename "$rs" .yaml)"
  inputs="$ROOT/tests/inputs/$comp/$file.yaml"
  [[ -f "$inputs" ]] || { echo "missing test inputs $inputs for $rs" >&2; exit 1; }
  substitute "$rs" "$BUILD/rs-$comp-$file.yaml"
  flux-operator build resourceset -f "$BUILD/rs-$comp-$file.yaml" --inputs-from "$inputs" \
    > "$BUILD/rendered-$comp-$file.yaml"
done

echo ">> kubeconform"
# Component CRD schemas are vendored (converted from upstream CRDs); refresh with:
#   curl <crd-yaml> | yq -o=json '.spec.versions[0].schema.openAPIV3Schema'
kubeconform -strict -summary \
  -schema-location default \
  -schema-location "https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/{{ .ResourceKind }}{{ .KindSuffix }}.json" \
  -schema-location "$ROOT/tests/schemas/{{ .ResourceKind }}-{{ .Group }}-{{ .ResourceAPIVersion }}.json" \
  "$BUILD"/component-*.yaml "$BUILD"/stack.yaml "$BUILD"/rendered-*.yaml

echo ">> validation clean"
