# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT
#
# flux-manifests — the GitOps stack every platform cluster syncs, packaged as
# a keyless-cosign-signed OCI artifact in the platform Artifact Registry
# (staging/stable channel tags).
#
# Everything lives in mise tasks: the shared toolchain submodule at .mise/
# provides the pinned tools + universal lint tasks, and tasks.toml carries the
# validation surface. This Makefile is only the thin forwarding shim —
# `make <task>` == `mise run <task>`.
include .mise/mise.mk
