#!/bin/bash
# Tests unitarios de todo el repo.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path Packages/VMCore
