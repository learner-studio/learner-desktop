#!/usr/bin/env bash
#
# fetch-voice-id.sh -- downloads what Voice ID ("am I talking?") needs and git does not hold:
# sherpa-onnx's macOS static libraries and the speaker-embedding model, all from
# k2-fsa/sherpa-onnx's GitHub releases, each pinned to an exact file and SHA-256.
#
#   third_party/sherpa-onnx/artifacts/sherpa-onnx.xcframework   (SherpaOnnxC: the C API, static)
#   third_party/sherpa-onnx/artifacts/onnxruntime.xcframework   (libonnxruntime.a 1.28.2, static)
#   menu-bar-app/Models/3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx
#
# Package.swift links both frameworks, so `swift build` needs this run once per checkout.
# Re-running is cheap: anything already in place is left alone. FORCE=1 fetches again.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

SHERPA_VERSION=2.0.1
BASE=https://github.com/k2-fsa/sherpa-onnx/releases/download

# sherpa-onnx's own SwiftPM manifest (Package.swift at v2.0.1) names this file and checksum.
XCF_URL=$BASE/xcframework/sherpa-onnx-v$SHERPA_VERSION-macos-static.xcframework.zip
XCF_SHA=3c378789ebcbf3b1fb2e7cf0c58dae8e5629001598148aee2edd4494dc939a27
# That xcframework leaves onnxruntime out. The same release's static libraries carry it
# (1.28.2, the version sherpa-onnx's manifest pairs with v2.0.1); only libonnxruntime.a is used.
LIB_URL=$BASE/v$SHERPA_VERSION/sherpa-onnx-v$SHERPA_VERSION-osx-universal2-static-lib.tar.bz2
LIB_SHA=b0e83bb95767af7a1655f3c7cdf637381d4cf593b6a661b3d1beff23bab72b71
# 3D-Speaker CAM++, English (VoxCeleb), 16 kHz: 512-dim speaker embeddings. GitHub publishes
# no digest for this asset; the SHA-256 matches the Hugging Face LFS oid of the same file in
# csukuangfj/speaker-embedding-models (checked 2026-11-10).
MODEL_NAME=3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx
MODEL_URL=$BASE/speaker-recongition-models/$MODEL_NAME
MODEL_SHA=357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b

ART=third_party/sherpa-onnx/artifacts
MODEL=menu-bar-app/Models/$MODEL_NAME
STAMP=$ART/VERSION

work="$(mktemp -d "${TMPDIR:-/tmp}/voice-id.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# fetch URL SHA FILE: downloads into the scratch folder and refuses a file whose hash differs.
fetch() {
  local url="$1" sha="$2" out="$work/$3"
  echo "fetching $url"
  curl -fL --retry 3 --silent --show-error -o "$out" "$url"
  local got
  got="$(shasum -a 256 "$out" | cut -d' ' -f1)"
  if [ "$got" != "$sha" ]; then
    echo "SHA-256 mismatch for $url" >&2
    echo "  expected $sha" >&2
    echo "  got      $got" >&2
    exit 1
  fi
}

if [ "${FORCE:-0}" = 1 ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$SHERPA_VERSION" ] \
   || [ ! -d "$ART/sherpa-onnx.xcframework" ] || [ ! -f "$ART/onnxruntime.xcframework/macos-arm64_x86_64/libonnxruntime.a" ]; then
  fetch "$XCF_URL" "$XCF_SHA" xcf.zip
  fetch "$LIB_URL" "$LIB_SHA" lib.tar.bz2
  # Unpacked in the scratch folder, then moved into place whole.
  mkdir -p "$work/xcf" "$work/lib"
  unzip -q "$work/xcf.zip" -d "$work/xcf"
  tar -xjf "$work/lib.tar.bz2" -C "$work/lib" "sherpa-onnx-v$SHERPA_VERSION-osx-universal2-static-lib/lib/libonnxruntime.a"
  # A library xcframework for SwiftPM's binaryTarget: one universal slice, no headers
  # (only SherpaOnnxC calls onnxruntime).
  ort="$work/onnxruntime.xcframework"
  mkdir -p "$ort/macos-arm64_x86_64"
  mv "$work/lib/sherpa-onnx-v$SHERPA_VERSION-osx-universal2-static-lib/lib/libonnxruntime.a" "$ort/macos-arm64_x86_64/"
  cat > "$ort/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>libonnxruntime.a</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64_x86_64</string>
			<key>LibraryPath</key>
			<string>libonnxruntime.a</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
EOF
  rm -rf "$ART"
  mkdir -p "$ART"
  mv "$work/xcf/sherpa-onnx.xcframework" "$ART/"
  mv "$ort" "$ART/"
  echo "$SHERPA_VERSION" > "$STAMP"
  echo "sherpa-onnx $SHERPA_VERSION in $ART"
else
  echo "sherpa-onnx $SHERPA_VERSION already in $ART"
fi

if [ "${FORCE:-0}" = 1 ] || [ ! -f "$MODEL" ] || [ "$(shasum -a 256 "$MODEL" | cut -d' ' -f1)" != "$MODEL_SHA" ]; then
  fetch "$MODEL_URL" "$MODEL_SHA" model.onnx
  mkdir -p "$(dirname "$MODEL")"
  mv "$work/model.onnx" "$MODEL"
  echo "model in $MODEL"
else
  echo "model already in $MODEL"
fi
