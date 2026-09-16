#!/usr/bin/env bash
# Copy the public lead-intake contract out of the API repo and into this one.
#
# Source of truth is docs/public-api/ in provident-broker-api — the handbook and its
# OpenAPI twin are hand-written there and hand-kept in step. This script is the only
# thing that moves them here. Mintlify builds this repo on every push to main.
#
# Usage:  ./sync.sh [path-to-provident-broker-api]
#         defaults to ../provident-broker-api
set -euo pipefail

DOCS_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_REPO="${1:-$(cd "$DOCS_REPO/.." && pwd)/provident-broker-api}"
SRC="$API_REPO/docs/public-api"

[ -d "$SRC" ] || { echo "error: no docs/public-api in $API_REPO" >&2; exit 1; }

# 1. The spec goes across byte for byte. Every page in the API Reference tab is
#    generated from it at build time, so nothing about it is hand-maintained.
cp "$SRC/provident-lead-intake-openapi.json" "$DOCS_REPO/api-reference/openapi.json"

#    It is written a second time at the repo root under its original name: that is the
#    path this repo shipped with before Mintlify, so a raw.githubusercontent.com link
#    already handed to an integrator keeps resolving. Both copies are written from the
#    same source on every sync, so the two cannot drift apart.
cp "$SRC/provident-lead-intake-openapi.json" "$DOCS_REPO/provident-lead-intake-openapi.json"

# 2. The handbook becomes one MDX page. The body is copied verbatim except for two
#    deterministic fixes: the leading H1 is dropped (Mintlify renders the frontmatter
#    title as the page heading, so keeping it would print the title twice), and the
#    "next to this file" relative link to the JSON is repointed at the hosted spec.
{
  printf -- '---\n'
  printf -- 'title: "Lead Intake API"\n'
  printf -- 'description: "The complete integration handbook for POST /v2/public/leads — authentication, every field, matching, webhooks and reference data."\n'
  printf -- '---\n\n'
  tail -n +2 "$SRC/PROVIDENT_LEAD_INTAKE_API.md" \
    | sed 's#(\./provident-lead-intake-openapi\.json)#(/api-reference/openapi.json)#g'
} > "$DOCS_REPO/lead-intake-api.mdx"

VERSION=$(python3 -c "import json;print(json.load(open('$SRC/provident-lead-intake-openapi.json'))['info']['version'])")
echo "Synced spec v$VERSION + handbook from $API_REPO"
git -C "$DOCS_REPO" status --short
echo "Review, then commit and push — Mintlify publishes from main."
