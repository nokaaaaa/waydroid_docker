#!/usr/bin/env bash
# Create and publish the encrypted state needed by a fresh clone.
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
"$script_dir/create-portable-snapshot.sh"
"$script_dir/publish-portable-snapshot.sh"

