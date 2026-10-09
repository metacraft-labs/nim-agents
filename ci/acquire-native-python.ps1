param([Parameter(Mandatory=$true)][ValidateSet('x64','arm64')][string]$Architecture)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Native Windows interpreter acquisition required' }
$ownershipSource = Join-Path $PSScriptRoot 'native-python-owned-path.ps1'
. $ownershipSource
$ownershipHash = (Get-FileHash -LiteralPath $ownershipSource -Algorithm SHA256).Hash
$cleanupSourceHash = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'cleanup-native-python.ps1') -Algorithm SHA256).Hash
$state = @{ success=$false; completeInventory=$false; failure=$null; ownedRuntime=$null }
$rootHandle=$null; $payloadHandle=$null; $receiptHandle=$null
$receiptPath=$null
try {
$subject = (Get-Item -LiteralPath $PSCommandPath).FullName
$scriptHash = (Get-FileHash -LiteralPath $subject -Algorithm SHA256).Hash
$owner = (Get-Item -LiteralPath (Get-Location).Path)
if ($owner.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Foreign consumer root' }
$receiptParent = Assert-SafeDirectory (Join-Path $owner.FullName '.repro')
$receiptHandle = [NativePythonOwnedPath]::new($receiptParent,$false)
$receiptParentIdentity = $receiptHandle.Identity()
$receiptPath = Join-Path $receiptParent ('native-python-acquisition-' + [Guid]::NewGuid().ToString('N') + '.json')
[IO.File]::AppendAllText($env:GITHUB_ENV, "NIM_NATIVE_PYTHON_RECEIPT=$receiptPath`n", [Text.UTF8Encoding]::new($false))
$head = (& git rev-parse HEAD); if ($LASTEXITCODE) { throw 'Cannot bind consumer HEAD' }
$index = (& git ls-files --stage | Out-String); if ($LASTEXITCODE) { throw 'Cannot bind consumer index' }
$lockHash = (Get-FileHash -LiteralPath (Join-Path $owner.FullName 'repro.lock') -Algorithm SHA256).Hash
$recipeHash = (Get-FileHash -LiteralPath (Join-Path $owner.FullName 'repro.nim') -Algorithm SHA256).Hash
$powerShellImage = Join-Path $PSHOME 'pwsh.exe'
$powerShellHash = (Get-FileHash -LiteralPath $powerShellImage -Algorithm SHA256).Hash
$package = if ($Architecture -eq 'x64') { 'python' } else { 'pythonarm64' }
$expectedHash = if ($Architecture -eq 'x64') { '0eb85c2dfccccf1b17352de4c397f69194035b7d37149eacc16f1147d93de3b8' } else { 'e397423b13b1f1db294cd822b13a695b9f95193f2dc4572ff30dd5cd83b99c37' }
$expectedLength = if ($Architecture -eq 'x64') { 14515433 } else { 13774002 }
$expectedMachine = if ($Architecture -eq 'x64') { 0x8664 } else { 0xaa64 }
$root = Join-Path $owner.FullName ('.native-python-' + [Guid]::NewGuid().ToString('N'))
$claim = New-Item -ItemType Directory -Path $root -ErrorAction Stop
if ($claim.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Foreign runtime claim' }
$rootHandle = [NativePythonOwnedPath]::new($root,$false)
$rootIdentity = $rootHandle.Identity()
$state.ownedRuntime = $root
$archive = Join-Path $root 'python.nupkg'
$url = "https://api.nuget.org/v3-flatcontainer/$package/3.12.10/$package.3.12.10.nupkg"
Invoke-WebRequest -Uri $url -OutFile $archive
if ((Get-Item -LiteralPath $archive).Length -ne $expectedLength -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) { throw 'Foreign official Python archive' }
$payload = Join-Path $root 'payload'
$null = New-Item -ItemType Directory -Path $payload -ErrorAction Stop
$payloadHandle = [NativePythonOwnedPath]::new($payload,$false)
$payloadIdentity = $payloadHandle.Identity()
$prefix = [IO.Path]::GetFullPath($payload) + [IO.Path]::DirectorySeparatorChar
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
$directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$entries = @(); $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
try {
    if ($zip.Entries.Count -ne 1329) { throw 'Foreign Python archive membership' }
    foreach ($entry in $zip.Entries) {
        $name = $entry.FullName
        if ($name.Contains('\') -or $name.Contains(':') -or $name.Contains("`r") -or $name.Contains("`n") -or [IO.Path]::IsPathRooted($name) -or ($name.Split('/') -contains '..') -or -not $seen.Add($name.TrimEnd('/'))) { throw 'Foreign archive entry' }
        if ((($entry.ExternalAttributes -shr 16) -band 0xf000) -eq 0xa000) { throw 'Archive symlink refused' }
        $parts = $name.TrimEnd('/').Split('/')
        $limit = if ($name.EndsWith('/')) { $parts.Count } else { $parts.Count - 1 }
        for ($i=1; $i -le $limit; $i++) { [void]$directories.Add(($parts[0..($i-1)] -join '/')) }
        $destination = [IO.Path]::GetFullPath((Join-Path $payload $name))
        if (-not $destination.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Escaped archive entry' }
        if ($name.EndsWith('/')) { $null = [IO.Directory]::CreateDirectory($destination); continue }
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        $input = $entry.Open(); $output = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
        if ((Get-Item -LiteralPath $destination).Length -ne $entry.Length) { throw 'Incomplete package entry' }
        $entries += @{ path=$name; length=$entry.Length; sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash }
    }
} finally { $zip.Dispose() }
$actualFiles = @(Get-ChildItem -LiteralPath $payload -Recurse -File -Force)
if ($actualFiles.Count -ne $entries.Count -or @(Get-ChildItem -LiteralPath $payload -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Foreign realized runtime membership' }
$python = Join-Path $payload 'tools/python.exe'
$pe = [IO.File]::ReadAllBytes($python); if ($pe.Length -lt 64) { throw 'Truncated Python PE' }; $offset = [BitConverter]::ToInt32($pe, 0x3c)
if ($pe.Length -lt 64 -or $offset -lt 0 -or $offset + 6 -gt $pe.Length -or [BitConverter]::ToUInt32($pe,$offset) -ne 0x4550 -or [BitConverter]::ToUInt16($pe,$offset+4) -ne $expectedMachine) { throw 'Foreign Python PE architecture' }
$signatures = @{}
$signedMembers = @('tools/python.exe') + @(Get-ChildItem -LiteralPath (Join-Path $payload 'tools') -Filter '*.dll' -File | ForEach-Object { 'tools/' + $_.Name })
foreach ($relative in $signedMembers) {
    $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $payload $relative)
    $vendor = if ($relative -match '^tools/python(?:3|312)?\.dll$' -or $relative -eq 'tools/python.exe') { 'Python Software Foundation' } elseif ($relative -match '^tools/vcruntime[0-9_]*\.dll$') { 'Microsoft Corporation' } else { throw 'Unknown runtime DLL publisher policy' }
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch ('O=' + [regex]::Escape($vendor) + '(?:,|$)')) { throw 'Untrusted official Python image' }
    $signatures[$relative] = @{ status=$signature.Status.ToString(); subject=$signature.SignerCertificate.Subject; thumbprint=$signature.SignerCertificate.Thumbprint }
}

function Assert-RuntimeAuthority {
    if ($rootHandle.Identity() -ne $rootIdentity -or (Get-NativeIdentity $root) -ne $rootIdentity -or $payloadHandle.Identity() -ne $payloadIdentity -or (Get-NativeIdentity $payload) -ne $payloadIdentity -or $receiptHandle.Identity() -ne $receiptParentIdentity -or (Get-NativeIdentity $receiptParent) -ne $receiptParentIdentity) { throw 'Changed runtime or receipt directory authority' }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) { throw 'Changed package archive' }
    foreach ($member in $entries) {
        $file = Get-Item -LiteralPath (Join-Path $payload $member.path)
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -ne $member.length -or (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $member.sha256) { throw 'Changed runtime member' }
    }
    $actualDirectories = @(Get-ChildItem -LiteralPath $payload -Recurse -Directory -Force)
    if ($actualDirectories.Count -ne $directories.Count) { throw 'Changed runtime directories' }
    foreach ($directory in $actualDirectories) {
        $relative = [IO.Path]::GetRelativePath($payload,$directory.FullName).Replace('\','/')
        if (-not $directories.Contains($relative)) { throw 'Unknown runtime directory' }
    }
    if (@(Get-ChildItem -LiteralPath $payload -Recurse -File -Force).Count -ne $entries.Count -or @(Get-ChildItem -LiteralPath $payload -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Changed runtime inventory' }
}
Assert-RuntimeAuthority
$observation = & $python -B -I -c 'import sys,struct,platform,json;print(json.dumps({"version":list(sys.version_info[:3]),"pointerBits":struct.calcsize("P")*8,"machine":platform.machine(),"executable":sys.executable}))'
if ($LASTEXITCODE) { throw 'Native Python execution failed' }
$observed = $observation | ConvertFrom-Json
$expectedObservedMachine = if ($Architecture -eq 'x64') { 'AMD64' } else { 'ARM64' }
if ([IO.Path]::GetFullPath($observed.executable) -cne [IO.Path]::GetFullPath($python) -or $observed.machine -cne $expectedObservedMachine -or ($observed.version -join '.') -ne '3.12.10' -or $observed.pointerBits -ne 64) { throw 'Foreign native Python execution' }
Assert-RuntimeAuthority
$finalIndex = (& git ls-files --stage | Out-String); if ($LASTEXITCODE) { throw 'Final Git index observation failed' }
$finalHead = (& git rev-parse HEAD); if ($LASTEXITCODE) { throw 'Final Git HEAD observation failed' }
if ($finalIndex -ne $index -or $finalHead -ne $head -or (Get-FileHash -LiteralPath (Join-Path $owner.FullName 'repro.lock') -Algorithm SHA256).Hash -ne $lockHash -or (Get-FileHash -LiteralPath (Join-Path $owner.FullName 'repro.nim') -Algorithm SHA256).Hash -ne $recipeHash -or (Get-FileHash -LiteralPath $powerShellImage -Algorithm SHA256).Hash -ne $powerShellHash -or (Get-FileHash -LiteralPath $subject -Algorithm SHA256).Hash -ne $scriptHash -or (Get-FileHash -LiteralPath $ownershipSource -Algorithm SHA256).Hash -ne $ownershipHash) { throw 'Changed declared source or tool authority' }
$receipt = @{ declaredArchitecture=$Architecture; observed=$observed; scriptSHA256=$scriptHash; sourceHead=$head; sourceIndex=$index; lockSHA256=$lockHash; recipeSHA256=$recipeHash; powerShellImage=$powerShellImage; powerShellSHA256=$powerShellHash; archiveUrl=$url; archiveSHA256=$expectedHash; runtimeRoot=$root; entries=$entries; directories=@($directories); signatures=$signatures; productVerdict=$null }
$state += $receipt
$state.rootIdentity=$rootIdentity; $state.payloadIdentity=$payloadIdentity; $state.receiptParentIdentity=$receiptParentIdentity
$state.ownershipSourceSHA256=$ownershipHash
$state.cleanupSourceSHA256=$cleanupSourceHash
$state.inventory=Get-RuntimeInventory $root
$state.completeInventory=$true
$state.success=$true
} catch {
    $state.failure = @{ type=$_.Exception.GetType().FullName; message=$_.Exception.Message; stack=$_.ScriptStackTrace }
} finally {
    try {
        if ($receiptPath) {
            $stream = [IO.File]::Open($receiptPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $bytes=[Text.Encoding]::UTF8.GetBytes(($state | ConvertTo-Json -Depth 12)); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
        }
        if ($state.success) {
            Assert-RuntimeAuthority
            [IO.File]::AppendAllText($env:GITHUB_ENV, "NIM_NATIVE_PYTHON=$($python.Replace('\','/'))`n", [Text.UTF8Encoding]::new($false))
        }
    } finally {
        foreach ($handle in @($payloadHandle,$rootHandle,$receiptHandle)) { if ($handle) { $handle.Dispose() } }
    }
}
if (-not $state.success) { throw ('Native Python acquisition failed: ' + $state.failure.message) }
