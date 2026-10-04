#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

python3 -m unittest discover -s tests -v
QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= QT_QUICK_CONTROLS_STYLE=Basic \
  /usr/lib/qt6/bin/qmltestrunner -input tests/qml

# Validate what `omarchy plugin add` would install: the git-tracked files
# (working-tree contents, so uncommitted edits are included). Local agent
# tooling such as .agents/ symlinks is untracked and must not fail the check.
snapshot="$work/plugin"
mkdir -p "$snapshot"
git ls-files -z --cached | while IFS= read -r -d '' file; do
  [[ -e $file ]] && printf '%s\0' "$file"
done | tar --null -T - -cf - | tar -xf - -C "$snapshot"
omarchy plugin validate "$snapshot"

mkdir -p "$work/imports"
ln -s "${OMARCHY_PATH:-/usr/share/omarchy}/shell" "$work/imports/qs"
/usr/lib/qt6/bin/qmllint -I "$work/imports" OmaConvert.qml services/ConvertService.qml services/PreviewService.qml components/ResultView.qml components/PreviewImage.qml components/TrimBar.qml
echo "All checks passed."
