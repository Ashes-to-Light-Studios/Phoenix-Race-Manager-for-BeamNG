# Runs PRM-Setup.exe against scratch BeamMP server folders: a fresh install,
# an update over an old install with leftovers, a renamed resources folder, a
# running server, a write that fails, and a folder that is not a server. The
# release workflow runs it on every build; it runs on any Windows PC too.
#
#   pwsh installer/windows/test.ps1 -Exe dist/PRM-Setup.exe -Zip dist/RaceManager-v0.22.0.zip
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [Parameter(Mandatory = $true)][string]$Zip
)
$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path $Exe).Path
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$script:checks = 0; $script:fails = 0
function Check([bool]$ok, [string]$what) {
  $script:checks++
  if (-not $ok) { $script:fails++; Write-Host "FAIL: $what" }
}

function Hash([byte[]]$bytes) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { [BitConverter]::ToString($sha.ComputeHash($bytes)) } finally { $sha.Dispose() }
}
function FileHash([string]$path) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  Hash ([System.IO.File]::ReadAllBytes($path))
}

# What the release says each installed file must be.
$expect = @{}
$archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $Zip).Path)
try {
  foreach ($e in $archive.Entries) {
    if ($e.FullName -match '^(Client/RaceManager\.zip|Server/RaceManager/[A-Za-z0-9_-]+\.lua)$') {
      $ms = New-Object System.IO.MemoryStream
      $s = $e.Open(); $s.CopyTo($ms); $s.Dispose()
      $expect[$e.FullName] = Hash $ms.ToArray()
      if ($e.FullName -eq 'Server/RaceManager/main.lua') {
        $version = [regex]::Match([System.Text.Encoding]::UTF8.GetString($ms.ToArray()), "(?m)^local RM_BUILD = '([^']+)'").Groups[1].Value
      }
    }
  }
} finally { $archive.Dispose() }
Check ($expect.Count -ge 2 -and $version) 'the release zip has the client and a main.lua with a version'

