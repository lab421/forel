#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./build.sh [command] [flavor] [arch] [version] [--sign] [--notarize]

Commands:
  dev       Build in debug mode and run ForelApp locally
  build     Build the Swift package in release mode
  test      Run the Swift test suite
  package   Build and package a Forel.app + DMG
  release   Alias for: build + package
  strings   Add the strings the code uses to Localization/Localizable.xcstrings
            (--check: only fail if the catalog is out of date, for CI)

Arguments:
  flavor    development, ad-hoc, or app-store
            (dev defaults to development; build/package default to ad-hoc)
            The test command is flavor-independent and accepts no flavor.
  arch      universal, arm64, or x86_64 (defaults to host architecture)
  version   Release version like v1.2.3
  --sign    Sign the app and DMG with a Developer ID Application certificate
  --notarize
            Submit and staple the signed app and DMG using Notary API secrets

Examples:
  ./build.sh
  ./build.sh dev
  ./build.sh test
  ./build.sh strings
  ./build.sh build ad-hoc arm64
  ./build.sh package arm64 v1.2.3
  ./build.sh package ad-hoc arm64 v1.2.3 --sign
  ./build.sh package ad-hoc arm64 v1.2.3 --sign --notarize
  ./build.sh package ad-hoc universal v1.2.3 --sign --notarize
  ./build.sh release x86_64 v1.2.3
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$script_dir"
dist_dir="$repo_root/dist/release"
temp_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
bundle_root="$temp_root/Forel.app"
dev_bundle="$temp_root/Forel-dev.app"
staging_root="$temp_root/Forel-dmg"
icon_source="$repo_root/Sources/ForelApp/Resources/AppIcon.png"
iconset_dir="$temp_root/Forel.iconset"
icns_path="$repo_root/dist/Forel.icns"
entitlements_path="$repo_root/Forel.entitlements"
localization_dir="$repo_root/Localization"
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

# Copies the binary and resources from SwiftPM's exact product directory
# into a fresh "$dest_app/Contents/{MacOS,Resources}". Shared by
# `dev` and `package` so the two don't drift out of sync.
assemble_app_bundle() {
  local products_dir="$1" dest_app="$2"
  local binary_path resource_bundle contents_dir macos_dir resources_dir

  binary_path="$products_dir/ForelApp"
  if [[ ! -f "$binary_path" ]]; then
    echo "Could not find ForelApp in $products_dir after swift build" >&2
    exit 1
  fi
  resource_bundle="$products_dir/Forel_ForelApp.bundle"

  contents_dir="$dest_app/Contents"
  macos_dir="$contents_dir/MacOS"
  resources_dir="$contents_dir/Resources"
  rm -rf "$dest_app"
  mkdir -p "$macos_dir" "$resources_dir"

  cp "$binary_path" "$macos_dir/ForelApp"
  chmod +x "$macos_dir/ForelApp"
  if [[ -d "$resource_bundle" ]]; then
    cp -R "$resource_bundle" "$resources_dir/"
  fi
  compile_localizations "$resources_dir"
}

