#!/usr/bin/env bash
# One-way, fail-closed projection of Firstmate work onto Linear.
#
# Usage:
#   fm-linear-projection.sh sync
#   fm-linear-projection.sh schema-check
#
# `sync` requires FM_LINEAR_PROJECTION_ENABLED=1, LINEAR_API_KEY, and the
# config/linear-projection.json contract documented in docs/configuration.md.
# It reads the canonical captain queue through fm-captain-queue.sh --json,
# resolves stages only from state/stage-transitions.tsv, and never writes the
# backlog, archive, or stage ledger.
# Projection receipts live in the private state/linear-projection.json journal.
# A validated state/linear-pr-receipts/<task-id>.receipt preserves canonical GitHub PR identity across teardown before the first sync.
#
# Set FM_LINEAR_TRANSPORT to an executable that accepts one GraphQL request on
# stdin and returns {"status":<http-status>,"body":<graphql-json>} for tests or
# alternate egress. Set FM_GITHUB_STATUS_TRANSPORT to an executable that accepts
# a PR URL and returns {"state":...,"checks":...}. Both transports are captured;
# their output is never copied into an error or run summary.
#
# `schema-check` is an explicit unauthenticated live-schema probe. It is separate
# from sync, requires no token, and validates every document this projection can
# send against Linear's current introspection result and validation endpoint.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-linear-projection.py" "$@"