function Installed([string]$res) {
  foreach ($k in $expect.Keys) {
    if ((FileHash (Join-Path $res ($k -replace '/', '\'))) -ne $expect[$k]) { return $false }
  }
  return $true
}

function Run([string]$server) {
  $p = Start-Process -FilePath $exe -ArgumentList '/server', ('"' + $server + '"'), '/quiet' -Wait -PassThru -WindowStyle Hidden
  return $p.ExitCode
}

function NewServer([string]$dir, [string]$config) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Set-Content -LiteralPath (Join-Path $dir 'ServerConfig.toml') -Value $config -NoNewline
}

function ZipWith([string]$path, [string[]]$names) {
  $fs = [System.IO.File]::Create($path)
  $z = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
  foreach ($n in $names) { $w = New-Object System.IO.StreamWriter($z.CreateEntry($n).Open()); $w.Write('x'); $w.Dispose() }
  $z.Dispose(); $fs.Dispose()
}

# The installer remembers the last server folder; put back whatever was there.
$regKey = 'HKCU:\Software\Phoenix Race Manager'
$hadKey = Test-Path $regKey
$before = if ($hadKey) { (Get-ItemProperty $regKey -ErrorAction SilentlyContinue).ServerFolder } else { $null }

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('prm setup test ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$config = "Port = 30814`r`nMap = `"/levels/gridmap_v2/info.json`"`r`n"
try {
  # --- A fresh server -------------------------------------------------------
  $fresh = Join-Path $root 'fresh'
  NewServer $fresh $config
  Check ((Run $fresh) -eq 0) 'a fresh server installs'
  Check (Installed (Join-Path $fresh 'Resources')) 'with every file the release has'
  $log = Get-ChildItem -Path (Join-Path $fresh '_attic') -Recurse -Filter install.log | Select-Object -First 1
  Check ($null -ne $log -and $log.Directory.Name -like "install-none-to-$version*") 'and a log of what it did'

  # --- An update over an old install ----------------------------------------
  $up = Join-Path $root 'update'
  NewServer $up $config
  $res = Join-Path $up 'Resources'
  $plugin = Join-Path $res 'Server\RaceManager'
  New-Item -ItemType Directory -Force -Path (Join-Path $plugin 'Data\results'), (Join-Path $res 'Client'),
    (Join-Path $res 'Server\RaceManager_old'), (Join-Path $res 'Server\OtherPlugin') | Out-Null
  Set-Content -LiteralPath (Join-Path $res 'Client\RaceManager.zip') -Value 'OLD CLIENT' -NoNewline
  Set-Content -LiteralPath (Join-Path $plugin 'main.lua') -Value "-- old`nlocal RM_BUILD = '0.0.1'`n" -NoNewline
  Set-Content -LiteralPath (Join-Path $plugin 'stale.lua') -Value '-- gone from the release' -NoNewline
  Set-Content -LiteralPath (Join-Path $plugin 'Data\config.json') -Value '{"adminPassword": "theirs"}' -NoNewline
  Set-Content -LiteralPath (Join-Path $plugin 'Data\results\race.txt') -Value 'P1 somebody' -NoNewline
  Set-Content -LiteralPath (Join-Path $res 'Server\RaceManager_old\main.lua') -Value "local RM_BUILD = '0.0.0'`nprint('[RaceManager] loaded')" -NoNewline
  Set-Content -LiteralPath (Join-Path $res 'Server\OtherPlugin\main.lua') -Value "print('RM_ is not ours')" -NoNewline
  ZipWith (Join-Path $res 'Client\RaceManager-v0.19.0.zip') @('lua/ge/extensions/raceManager.lua', 'scripts/raceManager/modScript.lua')
  ZipWith (Join-Path $res 'Client\cars.zip') @('vehicles/buggy/buggy.jbeam')
  Check ((Run $up) -eq 0) 'an old install updates'
  Check (Installed $res) 'to every file the release has'
  Check (-not (Test-Path -LiteralPath (Join-Path $plugin 'stale.lua'))) 'a plugin file the release no longer has is moved out'
  Check ((Get-Content -Raw -LiteralPath (Join-Path $plugin 'Data\config.json')) -eq '{"adminPassword": "theirs"}' -and
    (Get-Content -Raw -LiteralPath (Join-Path $plugin 'Data\results\race.txt')) -eq 'P1 somebody') 'Data is left alone'
  Check (-not (Test-Path -LiteralPath (Join-Path $res 'Client\RaceManager-v0.19.0.zip'))) 'a second copy of the client is moved out'
  Check (-not (Test-Path -LiteralPath (Join-Path $res 'Server\RaceManager_old'))) 'and so is another Race Manager plugin'
  Check ((Test-Path -LiteralPath (Join-Path $res 'Client\cars.zip')) -and (Test-Path -LiteralPath (Join-Path $res 'Server\OtherPlugin\main.lua'))) 'other mods and plugins stay'
  $attic = Get-ChildItem -Path (Join-Path $up '_attic') -Directory | Where-Object Name -like 'install-0.0.1-to-*' | Select-Object -First 1
  Check ($null -ne $attic) 'the attic folder names both versions'
  if ($attic) {
    Check ((Get-Content -Raw -LiteralPath (Join-Path $attic.FullName 'Client\RaceManager.zip')) -eq 'OLD CLIENT' -and
      (Get-Content -Raw -LiteralPath (Join-Path $attic.FullName 'Server\RaceManager\stale.lua')) -eq '-- gone from the release' -and
      (Test-Path -LiteralPath (Join-Path $attic.FullName 'Client\RaceManager-v0.19.0.zip')) -and
      (Test-Path -LiteralPath (Join-Path $attic.FullName 'Server\RaceManager_old\main.lua'))) 'and holds everything it replaced or moved'
  }
  Check ((Run $up) -eq 0) 'installing the same release again works'

  # --- A renamed resources folder -------------------------------------------
  $renamed = Join-Path $root 'renamed'
  NewServer $renamed ($config + "ResourceFolder = `"Res`"`r`n")
  Check ((Run $renamed) -eq 0 -and (Installed (Join-Path $renamed 'Res'))) 'ResourceFolder in ServerConfig.toml is followed'
  Check (-not (Test-Path -LiteralPath (Join-Path $renamed 'Resources'))) 'and nothing goes to Resources'

  # --- A running server ------------------------------------------------------
  $running = Join-Path $root 'running'
  NewServer $running $config
  Copy-Item (Join-Path $env:WINDIR 'System32\PING.EXE') (Join-Path $running 'BeamMP-Server.exe')
  $fake = Start-Process -FilePath (Join-Path $running 'BeamMP-Server.exe') -ArgumentList '-n', '30', '127.0.0.1' -PassThru -WindowStyle Hidden
  try {
    Start-Sleep -Milliseconds 500
    Check ((Run $running) -eq 1) 'a server that is running is refused'
    Check (-not (Test-Path -LiteralPath (Join-Path $running 'Resources'))) 'and nothing is written'
  } finally { Stop-Process -Id $fake.Id -Force -ErrorAction SilentlyContinue }

  # --- A write that fails ----------------------------------------------------
  $locked = Join-Path $root 'locked'
  NewServer $locked $config
  $lres = Join-Path $locked 'Resources'
  New-Item -ItemType Directory -Force -Path (Join-Path $lres 'Server\RaceManager'), (Join-Path $lres 'Client') | Out-Null
  Set-Content -LiteralPath (Join-Path $lres 'Client\RaceManager.zip') -Value 'OLD CLIENT' -NoNewline
  Set-Content -LiteralPath (Join-Path $lres 'Server\RaceManager\main.lua') -Value "local RM_BUILD = '0.0.1'" -NoNewline
  $ro = Join-Path $lres 'Server\RaceManager\maps.lua'
  Set-Content -LiteralPath $ro -Value '-- old maps' -NoNewline
  (Get-Item -LiteralPath $ro).IsReadOnly = $true
  Check ((Run $locked) -eq 1) 'a file that cannot be written stops the install'
  Check ((Get-Content -Raw -LiteralPath (Join-Path $lres 'Client\RaceManager.zip')) -eq 'OLD CLIENT' -and
    (Get-Content -Raw -LiteralPath (Join-Path $lres 'Server\RaceManager\main.lua')) -eq "local RM_BUILD = '0.0.1'") 'and every file is put back'
  (Get-Item -LiteralPath $ro).IsReadOnly = $false

  # --- Not a server ------------------------------------------------------------
  $empty = Join-Path $root 'empty'
  New-Item -ItemType Directory -Force -Path $empty | Out-Null
  Check ((Run $empty) -eq 1) 'a folder that is not a BeamMP server is refused'
  Check (@(Get-ChildItem -LiteralPath $empty -Force).Count -eq 0) 'and left empty'
} finally {
  Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
  if ($hadKey -and $before) { Set-ItemProperty -Path $regKey -Name ServerFolder -Value $before }
  elseif (-not $hadKey) { Remove-Item -Path $regKey -Recurse -ErrorAction SilentlyContinue }
}

Write-Host ("installer test: {0} checks, {1} failures" -f $script:checks, $script:fails)
if ($script:fails -gt 0) { exit 1 }
