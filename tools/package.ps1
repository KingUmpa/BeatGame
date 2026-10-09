# tools/package.ps1 - build play-tester packages for Windows and macOS (from CounterCatch's).
#
#   .\tools\package.ps1 -Version 0.1        (or: run package -Version 0.1)
#
# Produces in dist\:
#   BeatEmUp.love                 the game alone; runs anywhere LOVE 11.5 is installed
#   BeatEmUp-0.1-win64.zip        BeatEmUp.exe with LOVE fused in, its DLLs, alsoft.ini, LOVE's license
#   BeatEmUp-0.1-macos.zip        BeatEmUp.app, fused (+ "Open BeatEmUp.terminal" when unsigned)
# Nothing else: no README, just what it takes to launch the game.
#
# The .love holds the code, juice.json, the songs and levels, and only the audio they point at
# (tools\build_love.py). Windows uses LOVE 11.5 for Windows; macOS uses love-11.5-macos.zip.
# Both are looked for in tools\cache\, then CounterCatch's tools\cache\, and downloaded into
# tools\cache\ if neither has them. The mac fuse runs zip-to-zip in Python (tools\fuse_mac.py)
# so the app bundle keeps its Unix permissions and symlinks. Needs `py` (or `python`) with
# Pillow (py -m pip install pillow) for the app icon, assets\images\icon.png
# (lovec . --run=tools/make_icon.lua draws it).
#
# macOS signing + notarization (tools\sign_mac.py) runs when -SignDir (default .\signing) holds
# a Developer ID Application certificate (developer_id.cer + developer_id_key.pem) and an App
# Store Connect API key (AuthKey.p8 + notary.txt); needs Windows Developer Mode for symlinks.
# Notarized apps open on any Mac with no prompts. Without them the zip ships unsigned, with
# "Open BeatEmUp.terminal": double-clicked, it clears the app's download flag and starts it.

