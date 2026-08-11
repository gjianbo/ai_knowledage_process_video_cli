#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cli_root="$(cd "$script_dir/.." && pwd)"
app_root="$cli_root/app"

platform="all"
version=""
build_number=""
android_format="apk"

usage() {
  cat <<'EOF'
用法：
  ./scripts/build_release.sh --version 1.2.3 --build-number 12 [选项]

选项：
  --platform android|macos|windows|all
                                  构建目标；all 仅构建当前主机支持的平台
  --android-format apk|aab        Android 产物格式，默认 apk
  --version X.Y.Z                 必填，发布版本号
  --build-number N                必填，正整数构建号
  -h, --help                      显示此说明

示例：
  ./scripts/build_release.sh --platform macos --version 1.0.0 --build-number 1
  ./scripts/build_release.sh --platform windows --version 1.0.0 --build-number 1
  ./scripts/build_release.sh --platform android --android-format aab --version 1.0.0 --build-number 1
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) platform="${2:-}"; shift 2 ;;
    --android-format) android_format="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --build-number) build_number="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage >&2; exit 64 ;;
  esac
done

if [[ ! "$platform" =~ ^(macos|android|windows|all)$ ]]; then
  echo "--platform 只能是 android、macos、windows 或 all" >&2
  exit 64
fi
if [[ ! "$android_format" =~ ^(apk|aab)$ ]]; then
  echo "--android-format 只能是 apk 或 aab" >&2
  exit 64
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
  echo "--version 必须是 X.Y.Z 格式" >&2
  exit 64
fi
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "--build-number 必须是正整数" >&2
  exit 64
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "未找到 Flutter，请先安装并加入 PATH。" >&2
  exit 69
fi

output_dir="$cli_root/dist/$version+$build_number"
mkdir -p "$output_dir"
cd "$app_root"

flutter pub get

build_args=(--release "--build-name=$version" "--build-number=$build_number")

if [[ "$platform" == "macos" || "$platform" == "all" ]]; then
  if [[ "$(uname -s)" != "Darwin" ]]; then
    if [[ "$platform" == "macos" ]]; then
      echo "macOS 包必须在 macOS 主机构建。" >&2
      exit 69
    fi
  else
  # 未配置 Apple Team 时，工程使用 ad-hoc 本地签名；正式分发仍需配置证书。
  flutter build macos "${build_args[@]}"
  macos_product="build/macos/Build/Products/Release/app.app"
  if [[ ! -d "$macos_product" ]]; then
    echo "macOS 产物不存在：$macos_product" >&2
    exit 1
  fi
  ditto -c -k --sequesterRsrc --keepParent "$macos_product" "$output_dir/hive-cli-macos-$version.zip"
  fi
fi

if [[ "$platform" == "android" || "$platform" == "all" ]]; then
  flutter build "$android_format" "${build_args[@]}"
  if [[ "$android_format" == "apk" ]]; then
    android_product="build/app/outputs/flutter-apk/app-release.apk"
    archive_name="hive-cli-android-$version.apk"
  else
    android_product="build/app/outputs/bundle/release/app-release.aab"
    archive_name="hive-cli-android-$version.aab"
  fi
  if [[ ! -f "$android_product" ]]; then
    echo "Android 产物不存在：$android_product" >&2
    exit 1
  fi
  cp "$android_product" "$output_dir/$archive_name"
fi

if [[ "$platform" == "windows" || "$platform" == "all" ]]; then
  if [[ "$(uname -s)" != "MINGW"* && "$(uname -s)" != "MSYS"* && "$(uname -s)" != "CYGWIN"* ]]; then
    if [[ "$platform" == "windows" ]]; then
      echo "Windows 包必须在 Windows 主机构建。" >&2
      exit 69
    fi
  else
    flutter build windows "${build_args[@]}"
    windows_product="build/windows/x64/runner/Release"
    if [[ ! -d "$windows_product" ]]; then
      echo "Windows 产物不存在：$windows_product" >&2
      exit 1
    fi
    powershell.exe -NoProfile -Command "Compress-Archive -Path '$windows_product\\*' -DestinationPath '$output_dir\\hive-cli-windows-$version.zip' -Force"
  fi
fi

if command -v shasum >/dev/null 2>&1; then
  (cd "$output_dir" && shasum -a 256 ./* > SHA256SUMS)
elif command -v sha256sum >/dev/null 2>&1; then
  (cd "$output_dir" && sha256sum ./* > SHA256SUMS)
else
  echo "未找到 shasum 或 sha256sum，无法生成 SHA256SUMS。" >&2
  exit 69
fi

git_commit="$(git -C "$cli_root" rev-parse HEAD 2>/dev/null || echo unknown)"
cat > "$output_dir/release.json" <<EOF
{
  "product": "hive-cli",
  "version": "$version",
  "buildNumber": $build_number,
  "gitCommit": "$git_commit",
  "builtAt": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "artifacts": "See SHA256SUMS"
}
EOF

cat <<EOF
构建完成：$output_dir
版本：$version+$build_number
校验清单：$output_dir/SHA256SUMS
发布元数据：$output_dir/release.json
EOF
