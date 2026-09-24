#!/usr/bin/env bash
set -euo pipefail
# Validate the install identity and persistent signer without printing private material.
current_apk="$1"
previous_apk="${2:-}"
build_tools=$(find "$ANDROID_SDK_ROOT/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
apksigner="$build_tools/apksigner"
aapt="$build_tools/aapt"

certificate() {
  "$apksigner" verify --print-certs "$1" | sed -n 's/.*certificate SHA-256 digest: //p' | sed -n '1p'
}
package_info() {
  "$aapt" dump badging "$1" | sed -n '1p'
}
identity() {
  printf '%s' "$1" | sed -n "s/.*name='\([^']*\)'.*/\1/p"
}
version_code() {
  printf '%s' "$1" | sed -n "s/.*versionCode='\([^']*\)'.*/\1/p"
}

current_cert=$(certificate "$current_apk")
test -n "$current_cert"
current_info=$(package_info "$current_apk")
current_id=$(identity "$current_info")
current_version=$(version_code "$current_info")
test "$current_id" = 'com.ch1zume.projecttabi'
test -n "$current_version"
printf 'ProjectTabi package ID: %s; versionCode: %s\n' "$current_id" "$current_version"

if [ -n "$previous_apk" ]; then
  previous_cert=$(certificate "$previous_apk")
  previous_info=$(package_info "$previous_apk")
  previous_id=$(identity "$previous_info")
  previous_version=$(version_code "$previous_info")
  test "$previous_id" = "$current_id"
  if [ "$previous_cert" != "$current_cert" ]; then
    echo 'Android signing certificate differs from the previous ProjectTabi release.'
    exit 1
  fi
  if [ "$current_version" -le "$previous_version" ]; then
    echo 'Android versionCode must increase for every update.'
    exit 1
  fi
  echo 'Android update identity, signature and version checks passed.'
fi
