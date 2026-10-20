$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Native Windows owned cleanup required' }
$ownershipSource = Join-Path $PSScriptRoot 'native-python-owned-path.ps1'
. $ownershipSource
$owner = (Get-Item -LiteralPath (Get-Location).Path).FullName
$receiptParent = Join-Path $owner '.repro'
$receiptPath = [IO.Path]::GetFullPath($env:NIM_NATIVE_PYTHON_RECEIPT)
if ([IO.Path]::GetDirectoryName($receiptPath) -cne $receiptParent) { throw 'Foreign acquisition receipt path' }
$receiptParentHandle = [NativePythonOwnedPath]::new($receiptParent,$false)
$handles = @{}; $deleted = @(); $errorRecord = $null; $result = @{ success=$false; deleted=@() }
try {
    $receiptFile = Get-Item -LiteralPath $receiptPath -Force
    if ($receiptFile.PSIsContainer -or ($receiptFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Foreign acquisition receipt' }
    $receiptHash = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
    if (-not $receipt.success -or -not $receipt.completeInventory) { throw 'Incomplete owned runtime retained; cleanup refused' }
    if ($receiptParentHandle.Identity() -ne $receipt.receiptParentIdentity) { throw 'Changed receipt parent' }
    $head = (& git rev-parse HEAD); if ($LASTEXITCODE) { throw 'Cleanup Git HEAD observation failed' }
    $index = (& git ls-files --stage | Out-String); if ($LASTEXITCODE) { throw 'Cleanup Git index observation failed' }
    if ($head -ne $receipt.sourceHead -or $index -ne $receipt.sourceIndex -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'acquire-native-python.ps1') -Algorithm SHA256).Hash -ne $receipt.scriptSHA256 -or (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash -ne $receipt.cleanupSourceSHA256 -or (Get-FileHash -LiteralPath $ownershipSource -Algorithm SHA256).Hash -ne $receipt.ownershipSourceSHA256) { throw 'Changed cleanup source authority' }
    $root = [IO.Path]::GetFullPath($receipt.runtimeRoot)
    if ([IO.Path]::GetDirectoryName($root) -cne $owner -or [IO.Path]::GetFileName($root) -notmatch '^\.native-python-[0-9a-f]{32}$') { throw 'Foreign runtime namespace' }
    $actual = Get-RuntimeInventory $root
    if ($actual.Count -ne $receipt.inventory.Count) { throw 'Unknown runtime membership retained' }
    foreach ($relative in $receipt.inventory.Keys) {
        if (-not $actual.ContainsKey($relative)) { throw 'Missing owned runtime member' }
        $expected = $receipt.inventory[$relative]; $found = $actual[$relative]
        if ($found.identity -ne $expected.identity -or $found.directory -ne $expected.directory) { throw 'Replaced runtime member retained' }
        if (-not $found.directory -and ($found.sha256 -ne $expected.sha256 -or $found.length -ne $expected.length)) { throw 'Changed runtime body retained' }
        $path = if ($relative -eq '.') { $root } else { Join-Path $root $relative }
        $handle = [NativePythonOwnedPath]::new($path,$true)
        $handles[$relative] = $handle
        if ($handle.Identity() -ne $expected.identity) { throw 'Runtime member changed during ownership acquisition' }
        if (-not $found.directory -and $handle.Hash() -ne $expected.sha256) { throw 'Runtime body changed before deletion' }
    }
    # Every known file/directory is now held; deletion uses those handles,
    # not a second path lookup. Unknown new members make directory deletion fail.
    if ((Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash -ne $receiptHash) { throw 'Changed acquisition receipt' }
    $files = @($receipt.inventory.Keys | Where-Object { -not $receipt.inventory[$_].directory })
    $directories = @($receipt.inventory.Keys | Where-Object { $receipt.inventory[$_].directory } | Sort-Object { $_.Length } -Descending)
    foreach ($relative in @($files) + @($directories)) {
        if ($handles[$relative].Identity() -ne $receipt.inventory[$relative].identity) { throw 'Changed held runtime authority' }
        $handles[$relative].Delete(); $handles[$relative].Dispose(); $handles.Remove($relative); $deleted += $relative
    }
    $result.success = $true
} catch {
    $errorRecord = $_
    $result.failure = @{ type=$_.Exception.GetType().FullName; message=$_.Exception.Message; stack=$_.ScriptStackTrace }
} finally {
    foreach ($handle in $handles.Values) { $handle.Dispose() }
    try {
        $result.deleted = $deleted
        $result.sourceSHA256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
        $result.acquisitionReceipt = $receiptPath
        $output = Join-Path $receiptParent ('native-python-cleanup-' + [Guid]::NewGuid().ToString('N') + '.json')
        $stream = [IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $bytes=[Text.Encoding]::UTF8.GetBytes(($result | ConvertTo-Json -Depth 8)); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
    } finally { $receiptParentHandle.Dispose() }
}
if ($errorRecord) { throw $errorRecord }
