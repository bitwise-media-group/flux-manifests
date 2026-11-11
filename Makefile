# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT
#
# flux-manifests — the GitOps stack every platform cluster syncs, packaged as
# keyless-cosign-signed Flux OCI artifacts in the platform Artifact Registry
# (immutable edge builds, promoted to stable vX.Y.Z releases).
#
# Everything lives in mise tasks: the shared toolchain submodule at .mise/
# provides the pinned tools, the common lint contract and the containers
# archetype's build and publish tasks (selected in the root mise.toml), and
# tasks.toml carries the validation harness. This Makefile is only the thin
# forwarding shim — `make <task>` == `mise run <task>`.
include .mise/archetypes/containers/include.mk
