#!/bin/bash
# Publish a GitHub Release with the notarized DMG and zip.
#
#   scripts/publish-release.sh <version> [options]
#
#   --build NOTARY_PROFILE   first run package-release.sh (notarized) with this profile
#   --notes FILE             release notes (Markdown); default: generated install notes
#   --draft                  create the release as a draft
#   --repo OWNER/NAME        default: the origin remote's GitHub repo
#
# Refuses to publish unless: the working tree is clean and pushed, dist/SessionMonitor-<version>.dmg
# and .zip exist, the app in the zip has CFBundleShortVersionString <version>, and both the DMG and
# that app are notarized (stapled ticket + Gatekeeper "Notarized Developer ID").
# Tags HEAD as v<version> (if the tag does not exist yet) and pushes the tag.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
[[ -n "$version" && "$version" != -* ]] || { sed -n '2,15p' "$0"; exit 2; }
shift
notary_profile=""
notes_file=""
draft=()
repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) notary_profile="$2"; shift 2 ;;
    --notes) notes_file="$2"; shift 2 ;;
    --draft) draft=(--draft); shift ;;
    --repo) repo="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

tag="v$version"
dmg="dist/SessionMonitor-$version.dmg"
zip="dist/SessionMonitor-$version.zip"
fail() { echo "error: $*" >&2; exit 1; }

command -v gh >/dev/null || fail "GitHub CLI (gh) is not installed"
gh auth status >/dev/null 2>&1 || fail "gh is not logged in (run: gh auth login)"
if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || fail "cannot determine the GitHub repo"
fi

echo "==> Checking git state"
[[ -z "$(git status --porcelain)" ]] || fail "working tree has uncommitted changes; commit them first"
git fetch -q origin
branch="$(git rev-parse --abbrev-ref HEAD)"
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" \
  || fail "branch $branch has no upstream; push it first"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "$upstream")" ]] \
  || fail "HEAD is not pushed ($branch differs from $upstream); push first"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  [[ "$(git rev-list -n1 "$tag")" == "$(git rev-parse HEAD)" ]] \
    || fail "tag $tag already exists on another commit"
fi

if [[ -n "$notary_profile" ]]; then
  echo "==> Building and notarizing $version"
  scripts/package-release.sh --version "$version" --notary-profile "$notary_profile"
fi

echo "==> Verifying artifacts"
[[ -f "$dmg" ]] || fail "$dmg not found (build with: scripts/package-release.sh --version $version --notary-profile <profile>)"
[[ -f "$zip" ]] || fail "$zip not found"
work="$(mktemp -d "${TMPDIR:-/tmp}/sm-publish.XXXXXX")"
trap 'rm -rf "$work"' EXIT
ditto -x -k "$zip" "$work"
app="$work/SessionMonitor.app"
[[ -d "$app" ]] || fail "$zip does not contain SessionMonitor.app"
app_version="$(defaults read "$app/Contents/Info" CFBundleShortVersionString)"
[[ "$app_version" == "$version" ]] || fail "app in $zip is version $app_version, not $version"

xcrun stapler validate -q "$dmg" || fail "$dmg has no notarization ticket"
spctl --assess --type open --context context:primary-signature -vv "$dmg" 2>&1 \
  | grep -q "source=Notarized Developer ID" || fail "$dmg is not accepted by Gatekeeper as notarized"
xcrun stapler validate -q "$app" || fail "the app in $zip has no notarization ticket"
spctl --assess --type execute -vv "$app" 2>&1 \
  | grep -q "source=Notarized Developer ID" || fail "the app in $zip is not accepted by Gatekeeper as notarized"
echo "    $dmg and $zip are notarized (version $app_version)"

dmg_sha="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
zip_sha="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
if [[ -z "$notes_file" ]]; then
  notes_file="$work/notes.md"
  cat > "$notes_file" <<NOTES
## 安装

1. 下载 \`SessionMonitor-$version.dmg\`，打开后把 SessionMonitor 拖到"应用程序"。
2. 启动 SessionMonitor，在菜单栏图标 → **设置… → 集成** 中为 Claude Code / Codex 点击 **安装**。
3. 使用 Codex 时，在任意 Codex 会话中输入 \`/hooks\` 批准 SessionMonitor 的条目。

需要 macOS 14 或以上，仅支持 Apple Silicon（M 系列芯片）。安装包已签名并通过 Apple 公证。

## 校验

| 文件 | SHA-256 |
|---|---|
| SessionMonitor-$version.dmg | \`$dmg_sha\` |
| SessionMonitor-$version.zip | \`$zip_sha\` |
NOTES
fi

if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "==> Tagging $tag"
  git tag -a "$tag" -m "SessionMonitor $version"
fi
git push -q origin "$tag"

if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  echo "==> Release $tag exists; replacing its assets"
  gh release upload "$tag" "$dmg" "$zip" --repo "$repo" --clobber
  gh release edit "$tag" --repo "$repo" --notes-file "$notes_file" >/dev/null
else
  echo "==> Creating release $tag"
  gh release create "$tag" "$dmg" "$zip" --repo "$repo" --verify-tag \
    --title "SessionMonitor $version" --notes-file "$notes_file" ${draft[@]+"${draft[@]}"} >/dev/null
fi
echo "==> Done: $(gh release view "$tag" --repo "$repo" --json url --jq .url)"
