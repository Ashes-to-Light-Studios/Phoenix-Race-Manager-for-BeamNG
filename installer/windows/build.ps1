# Builds PRM-Setup.exe: a release zip inside a small Windows installer.
#
#   pwsh installer/windows/build.ps1 -Zip dist/RaceManager-v0.22.0.zip -Out dist/PRM-Setup.exe
#
# The compiler is the one in .NET Framework 4.x, part of every Windows 10 and
# 11 and of GitHub's Windows runners, so there is nothing to install. That pins
# Setup.cs to C# 5.
param(
  [Parameter(Mandatory = $true)][string]$Zip,
  [string]$Out = 'PRM-Setup.exe'
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "no C# compiler at $csc (.NET Framework 4.x)" }
$zipPath = (Resolve-Path $Zip).Path

# The version comes from the release itself, so the exe cannot claim another.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
  $entry = $archive.GetEntry('Server/RaceManager/main.lua')
  if (-not $entry) { throw "$Zip has no Server/RaceManager/main.lua" }
  $reader = New-Object System.IO.StreamReader($entry.Open())
  try { $main = $reader.ReadToEnd() } finally { $reader.Dispose() }
} finally { $archive.Dispose() }
if ($main -notmatch "(?m)^local RM_BUILD = '(\d+\.\d+\.\d+)'") { throw "no RM_BUILD in the release's main.lua" }
$version = $Matches[1]

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('prm-setup-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $versionCs = Join-Path $tmp 'Version.cs'
  Set-Content -Path $versionCs -Encoding UTF8 -Value @"
using System.Reflection;
[assembly: AssemblyTitle("Phoenix Race Manager Setup")]
[assembly: AssemblyDescription("Installs Phoenix Race Manager into a BeamMP server")]
[assembly: AssemblyProduct("Phoenix Race Manager")]
[assembly: AssemblyCopyright("Copyright (c) 2026 Phoenix. MIT License.")]
[assembly: AssemblyVersion("$version.0")]
[assembly: AssemblyFileVersion("$version.0")]
[assembly: AssemblyInformationalVersion("$version")]
"@
  & $csc /nologo /target:winexe /optimize+ /platform:anycpu "/out:$Out" `
    "/win32icon:$here\prm.ico" "/win32manifest:$here\app.manifest" `
    "/resource:$zipPath,RaceManager.zip" "/resource:$here\prm.ico,prm.ico" `
    /reference:System.IO.Compression.dll /reference:System.Windows.Forms.dll /reference:System.Drawing.dll `
    "$here\Setup.cs" $versionCs
  if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }
} finally {
  Remove-Item -Recurse -Force $tmp
}
Write-Host ("built {0}: Phoenix Race Manager {1}, {2:N0} bytes" -f $Out, $version, (Get-Item $Out).Length)
