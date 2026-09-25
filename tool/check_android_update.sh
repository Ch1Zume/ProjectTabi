#!/usr/bin/env bash
set -euo pipefail
# Validate the install identity and persistent signer without printing private material.
current_apk="$1"
previous_apk="${2:-}"
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"

if [[ -z "$sdk_root" ]]; then
  echo 'Android SDK location is unavailable (ANDROID_SDK_ROOT and ANDROID_HOME are unset).' >&2
  exit 1
fi

build_tools=$(find "$sdk_root/build-tools" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1)
if [[ -z "$build_tools" || ! -x "$build_tools/apksigner" || ! -x "$build_tools/aapt" ]]; then
  echo "Android build-tools are missing apksigner or aapt under $sdk_root/build-tools." >&2
  exit 1
fi
apksigner="$build_tools/apksigner"
aapt="$build_tools/aapt"

certificate() {
  local output digest
  if ! output=$("$apksigner" verify --print-certs "$1" 2>&1); then
    printf 'APK signature verification failed: %s\n' "$output" >&2
    return 1
  fi
  digest=$(printf '%s\n' "$output" | sed -n 's/.*certificate SHA-256 digest: //p' | sed -n '1p')
  if [[ -z "$digest" ]]; then
    printf 'APK signature verification returned no SHA-256 certificate digest: %s\n' "$output" >&2
    return 1
  fi
  printf '%s' "$digest"
}

package_info() {
  local output
  if ! output=$("$aapt" dump badging "$1" 2>&1); then
    printf 'Could not read APK package metadata: %s\n' "$output" >&2
    return 1
  fi
  printf '%s\n' "$output" | sed -n '1p'
}

identity() {
  printf '%s' "$1" | sed -n "s/.*name='\([^']*\)'.*/\1/p"
}

version_code() {
  printf '%s' "$1" | sed -n "s/.*versionCode='\([^']*\)'.*/\1/p"
}

if ! current_cert=$(certificate "$current_apk"); then
  echo 'The release APK is not signed with a verifiable certificate.' >&2
  exit 1
fi
if ! current_info=$(package_info "$current_apk"); then
  exit 1
fi
current_id=$(identity "$current_info")
current_version=$(version_code "$current_info")

if [[ "$current_id" != 'com.ch1zume.projecttabi' ]]; then
  printf 'Unexpected Android package ID: expected com.ch1zume.projecttabi, found %s.\n' "${current_id:-<missing>}" >&2
  exit 1
fi
if [[ -z "$current_version" ]]; then
  echo 'The release APK has no readable Android versionCode.' >&2
  exit 1
fi
printf 'ProjectTabi package ID: %s; versionCode: %s\n' "$current_id" "$current_version"

if [[ -n "$previous_apk" ]]; then
  if ! previous_cert=$(certificate "$previous_apk"); then
    echo 'The previous release APK signature could not be verified.' >&2
    exit 1
  fi
  if ! previous_info=$(package_info "$previous_apk"); then
    exit 1
  fi
  previous_id=$(identity "$previous_info")
  previous_version=$(version_code "$previous_info")
  if [[ "$previous_id" != "$current_id" ]]; then
    printf 'Android package ID changed from %s to %s.\n' "$previous_id" "$current_id" >&2
    exit 1
  fi
  if [[ "$previous_cert" != "$current_cert" ]]; then
    echo 'Android signing certificate differs from the previous ProjectTabi release.' >&2
    exit 1
  fi
  if [[ -z "$previous_version" || "$current_version" -le "$previous_version" ]]; then
    echo 'Android versionCode must increase for every update.' >&2
    exit 1
  fi
  echo 'Android update identity, signature and version checks passed.'
fi
