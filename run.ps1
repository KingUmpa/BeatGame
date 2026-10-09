# run.ps1 - convenience launcher for Windows.
#   .\run.ps1                 the game
#   .\run.ps1 play --song=songs\x.json --from=2   one song, from its level 2
#   .\run.ps1 juice          the juice editor (juice.json + live game)
#   .\run.ps1 levels          the level editor
#   .\run.ps1 export          the song to exports\ (with and without backing)
#   .\run.ps1 test            unit tests
#   .\run.ps1 package -Version 0.1   Windows + Mac builds in dist\ (tools\package.ps1)
#
# Looks for LÖVE in PATH, $env:LOVE_HOME, the default install folders, CounterCatch's
# tools\cache, then this repo's tools\cache; downloads LÖVE 11.5 there if none is found.

param([string]$Mode = "play", [Parameter(ValueFromRemainingArguments = $true)][string[]]$Extra = @())

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$cached = Join-Path $root "tools\cache\love-11.5-win64\lovec.exe"

$candidates = @(@(
  (Get-Command lovec.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
  "$env:LOVE_HOME\lovec.exe",
  "C:\Program Files\LOVE\lovec.exe",
  "C:\Program Files (x86)\LOVE\lovec.exe",
  (Join-Path $root "..\CounterCatch\tools\cache\love-11.5-win64\lovec.exe"),
  $cached
) | Where-Object { $_ -and (Test-Path $_) })

if (-not $candidates) {
  $zip = Join-Path $root "tools\cache\love-11.5-win64.zip"
  New-Item -ItemType Directory -Force -Path (Split-Path $zip) | Out-Null
  Write-Host "LÖVE not found; downloading 11.5 into tools\cache ..."
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri "https://github.com/love2d/love/releases/download/11.5/love-11.5-win64.zip" -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath (Join-Path $root "tools\cache") -Force
  Remove-Item $zip
  if (-not (Test-Path $cached)) { Write-Error "download failed; install LÖVE 11.5 from https://love2d.org"; exit 1 }
  $candidates = @($cached)
}
$love = $candidates[0]

Push-Location $root
try {
  switch ($Mode) {
    "test"   { & $love $root --test @Extra }
    "juice"  { & $love $root --juice @Extra }
    "levels" { & $love $root --levels @Extra }
    "export" { & $love $root --export @Extra }
    # its own process, so "-Version 0.1" etc. reach it as named parameters
    "package" { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "tools\package.ps1") @Extra }
    default  { & $love $root @Extra }
  }
} finally { Pop-Location }
exit $LASTEXITCODE
