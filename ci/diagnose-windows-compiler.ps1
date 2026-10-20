# Failure-only ordinary compiler/file diagnostic. Original job failure is preserved.
# The SDK-resolved GCC is diagnostic authority, not proof of a failed action image.
param([Parameter(Mandatory=$true)][ValidateSet('x64','arm64')][string]$Architecture)
$ErrorActionPreference = 'Stop'
$root = Join-Path (Get-Location).Path '.repro/compiler-diagnostics'
[IO.Directory]::CreateDirectory($root) | Out-Null
$id = [Guid]::NewGuid().ToString('N')
$receipt = Join-Path $root "$id.json"
$result = [ordered]@{ scope='failure-only SDK compiler probe'; productVerdict=$null; declaredArchitecture=$Architecture; probeABI=64; observations=@() }
function Hash-Regular([string]$path) {
  $item = Get-Item -LiteralPath $path
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Expected regular file' }
  [ordered]@{ path=$item.FullName; length=$item.Length; attributes=[string]$item.Attributes; lastWriteUtc=$item.LastWriteTimeUtc.ToString('o'); sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
}
try {
  $reports = @(Get-ChildItem -LiteralPath '.repro/build' -Filter 'build-failure-report.json' -Recurse -File)
  if ($reports.Count -ne 1) { throw 'Expected one original failure report' }
  $scriptBefore = Hash-Regular $PSCommandPath
  $reportBefore = Hash-Regular $reports[0].FullName
  $result.script = $scriptBefore
  $result.originalReport = $reportBefore
  $report = Get-Content -LiteralPath $reports[0].FullName -Raw | ConvertFrom-Json
  $paths = @($report.failedActions | ForEach-Object { $_.argv[0] } | Select-Object -Unique)
  if ($paths.Count -ne 1 -or -not [IO.Path]::IsPathRooted($paths[0])) { throw 'Original Nim executable authority unavailable' }
  $nim = $paths[0]
  $base = Join-Path (Split-Path (Split-Path $nim -Parent) -Parent) 'lib/nimbase.h'
  $nimBefore = Hash-Regular $nim
  $baseBefore = Hash-Regular $base
  $result.originalNimbase = $baseBefore
  $gcc = (Get-Command gcc.exe -CommandType Application -ErrorAction Stop).Source
  $before = @($nimBefore, $baseBefore, (Hash-Regular $gcc), $reportBefore)
  $result.originalReport = $before[3]
  $result.originalNim = $before[0]
  $result.sdkGcc = $before[2]
  $result.sdkGccVersion = @(& $gcc --version 2>&1 | ForEach-Object { "$_" })
  $result.sdkGccVersionExit = $LASTEXITCODE
  $src = Join-Path $root "$id.c"
  $obj = Join-Path $root "$id.o"
  $stream = [IO.File]::Open($src, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try {
    $body = "#define NIM_INTBITS 64`n#include <nimbase.h>`n#include <string.h>`ntypedef char probe_requires_64bit_pointer[(sizeof(void*) == 8) ? 1 : -1];`nint main(void) { return strlen(`"a`") != 1; }`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $stream.Write($bytes,0,$bytes.Length)
  } finally { $stream.Dispose() }
  $result.probeSource = Hash-Regular $src
  $result.probeOutput = @(& $gcc '-c' '-H' ('-I' + (Split-Path $base -Parent)) $src '-o' $obj 2>&1 | ForEach-Object { "$_" })
  $result.probeExit = $LASTEXITCODE
  $after = @((Hash-Regular $nim), (Hash-Regular $base), (Hash-Regular $gcc), (Hash-Regular $reports[0].FullName))
  $scriptAfter = Hash-Regular $PSCommandPath
  $result.scriptUnchanged = (($scriptBefore | ConvertTo-Json -Compress) -ceq ($scriptAfter | ConvertTo-Json -Compress))
  $result.reportUnchangedSinceBeforeParsing = (($reportBefore | ConvertTo-Json -Compress) -ceq ($after[3] | ConvertTo-Json -Compress))
  if (-not $result.scriptUnchanged -or -not $result.reportUnchangedSinceBeforeParsing) { throw 'Script/report authority changed' }
  $result.observedFilesUnchanged = (($before | ConvertTo-Json -Depth 5 -Compress) -ceq ($after | ConvertTo-Json -Depth 5 -Compress))
  if (-not $result.observedFilesUnchanged) { throw 'Observed file identity changed' }
  if (Test-Path -LiteralPath $obj) { $result.object = Hash-Regular $obj }
} catch {
  $result.diagnosticError = $_.Exception.ToString()
} finally {
  $bytes = [Text.Encoding]::UTF8.GetBytes(($result | ConvertTo-Json -Depth 10))
  $stream = [IO.File]::Open($receipt, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
  Write-Output "Diagnostic receipt: $receipt"
}
