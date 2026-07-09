#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./build.sh [command] [arch] [version] [--sign] [--notarize]

Commands:
  dev       Build in debug mode and run ForelApp locally
  build     Build the Swift package in release mode
  test      Run the Swift test suite
  package   Build and package a Forel.app + DMG
  release   Alias for: build + package

Arguments:
  arch      arm64 or x86_64 (defaults to host architecture)
  version   Release version like v1.2.3
  --sign    Sign the app and DMG with a Developer ID Application certificate
  --notarize
            Submit and staple the signed app and DMG using Notary API secrets

Examples:
  ./build.sh
  ./build.sh dev
  ./build.sh package
  ./build.sh package arm64 v1.2.3
  ./build.sh package arm64 v1.2.3 --sign
  ./build.sh package arm64 v1.2.3 --sign --notarize
  ./build.sh release x86_64 v1.2.3
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$script_dir"
build_root="$repo_root/.build"
dist_dir="$repo_root/dist/release"
bundle_root="${TMPDIR:-/tmp}/Forel.app"
dev_bundle="${TMPDIR:-/tmp}/Forel-dev.app"
staging_root="${TMPDIR:-/tmp}/Forel-dmg"
icon_source="$repo_root/Sources/ForelApp/Resources/AppIcon.png"
iconset_dir="${TMPDIR:-/tmp}/Forel.iconset"
icns_path="$repo_root/dist/Forel.icns"
entitlements_path="$repo_root/Forel.entitlements"
code_sign_identity="${CODE_SIGN_IDENTITY:--}"
notary_work=""

cleanup() {
  if [[ -n "$notary_work" ]]; then
    rm -rf "$notary_work"
  fi
}
trap cleanup EXIT

generate_icns() {
  rm -rf "$iconset_dir"
  mkdir -p "$iconset_dir"

  local size src
  src="$icon_source"
  for size in 16 32 64 128 256 512; do
    sips -z "$size" "$size" "$src" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$src" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
  done

  iconutil -c icns "$iconset_dir" -o "$icns_path" >/dev/null
}

