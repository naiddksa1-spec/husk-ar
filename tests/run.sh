#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Portable offline checks. Does not claim to build or run the iOS app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo '== security and guest-agent regression checks'
python3 tests/security/test_hardening.py

echo '== shell syntax'
for file in scripts/*.sh tests/run.sh tests/translation-layer/run.sh; do
    bash -n "$file"
done
python3 - <<'PY'
from pathlib import Path
root = Path('.')
files = list(root.glob('scripts/*.py')) + list(root.glob('tests/**/*.py'))
for path in files:
    compile(path.read_text(), str(path), 'exec')
print(f'checked Python syntax in {len(files)} files')
PY

echo '== translation-layer host tests'
bash tests/translation-layer/run.sh

echo 'all available portable tests passed; skipped device tests remain unverified'
