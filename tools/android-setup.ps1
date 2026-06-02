# tools/android-setup.ps1 — one-time Android export setup for this machine.
# Idempotent: safe to re-run. Sources nothing secret into git.
$ErrorActionPreference = "Stop"

$Sdk = "C:\Users\quint\AppData\Local\Android\Sdk"
if (-not (Test-Path $Sdk)) { throw "Android SDK not found at $Sdk — install it first." }

# 1. Session env (the package.mjs toolchain guard keys off these).
$env:ANDROID_HOME = $Sdk
$env:ANDROID_SDK_ROOT = $Sdk
$env:Path += ";$Sdk\platform-tools;$Sdk\emulator;$Sdk\cmdline-tools\latest\bin"
Write-Host "ANDROID_HOME set to $Sdk (this session)."

# 2. Debug keystore (Godot's expected androiddebugkey / android / android).
$Keystore = Join-Path $env:USERPROFILE ".android\debug.keystore"
if (-not (Test-Path $Keystore)) {
  New-Item -ItemType Directory -Force (Split-Path $Keystore) | Out-Null
  & keytool -genkeypair -v -keystore $Keystore -storepass android -keypass android `
    -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 `
    -dname "CN=Android Debug,O=Android,C=US"
  Write-Host "Generated debug keystore at $Keystore."
} else {
  Write-Host "Debug keystore already present at $Keystore."
}

# 3. Editor settings the engineer must confirm in Godot's editor_settings-4.tres
#    (%APPDATA%\Godot\editor_settings-4.tres) for headless CLI export to find the SDK + keystore:
Write-Host ""
Write-Host "Confirm these keys in %APPDATA%\Godot\editor_settings-4.tres (open Godot once, Editor > Editor Settings > Export > Android):"
Write-Host "  export/android/android_sdk_path = `"$Sdk`""
Write-Host "  export/android/debug_keystore   = `"$Keystore`""
Write-Host "  export/android/debug_keystore_user = `"androiddebugkey`""
Write-Host "  export/android/debug_keystore_pass = `"android`""
Write-Host ""
Write-Host "For a release AAB also: install the Android build template (Godot: Project > Install Android Build Template)"
Write-Host "and create tools/android-signing.local.json (git-ignored) with { keystore_path, keystore_user, keystore_password }."