param(
  [string]$Version = "",
  [string]$LoveDir = "",
  [string]$SignDir = "",
  [switch]$SkipMac,
  [switch]$SkipWindows,
  [switch]$NoSign,        # skip Developer ID signing even if the signing folder exists
  [switch]$NoNotarize     # sign but don't submit to Apple (quick local builds)
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dist = Join-Path $root "dist"
$cache = Join-Path $root "tools\cache"
$siblingCache = Join-Path $root "..\CounterCatch\tools\cache"
$ver = if ($Version) { $Version } else { "dev" }
$name = "BeatEmUp"
$bundleId = "com.dumbfun.beatemup"
New-Item -ItemType Directory -Force -Path $dist, $cache | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$py = Get-Command py -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
if (-not $py) { Write-Error "Python not found (needed for the .love, the app icon and the mac fuse). Install Python 3." }
$appIcon = Join-Path $root "assets\images\icon.png"
if (-not (Test-Path $appIcon)) { Write-Error "no app icon: run  lovec . --run=tools/make_icon.lua  first" }

# a file from tools\cache, else CounterCatch's tools\cache (copied over), else downloaded
function Get-Cached([string]$file, [string]$url) {
  $mine = Join-Path $cache $file
  if (Test-Path $mine) { return $mine }
  $theirs = Join-Path $siblingCache $file
  if (Test-Path $theirs) {
    Copy-Item -Recurse $theirs $mine
    return $mine
  }
  Write-Host "downloading $url"
  $zip = Join-Path $cache (Split-Path -Leaf $url)
  Invoke-WebRequest -Uri $url -OutFile $zip
  if ($zip -ne $mine) {
    Expand-Archive -Path $zip -DestinationPath $cache -Force
    Remove-Item $zip
  }
  return $mine
}

# ---- the .love -----------------------------------------------------------------------------
$loveFile = Join-Path $dist "$name.love"
& $py.Source (Join-Path $root "tools\build_love.py") $root $loveFile
if ($LASTEXITCODE -ne 0) { Write-Error "building the .love failed" }

# ---- Windows: fuse love.exe ----------------------------------------------------------------
if (-not $SkipWindows) {
  if (-not $LoveDir) {
    $exe = Get-Command love.exe -ErrorAction SilentlyContinue
    $candidates = @(@(
      (Join-Path $cache "love-11.5-win64"),
      (Join-Path $siblingCache "love-11.5-win64"),
      $(if ($exe) { Split-Path -Parent $exe.Source }),
      $env:LOVE_HOME,
      "C:\Program Files\LOVE",
      "C:\Program Files (x86)\LOVE"
    ) | Where-Object { $_ -and (Test-Path (Join-Path $_ "love.exe")) })
    $LoveDir = if ($candidates) { $candidates[0] } else {
      Get-Cached "love-11.5-win64" "https://github.com/love2d/love/releases/download/11.5/love-11.5-win64.zip"
    }
  }
  Write-Host "LOVE (win): $LoveDir"

  $win = Join-Path $dist "$name-win64"
  if (Test-Path $win) { Remove-Item -Recurse -Force $win }
  New-Item -ItemType Directory -Force -Path $win | Out-Null

  # love.exe with the game's icon swapped in, + the .love concatenated = a standalone exe
  # (LOVE's "fused" mode). The icon goes in first: rewriting an exe's resources rebuilds the
  # file and would cut off a game already appended to it.
  $iconExe = Join-Path $dist "_love_icon.exe"
  & $py.Source (Join-Path $root "tools\win_icon.py") (Join-Path $LoveDir "love.exe") $appIcon $iconExe
  if ($LASTEXITCODE -ne 0) { Write-Error "setting the Windows icon failed" }
  $fused = Join-Path $win "$name.exe"
  cmd /c "copy /b `"$iconExe`"+`"$loveFile`" `"$fused`"" | Out-Null
  Remove-Item $iconExe
  Get-ChildItem $LoveDir -Filter "*.dll" | Copy-Item -Destination $win
  $lic = Join-Path $LoveDir "license.txt"
  if (Test-Path $lic) { Copy-Item $lic (Join-Path $win "LOVE-license.txt") }
  # the low-latency audio settings conf.lua points OpenAL at (read from beside the exe)
  Copy-Item (Join-Path $root "alsoft.ini") $win

  $zip = Join-Path $dist "$name-$ver-win64.zip"
  if (Test-Path $zip) { Remove-Item $zip }
  & $py.Source (Join-Path $root "tools\zip_folder.py") $win $zip
  if ($LASTEXITCODE -ne 0) { Write-Error "zipping the Windows build failed" }
  Write-Host "built $zip"
}

# ---- macOS: fuse love.app ------------------------------------------------------------------
if (-not $SkipMac) {
  $macZip = Get-Cached "love-11.5-macos.zip" "https://github.com/love2d/love/releases/download/11.5/love-11.5-macos.zip"
  $fuse = Join-Path $root "tools\fuse_mac.py"

  $macDir = Join-Path $dist "$name-macos"
  if (Test-Path $macDir) { Remove-Item -Recurse -Force $macDir }
  New-Item -ItemType Directory -Force -Path $macDir | Out-Null
  $appZip = Join-Path $macDir "app.zip"
  & $py.Source $fuse $macZip $loveFile $appZip $name $bundleId $ver $appIcon
  if ($LASTEXITCODE -ne 0) { Write-Error "fusing the mac app failed" }

  if (-not $SignDir) { $SignDir = Join-Path $root "signing" }
  $canSign = (-not $NoSign) -and (Test-Path (Join-Path $SignDir "developer_id.cer")) -and (Test-Path (Join-Path $SignDir "developer_id_key.pem"))
  $macOut = Join-Path $dist "$name-$ver-macos.zip"
  if (Test-Path $macOut) { Remove-Item $macOut }

  if ($canSign) {
    # ---- signed + notarized: the zip holds only the app; it just opens ----
    $rc = Join-Path $cache "rcodesign.exe"
    if (-not (Test-Path $rc)) {
      $theirs = Join-Path $siblingCache "rcodesign.exe"
      if (Test-Path $theirs) { Copy-Item $theirs $rc } else {
        $rcUrl = "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/0.29.0/apple-codesign-0.29.0-x86_64-pc-windows-msvc.zip"
        Write-Host "downloading $rcUrl"
        $rcZip = Join-Path $cache "rcodesign.zip"
        Invoke-WebRequest -Uri $rcUrl -OutFile $rcZip
        Expand-Archive -Path $rcZip -DestinationPath $cache -Force
        Copy-Item (Get-ChildItem $cache -Recurse -Filter "rcodesign.exe" | Select-Object -First 1).FullName $rc
      }
    }
    $signArgs = @($appZip, $macOut, $SignDir, $rc)
    if ($NoNotarize) { $signArgs += "--skip-notarize" }
    & $py.Source (Join-Path $root "tools\sign_mac.py") @signArgs
    if ($LASTEXITCODE -ne 0) { Write-Error "mac signing failed" }
  } else {
    # ---- unsigned: ship the helper that clears the quarantine flag and starts the app ----
    $find = 'for d in ~/Downloads ~/Desktop ~/Documents ~; do a=$(find "$d" -maxdepth 3 -name "' + $name + '.app" -print -quit 2>/dev/null); if [ -n "$a" ]; then xattr -cr "$a"; open "$a"; echo "Started $a - you can close this window."; exit 0; fi; done; echo "' + $name + '.app not found in Downloads, Desktop or Documents."'
    $terminal = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CommandString</key>
  <string>$([System.Security.SecurityElement]::Escape($find))</string>
  <key>RunCommandAsShell</key>
  <true/>
  <key>ProfileCurrentVersion</key>
  <real>2.07</real>
  <key>name</key>
  <string>Open $name</string>
  <key>type</key>
  <string>Window Settings</string>
  <key>shellExitAction</key>
  <integer>1</integer>
</dict>
</plist>
"@
    [IO.File]::WriteAllText((Join-Path $macDir "Open $name.terminal"), $terminal)
    $merge = @"
import sys, zipfile
out, terminal, name, parts = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
def add(zout, arc, path, mode):
    zi = zipfile.ZipInfo(arc); zi.external_attr = mode << 16; zi.create_system = 3
    zi.compress_type = zipfile.ZIP_DEFLATED
    zout.writestr(zi, open(path, 'rb').read())
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as zout:
    for p in parts:
        with zipfile.ZipFile(p) as zin:
            for info in zin.infolist():
                info.create_system = 3
                zout.writestr(info, zin.read(info))
    add(zout, 'Open ' + name + '.terminal', terminal, 0o644)
"@
    $mergeFile = Join-Path $macDir "_merge.py"
    Set-Content $mergeFile $merge -Encoding ASCII
    & $py.Source $mergeFile $macOut (Join-Path $macDir "Open $name.terminal") $name $appZip
    if ($LASTEXITCODE -ne 0) { Write-Error "zipping the mac app failed" }
  }
  Remove-Item -Recurse -Force $macDir
  $how = "unsigned"
  if ($canSign -and $NoNotarize) { $how = "signed" } elseif ($canSign) { $how = "signed + notarized" }
  Write-Host "built $macOut ($how)"
}

Write-Host ""
Write-Host "Send testers:"
Get-ChildItem $dist -Filter "$name-$ver-*.zip" | ForEach-Object { Write-Host ("  {0}  ({1:N1} MB)" -f $_.FullName, ($_.Length / 1MB)) }
Write-Host "Or, for anyone with LOVE installed: $loveFile"
