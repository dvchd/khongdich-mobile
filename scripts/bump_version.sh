#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <version>"
  echo "  version theo dạng versionName+versionCode, ví dụ: 0.3.1+6"
  exit 1
}

[ $# -eq 1 ] || usage
VERSION="$1"

if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$'; then
  echo "Version không hợp lệ: $VERSION (cần dạng X.Y.Z+N)" >&2
  exit 1
fi

grep -q '^version: ' pubspec.yaml || {
  echo "pubspec.yaml không có dòng version" >&2
  exit 1
}

OLD=$(grep '^version: ' pubspec.yaml | awk '{print $2}')
if [ "$OLD" = "$VERSION" ]; then
  echo "Version đã là $VERSION, không có gì để bump" >&2
  exit 1
fi

sed -i "s/^version: .*/version: ${VERSION}/" pubspec.yaml

TAG="v${VERSION%%+*}"

git add pubspec.yaml
git commit -m "chore(release): bump version ${VERSION}"
git push origin HEAD

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "Tag ${TAG} đã tồn tại, không push tag" >&2
  exit 1
fi

git tag -a "${TAG}" -m "Release ${TAG}"
git push origin "${TAG}"

echo "Đã push tag ${TAG} → CI sẽ build APK + AAB và tạo GitHub Release."
