#!/bin/bash
# Produces development artifacts; distribution signing is a separate explicit step.
set -euo pipefail
RILL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RILL_ROOT"
zsh scripts/package.sh
RILL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' dist/Rill.app/Contents/Info.plist)"
RILL_ARCH="$(uname -m)"
RILL_NAME="Rill-${RILL_VERSION}-${RILL_ARCH}-development"
RILL_STAGE="$(mktemp -d "$RILL_ROOT/dist/.rill-dmg.XXXXXX")"
trap 'rmdir "$RILL_STAGE" 2>/dev/null || true' EXIT
ditto dist/Rill.app "$RILL_STAGE/Rill.app"
ln -s /Applications "$RILL_STAGE/Applications"
hdiutil create -quiet -ov -format UDZO -volname Rill -srcfolder "$RILL_STAGE" "dist/$RILL_NAME.dmg"
# Remove only this script's temporary staging tree.
python3 - "$RILL_STAGE" <<'PY'
import shutil, sys
from pathlib import Path
p = Path(sys.argv[1])
assert p.name.startswith('.rill-dmg.') and p.parent.name == 'dist'
shutil.rmtree(p)
PY
shasum -a 256 "dist/$RILL_NAME.dmg" > "dist/$RILL_NAME.sha256"
python3 - "$RILL_NAME" <<'PY'
import hashlib,json,platform,subprocess,sys
from pathlib import Path
name=sys.argv[1]
record={'artifact':name+'.dmg','sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'dirtySource':bool(subprocess.check_output(['git','status','--porcelain'],text=True).strip()),'architecture':platform.machine(),'signing':'ad-hoc development; not notarized','packageResolvedSHA256':hashlib.sha256(Path('Package.resolved').read_bytes()).hexdigest(),'noticesSHA256':hashlib.sha256(Path('THIRD_PARTY_NOTICES.txt').read_bytes()).hexdigest()}
Path('dist/'+name+'.provenance.json').write_text(json.dumps(record,indent=2)+'\n')
PY
