#!/usr/bin/env bash
# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Publish the platform as OCI artifacts: one image per component
# (oci://<registry>/manifests/<name> from components/<name>) and the
# entrypoint (oci://<registry>/manifests/platform from platform/), to every
# registry in $REGISTRIES. Called by the publish workflows; runnable by hand
# against a scratch prefix.
#
#   publish.sh push <tag> <revision>   push + sign every component, then
#                                      the entrypoint LAST - a channel or
#                                      version tag never points at an
#                                      entrypoint whose components are not
#                                      yet there
#   publish.sh tag <from> <to>         re-tag every image (components first,
#                                      entrypoint last), after a pull sanity
#                                      check on <from>
#
# Environment:
#   REGISTRIES   space-separated registry prefixes (<host>/<prefix>), each
#                already logged in through the docker keychain
#   SOURCE       the source URL recorded in the artifact (repo URL)
#   COSIGN_KEY   optional: a cosign key reference (awskms:///..., gcpkms://...)
#                for KMS signing mode; unset signs keylessly (the default,
#                what the clusters' SIGNED_IDENTITY_MANIFESTS verifies)
#
# cosign v3 stores the signature as a sigstore bundle via the OCI referrers
# API; flux >= 2.8 reads that format. --use-signing-config=false only pins
# the v2 trust services (Fulcio + Rekor v1) - it does not change the format.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  sed -n '5,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[[ $# -eq 3 ]] || usage
: "${REGISTRIES:?REGISTRIES must list at least one registry prefix}"

# name=path pairs, components first and the entrypoint last.
images() {
  local dir
  for dir in "$ROOT"/components/*/; do
    echo "$(basename "$dir")=components/$(basename "$dir")"
  done
  echo "platform=platform"
}

sign() { # sign <image@digest>
  if [[ -n "${COSIGN_KEY:-}" ]]; then
    cosign sign --yes --key "$COSIGN_KEY" "$1"
  else
    cosign sign --yes --use-signing-config=false "$1"
  fi
}

push() { # push <tag> <revision>
  local tag="$1" revision="$2" entry name path registry url digest
  : "${SOURCE:?SOURCE must name the source URL recorded in the artifacts}"
  for entry in $(images); do
    name="${entry%%=*}"
    path="${entry#*=}"
    for registry in $REGISTRIES; do
      url="oci://$registry/manifests/$name"
      digest="$(flux push artifact "$url:$tag" \
        --path "$ROOT/$path" \
        --source "$SOURCE" \
        --revision "$revision" \
        --output json | jq -r .digest)"
      sign "$registry/manifests/$name@$digest"
      echo "pushed $url:$tag ($digest)"
    done
  done
}

tag() { # tag <from> <to>
  local from="$1" to="$2" entry name registry url scratch
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/publish.XXXXXX")"
  trap 'rm -rf "$scratch"' EXIT
  for entry in $(images); do
    name="${entry%%=*}"
    for registry in $REGISTRIES; do
      url="oci://$registry/manifests/$name"
      # sanity: the source tag must exist (and be pullable) before the
      # channel moves - a typo must never strand a channel on nothing
      flux pull artifact "$url:$from" --output "$scratch/$name" > /dev/null
      flux tag artifact "$url:$from" --tag "$to"
      echo "tagged $url:$from -> $to"
    done
  done
}

case "$1" in
  push) push "$2" "$3" ;;
  tag) tag "$2" "$3" ;;
  *) usage ;;
esac
