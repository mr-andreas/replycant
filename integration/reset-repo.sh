#!/bin/bash
set -euo pipefail

seed="${1:-true}"

rm -rf /tmp/repo.git /tmp/identity
git init --initial-branch=main --bare /tmp/repo.git
git -C /tmp/repo.git config http.receivepack true

if [[ "$seed" == "true" ]]; then
  seeder --bare-repo=/tmp/repo.git --output-dir=/tmp/identity
fi
