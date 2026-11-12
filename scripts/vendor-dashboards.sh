#!/usr/bin/env bash
# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Vendor the upstream Grafana dashboards the kube-prometheus-stack component
# ships as ConfigMaps (components/kube-prometheus-stack/{common,aws}/dashboards).
# Only dashboards whose charts don't ship their own live here: kyverno and
# cilium deliver theirs through their charts, versioned with the chart.
#
# Each dashboard is pinned to the release of the component it watches. Bump
# the version below when that component's mirrored chart moves, rerun, and
# review the diff.
#
# Every braced variable reference (${DS_PROMETHEUS}, ${datasource}) is
# rewritten to its bare form ($DS_PROMETHEUS). Grafana reads both the same,
# but Flux's postBuild substitution rewrites ${...} and would empty them (and
# make test's strict substitution rejects them). The ConfigMaps also carry
# kustomize.toolkit.fluxcd.io/substitute: disabled; the rewrite is what keeps
# the validation harness, which substitutes whole files, honest.
#
# Usage: scripts/vendor-dashboards.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPONENT="$ROOT/components/kube-prometheus-stack"

# flux-operator's monitoring kit (config/monitoring), at the operator version
# the flux component's mirrored flux-operator chart runs.
FLUX_OPERATOR_VERSION="v0.62.1"
# Karpenter's getting-started dashboards, at the mirrored karpenter chart's
# version.
KARPENTER_VERSION="v1.15.1"

fetch() { # fetch <url> <dest>
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/dashboard.XXXXXX")"
  curl -fsSL "$1" -o "$tmp"
  jq -e '.panels' "$tmp" >/dev/null || { echo "not a dashboard: $1" >&2; rm -f "$tmp"; exit 1; }
  # ${a}b would become $ab, a different variable: refuse rather than mangle.
  if grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*\}[A-Za-z0-9_]' "$tmp"; then
    echo "a braced variable runs into an identifier in $1; vendor it by hand" >&2
    rm -f "$tmp"
    exit 1
  fi
  # ${name} -> $name for plain identifiers; leaves ${__name:fmt} forms (none
  # today) alone so a future one is caught by make test, not silently mangled.
  sed -E 's/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/$\1/g' "$tmp" | jq --indent 2 . >"$2"
  rm -f "$tmp"
  echo "vendored $(basename "$2") from $1"
}

FLUX="https://raw.githubusercontent.com/controlplaneio-fluxcd/flux-operator/$FLUX_OPERATOR_VERSION/config/monitoring/dashboards"
fetch "$FLUX/flux-performance.json" "$COMPONENT/common/dashboards/flux-performance.json"
fetch "$FLUX/flux-k8s-api-performance.json" "$COMPONENT/common/dashboards/flux-k8s-api-performance.json"

KARPENTER="https://raw.githubusercontent.com/aws/karpenter-provider-aws/$KARPENTER_VERSION/website/content/en/docs/getting-started/getting-started-with-karpenter"
fetch "$KARPENTER/karpenter-capacity-dashboard.json" "$COMPONENT/aws/dashboards/karpenter-capacity.json"
fetch "$KARPENTER/karpenter-performance-dashboard.json" "$COMPONENT/aws/dashboards/karpenter-performance.json"
