#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <version>"
  echo "  version theo dạng versionName+versionCode, ví dụ: 0.3.4+9"
  exit 1
}

[ $# -eq 1 ] || usage
VERSION="$1"

if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$'; then
  echo "Version không hợp lệ: $VERSION (cần dạng X.Y.Z+N)" >&2
  exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
  echo "Phải đang ở branch main (hiện tại: $BRANCH) — release chỉ build từ main" >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree đang bẩn — commit/stash trước khi bump version:" >&2
  git status --short >&2
  exit 1
fi

git fetch origin main --quiet
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "Local main lệch origin/main — chạy git pull --ff-only trước" >&2
  exit 1
fi

OLD=$(grep '^version: ' pubspec.yaml | awk '{print $2}') || {
  echo "pubspec.yaml không có dòng version" >&2
  exit 1
}
OLD_CODE="${OLD##*+}"
NEW_CODE="${VERSION##*+}"

if [ "$OLD" = "$VERSION" ]; then
  echo "Version đã là $VERSION, không có gì để bump" >&2
  exit 1
fi

if [ "$NEW_CODE" -le "$OLD_CODE" ]; then
  echo "versionCode phải tăng: $OLD_CODE → $NEW_CODE" >&2
  exit 1
fi

TAG="v${VERSION%%+*}"

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "Tag ${TAG} đã tồn tại — không thể release lại cùng versionName (Play Store cũng chặn)" >&2
  exit 1
fi

# Release notes là nguồn duy nhất (docs/release-notes/v<version>.md + .en-US.md)
# được cả GitHub Release lẫn Play Console đọc — bắt buộc có sẵn trước khi tag.
# Validate luôn khối whatsnew (≤500 ký tự cho Play Console) — fail sớm ở đây
# thay vì đợi CI build xong mới fail ở bước Prepare Play release notes.
for NOTES in "docs/release-notes/${TAG}.md" "docs/release-notes/${TAG}.en-US.md"; do
  if [ ! -f "$NOTES" ]; then
    echo "Thiếu file release notes $NOTES — tạo trước rồi commit rồi mới bump (CI sẽ fail nếu thiếu)" >&2
    exit 1
  fi
  python3 scripts/md_to_whatsnew.py "$NOTES" /dev/null
done

sed -i "s/^version: .*/version: ${VERSION}/" pubspec.yaml

git add pubspec.yaml
git commit -m "chore(release): bump version ${VERSION}"
git push origin main

git tag -a "${TAG}" -m "Release ${TAG}"
git push origin "${TAG}"

echo "Đã push tag ${TAG} → CI sẽ build APK + AAB và tạo GitHub Release."