# Copies the built binary (+ resource bundle, if any) for $config ("debug" or
# "release") into a fresh "$dest_app/Contents/{MacOS,Resources}". Shared by
# `dev` and `package` so the two don't drift out of sync.
assemble_app_bundle() {
  local config="$1" dest_app="$2"
  local binary_path resource_bundle contents_dir macos_dir resources_dir

  binary_path="$(find "$build_root" -type f -path "*/$config/ForelApp" -print -quit)"
  if [[ -z "$binary_path" ]]; then
    echo "Could not find ForelApp in .build after swift build" >&2
    exit 1
  fi
  resource_bundle="$(find "$build_root" -type d -path "*/$config/*_ForelApp.bundle" -print -quit)"

  contents_dir="$dest_app/Contents"
  macos_dir="$contents_dir/MacOS"
  resources_dir="$contents_dir/Resources"
  rm -rf "$dest_app"
  mkdir -p "$macos_dir" "$resources_dir"

  cp "$binary_path" "$macos_dir/ForelApp"
  chmod +x "$macos_dir/ForelApp"
  if [[ -n "$resource_bundle" ]]; then
    cp -R "$resource_bundle" "$resources_dir/"
  fi
}

# Writes Info.plist into $1, with $2 as both CFBundleShortVersionString and
# CFBundleVersion, plus any extra keys (already-indented <key>/<value> XML)
# passed as $3. Shared by `dev` and `package`, which pass only their
# build-specific extras on top of the identical boilerplate and privacy keys.
write_info_plist() {
  local contents_dir="$1" version_number="$2" extra_keys="${3:-}"
  cat > "$contents_dir/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Forel</string>
  <key>CFBundleExecutable</key>
  <string>ForelApp</string>
  <key>CFBundleIdentifier</key>
  <string>com.lab421.forel</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Forel</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${version_number}</string>
  <key>CFBundleVersion</key>
  <string>${version_number}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>Forel can import images and videos into your Photos library as part of automated rules.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Forel uses automation to add files to the Music and TV libraries as part of automated rules.</string>
${extra_keys}
</dict>
</plist>
EOF
}

notarize_and_staple() {
  local target="$1"
  local submission="$target"

  if [[ "$target" == *.app ]]; then
    submission="$notary_work/$(basename "$target").zip"
    /usr/bin/ditto -c -k --keepParent "$target" "$submission"
  fi

  echo "Submitting $(basename "$target") to Apple for notarization..."
  xcrun notarytool submit "$submission" \
    --key "$notary_work/AuthKey.p8" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait
  xcrun stapler staple "$target"
  xcrun stapler validate "$target"
}

command="${1:-release}"
if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    dev|build|test|package|release)
      command="$1"
      shift
      ;;
  esac
fi

sign_requested=false
notarize_requested=false
positional_args=()
for arg in "$@"; do
  case "$arg" in
    --sign)
      sign_requested=true
      ;;
    --notarize)
      notarize_requested=true
      ;;
    -*)
      echo "Unknown option: $arg" >&2
      usage
      exit 1
      ;;
    *)
      positional_args+=("$arg")
      ;;
  esac
done
if [[ ${#positional_args[@]} -gt 0 ]]; then
  set -- "${positional_args[@]}"
else
  set --
fi

if [[ $# -gt 2 ]]; then
  echo "Too many arguments" >&2
  usage
  exit 1
fi

arch="${1:-$(uname -m)}"
version="${2:-}"

if [[ "$sign_requested" == true ]]; then
  if [[ "$command" != "package" && "$command" != "release" ]]; then
    echo "--sign is only supported with package or release" >&2
    exit 1
  fi
  if [[ "$code_sign_identity" == "-" ]]; then
    code_sign_identity="$(
      security find-identity -v -p codesigning |
        awk '/Developer ID Application:/ && !identity { identity=$2 } END { print identity }'
    )"
    if [[ -z "$code_sign_identity" ]]; then
      echo "No valid Developer ID Application identity was found in the keychain" >&2
      exit 1
    fi
  fi
fi

if [[ "$notarize_requested" == true ]]; then
  if [[ "$command" != "package" && "$command" != "release" ]]; then
    echo "--notarize is only supported with package or release" >&2
    exit 1
  fi
  if [[ "$sign_requested" != true ]]; then
    echo "--notarize requires --sign" >&2
    exit 1
  fi
  if [[ -z "${NOTARY_API_KEY_P8:-}" || -z "${NOTARY_KEY_ID:-}" || -z "${NOTARY_ISSUER_ID:-}" ]]; then
    echo "Notarization requires NOTARY_API_KEY_P8, NOTARY_KEY_ID, and NOTARY_ISSUER_ID" >&2
    exit 1
  fi
  notary_work="$(mktemp -d "${TMPDIR:-/tmp}/Forel-notary.XXXXXX")"
  printf '%s' "$NOTARY_API_KEY_P8" | base64 --decode > "$notary_work/AuthKey.p8"
  chmod 600 "$notary_work/AuthKey.p8"
fi

case "$command" in
  dev)
    cd "$repo_root"
    # Build and run from inside a debug .app bundle rather than the bare
    # `swift run` binary. macOS attributes TCC checks (Photos, Automation) to
    # the bundle identity declared in Info.plist; an unbundled binary has none,
    # so those checks get misattributed to whatever launched it (e.g. the
    # terminal you're using) instead of Forel, making them unreliable to test.
    swift build

    assemble_app_bundle "debug" "$dev_bundle"
    contents_dir="$dev_bundle/Contents"
    macos_dir="$contents_dir/MacOS"

    write_info_plist "$contents_dir" "0.0.0-dev"

    # Ad-hoc sign so TCC has a stable bundle identity to attach grants to.
    codesign --force --deep --sign - "$dev_bundle" >/dev/null 2>&1
    # Exec the binary inside the bundle (not `open`) so stdout/stderr stay
    # attached to this terminal while macOS still reads the adjacent
    # Info.plist for the bundle identity TCC checks need.
    exec "$macos_dir/ForelApp"
    ;;

  build)
    cd "$repo_root"
    swift build -c release --arch "$arch"
    ;;

  test)
    cd "$repo_root"
    swift test
    ;;

  package|release)
    if [[ -z "$version" ]]; then
      if git -C "$repo_root" describe --tags --exact-match >/dev/null 2>&1; then
        version="$(git -C "$repo_root" describe --tags --exact-match)"
      else
        version="v0.0.0-local"
      fi
    fi

    if [[ "$version" == v* ]]; then
      version_number="${version#v}"
    else
      version_number="$version"
      version="v$version"
    fi

    case "$arch" in
      arm64)
        dmg_suffix="darwin-arm64"
        ;;
      x86_64)
        dmg_suffix="darwin-x86_64"
        ;;
      *)
        echo "Unsupported architecture: $arch" >&2
        exit 1
        ;;
    esac

    cd "$repo_root"
    swift build -c release --arch "$arch"

    if [[ -f "$icon_source" ]]; then
      mkdir -p "$repo_root/dist"
      generate_icns
    fi

    assemble_app_bundle "release" "$bundle_root"
    contents_dir="$bundle_root/Contents"

    write_info_plist "$contents_dir" "$version_number" '  <key>CFBundleIconFile</key>
  <string>Forel</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>'

    if [[ -f "$icns_path" ]]; then
      cp "$icns_path" "$bundle_root/Contents/Resources/Forel.icns"
    fi

    if [[ "$sign_requested" == true ]]; then
      # Sign outside the repository. Folders under Documents can receive
      # File Provider/provenance metadata after a copy, invalidating an
      # otherwise-correct signature before the DMG is assembled.
      xattr -cr "$bundle_root"
      codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --entitlements "$entitlements_path" \
        --sign "$code_sign_identity" \
        "$bundle_root"
      codesign --verify --deep --strict --verbose=2 "$bundle_root"
      if [[ "$notarize_requested" == true ]]; then
        notarize_and_staple "$bundle_root"
      fi
    fi

    mkdir -p "$dist_dir"
    rm -rf "$dist_dir/Forel.app"
    /usr/bin/ditto --noextattr --noqtn "$bundle_root" "$dist_dir/Forel.app"

    rm -rf "$staging_root"
    mkdir -p "$staging_root"
    /usr/bin/ditto --noextattr --noqtn "$bundle_root" "$staging_root/Forel.app"
    if [[ "$sign_requested" == true ]]; then
      codesign --verify --deep --strict --verbose=2 "$staging_root/Forel.app"
      if [[ "$notarize_requested" == true ]]; then
        xcrun stapler validate "$staging_root/Forel.app"
      fi
    fi
    ln -s /Applications "$staging_root/Applications"

    dmg_path="$dist_dir/Forel-${version}-${dmg_suffix}.dmg"
    hdiutil create \
      -volname "Forel" \
      -srcfolder "$staging_root" \
      -ov \
      -format UDZO \
      "$dmg_path"

    if [[ "$sign_requested" == true ]]; then
      codesign --force --timestamp --sign "$code_sign_identity" "$dmg_path"
      codesign --verify --strict --verbose=2 "$dmg_path"
      if [[ "$notarize_requested" == true ]]; then
        notarize_and_staple "$dmg_path"
        codesign --verify --strict --verbose=2 "$dmg_path"
      fi
    fi

    echo "Created $dmg_path"
    rm -rf "$iconset_dir" "$staging_root" "$icns_path"
    ;;

  *)
    usage
    exit 1
    ;;
esac
