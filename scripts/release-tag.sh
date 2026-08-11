#!/usr/bin/env bash
set -euo pipefail

repo=${1:?repository path required}
source_sha="$(git -C "$repo" rev-list -1 HEAD -- . ':(exclude).github/**')"
[[ -n "$source_sha" ]]
epoch="$(git -C "$repo" show -s --format=%ct "$source_sha")"
stamp="$(date -u --date="@$epoch" +%Y%m%dT%H%M%SZ)"
short_sha="$(git -C "$repo" rev-parse --short=12 "$source_sha")"
printf '%s-%s\n' "$stamp" "$short_sha"