# Compiles each string catalog in Localization/ into "<language>.lproj"
# folders in the app's own Resources, where SwiftUI and String(localized:)
# look up translations. The catalogs are not SwiftPM resources on purpose:
# SwiftPM's native build system copies a catalog without compiling it, and
# either build system would put it in the package's resource bundle instead
# of the app's main bundle.
compile_localizations() {
  local resources_dir="$1" catalog
  for catalog in "$localization_dir"/*.xcstrings; do
    xcrun xcstringstool compile "$catalog" --output-directory "$resources_dir" >/dev/null
  done
}

# Keys of catalog $1 that the code still uses, one per line, sorted.
catalog_keys() {
  python3 -c '
import json, sys
strings = json.load(open(sys.argv[1]))["strings"]
for key in sorted(k for k, v in strings.items() if v.get("extractionState") != "stale"):
    print(json.dumps(key))
' "$1"
}

# Warns about strings of catalog $1 that a language already in the catalog
# doesn't translate yet. The app then shows them in English, so it's a
# warning, not a failure.
report_untranslated() {
  python3 -c '
import json, sys
strings = json.load(open(sys.argv[1]))["strings"]
active = {k: v for k, v in strings.items() if v.get("extractionState") != "stale" and v.get("shouldTranslate", True)}
languages = sorted({lang for v in active.values() for lang in v.get("localizations", {})} - {"en"})
for lang in languages:
    missing = sorted(k for k, v in active.items() if lang not in v.get("localizations", {}))
    if missing:
        print(f"warning: {len(missing)} string(s) not translated to {lang}: " + ", ".join(json.dumps(k, ensure_ascii=False) for k in missing), file=sys.stderr)
' "$1"
}

# Adds the strings Forel's code uses to catalog $1, with their comments, and
# marks the ones it no longer uses as stale. The compiler reports them
# (-emit-localized-strings), so it sees exactly which literals SwiftUI and
# String(localized:) treat as localizable, including those passed to a
# LocalizedStringKey parameter. Every file is recompiled so none is skipped
# as up to date; dependency checkouts are kept to avoid fetching them again.
sync_string_catalog() {
  local catalog="$1" scratch="$repo_root/.build/strings" stringsdata_dir name
  local stringsdata_args=()
  stringsdata_dir="$scratch/stringsdata"
  if [[ -d "$scratch" ]]; then
    find "$scratch" -mindepth 1 -maxdepth 1 \
      ! -name checkouts ! -name repositories ! -name artifacts ! -name workspace-state.json \
      -exec rm -rf {} +
  fi
  mkdir -p "$stringsdata_dir"
  swift build --scratch-path "$scratch" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$stringsdata_dir"

  # The compiler names each file's strings after the source file alone, in one
  # folder for every module, dependencies included. Keep only Forel's own.
  while IFS= read -r name; do
    if find "$scratch/checkouts" -path "*/Sources/*" -name "$name.swift" 2>/dev/null | grep -q .; then
      echo "A dependency also has a $name.swift, so its strings can't be told apart from Forel's. Rename Forel's file." >&2
      exit 1
    fi
    if [[ -f "$stringsdata_dir/$name.stringsdata" ]]; then
      stringsdata_args+=(--stringsdata "$stringsdata_dir/$name.stringsdata")
    fi
  done < <(find "$repo_root/Sources/ForelApp" "$repo_root/Sources/ForelCore" -name "*.swift" -exec basename {} .swift \; | sort)

  xcrun xcstringstool sync "$catalog" "${stringsdata_args[@]}"
}

# macOS 26 and later only give an app the current system design (control
# sizes and shapes, segmented controls, etc.) when its binary records an SDK
# of 26 or later. SwiftPM's default build system in Xcode 27 records the
# deployment target (14.0) there instead of the SDK it compiled against, so a
# local dev build would look like an old app. Used by `dev` only; release
# packaging is left untouched.
minimum_design_sdk_major=26

recorded_sdk_versions() {
  vtool -show-build "$1" | awk '$1 == "sdk" { print $2 }'
}

# Rewrites the SDK version recorded in every architecture of binary $1 to the
# SDK it was built with, keeping its minimum macOS version. No-op when they
# already match, e.g. once SwiftPM records it correctly.
record_real_sdk_version() {
  local binary="$1" sdk_version minimum_os recorded needs_fix=false
  sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
  minimum_os="$(vtool -show-build "$binary" | awk '$1 == "minos" { print $2; exit }')"
  while read -r recorded; do
    if [[ "$recorded" != "$sdk_version" ]]; then
      needs_fix=true
    fi
  done < <(recorded_sdk_versions "$binary")

  if [[ "$needs_fix" == true ]]; then
    vtool -set-build-version macos "$minimum_os" "$sdk_version" -replace \
      -output "$binary.sdk-fixed" "$binary" >/dev/null
    mv "$binary.sdk-fixed" "$binary"
    chmod +x "$binary"
  fi
}

# Fails (or only warns, with "warn" as $2) when binary $1 records an SDK too
# old for the current system design, so a release can't ship the old look.
verify_design_sdk() {
  local binary="$1" mode="${2:-fail}" recorded
  while read -r recorded; do
    if (( ${recorded%%.*} < minimum_design_sdk_major )); then
      echo "ForelApp records macOS SDK $recorded. macOS only applies its current design to apps built with SDK $minimum_design_sdk_major or later; build with Xcode $minimum_design_sdk_major or later." >&2
      if [[ "$mode" != "warn" ]]; then
        exit 1
      fi
      return
    fi
  done < <(recorded_sdk_versions "$binary")
}

# Writes Info.plist into $1, with $2 as both CFBundleShortVersionString and
# CFBundleVersion, plus any extra keys (already-indented <key>/<value> XML)
# passed as $3. Shared by `dev` and `package`, which pass only their
# build-specific extras on top of the identical boilerplate and privacy keys.
# The privacy texts are translated in Localization/InfoPlist.xcstrings; keep
# their English there in sync with this file.
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
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Lab421</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
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

swift_release_build() {
  local build_arch="$1"
  local build_args=(-c release "${swift_flags[@]}")

  if [[ "$build_arch" == "universal" ]]; then
    build_args+=(--arch arm64 --arch x86_64)
  else
    build_args+=(--arch "$build_arch")
  fi
  swift build "${build_args[@]}"
  build_products_dir="$(swift build "${build_args[@]}" --show-bin-path)"
}

command="${1:-release}"
if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    dev|build|test|package|release|strings)
      command="$1"
      shift
      ;;
  esac
fi

if [[ "$command" == "strings" ]]; then
  cd "$repo_root"
  catalog="$localization_dir/Localizable.xcstrings"
  case "${1:-}" in
    "")
      sync_string_catalog "$catalog"
      echo "Updated ${catalog#"$repo_root/"}"
      report_untranslated "$catalog"
      ;;
    --check)
      # Compares which strings the code uses rather than the file's text, so
      # a different Xcode formatting the catalog differently doesn't fail CI.
      checked_copy="$(mktemp -d "$temp_root/Forel-strings.XXXXXX")/Localizable.xcstrings"
      cp "$catalog" "$checked_copy"
      sync_string_catalog "$checked_copy"
      if ! diff <(catalog_keys "$catalog") <(catalog_keys "$checked_copy") >&2; then
        echo "Localization/Localizable.xcstrings is out of date (> to add, < no longer used). Run ./build.sh strings and commit the result." >&2
        exit 1
      fi
      echo "Localization/Localizable.xcstrings is up to date."
      report_untranslated "$catalog"
      ;;
    *)
      echo "Unknown argument for strings: $1" >&2
      usage
      exit 1
      ;;
  esac
  exit 0
fi

if [[ "$command" == "test" ]]; then
  if [[ $# -gt 0 ]]; then
    echo "The test command does not accept a build flavor." >&2
    exit 1
  fi
  flavor="development"
else
  if [[ "$command" == "dev" ]]; then
    flavor="development"
  else
    flavor="ad-hoc"
  fi

  if [[ $# -gt 0 ]]; then
    case "$1" in
      development|ad-hoc|app-store)
        flavor="$1"
        shift
        ;;
    esac
  fi
fi

case "$flavor" in
  development)
    compilation_condition="FOREL_BUILD_DEVELOPMENT"
    ;;
  ad-hoc)
    compilation_condition="FOREL_BUILD_AD_HOC"
    ;;
  app-store)
    compilation_condition="FOREL_BUILD_APP_STORE"
    ;;
  *)
    echo "Unsupported build flavor: $flavor" >&2
    exit 1
    ;;
esac

swift_flags=(-Xswiftc "-D$compilation_condition")

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
  notary_work="$(mktemp -d "$temp_root/Forel-notary.XXXXXX")"
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
    swift build "${swift_flags[@]}"

    build_products_dir="$(swift build "${swift_flags[@]}" --show-bin-path)"
    assemble_app_bundle "$build_products_dir" "$dev_bundle"
    contents_dir="$dev_bundle/Contents"
    macos_dir="$contents_dir/MacOS"
    # Dev builds only: give the local app the same system design as the
    # release, whatever the local SwiftPM records.
    record_real_sdk_version "$macos_dir/ForelApp"
    verify_design_sdk "$macos_dir/ForelApp" warn

    write_info_plist "$contents_dir" "0.0.0-dev" '  <key>ForelBuildFlavor</key>
  <string>development</string>'

    # Ad-hoc sign so TCC has a stable bundle identity to attach grants to.
    codesign --force --deep --sign - "$dev_bundle" >/dev/null 2>&1
    # Exec the binary inside the bundle (not `open`) so stdout/stderr stay
    # attached to this terminal while macOS still reads the adjacent
    # Info.plist for the bundle identity TCC checks need.
    exec "$macos_dir/ForelApp"
    ;;

  build)
    cd "$repo_root"
    swift_release_build "$arch"
    ;;

  test)
    cd "$repo_root"
    # Tests use the development flavor (no direct licensing), so no
    # compilation condition is passed — plain `swift test` works as before.
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
      universal)
        dmg_suffix=""
        ;;
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
    swift_release_build "$arch"

    if [[ -f "$icon_source" ]]; then
      mkdir -p "$repo_root/dist"
      generate_icns
    fi

    assemble_app_bundle "$build_products_dir" "$bundle_root"
    contents_dir="$bundle_root/Contents"

    if [[ "$arch" == "universal" ]]; then
      lipo "$bundle_root/Contents/MacOS/ForelApp" -verify_arch arm64
      lipo "$bundle_root/Contents/MacOS/ForelApp" -verify_arch x86_64
    fi

    write_info_plist "$contents_dir" "$version_number" '  <key>CFBundleIconFile</key>
  <string>Forel</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>ForelBuildFlavor</key>
  <string>'"$flavor"'</string>'

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

    if [[ "$arch" == "universal" ]]; then
      dmg_path="$dist_dir/Forel-${version}.dmg"
    else
      dmg_path="$dist_dir/Forel-${version}-${dmg_suffix}.dmg"
    fi
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
