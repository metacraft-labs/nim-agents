# Acquire only the existing declared Winlibs profile; never alias an SDK compiler.
# Full source/profile/package review and native x64 CI remain required.
$ErrorActionPreference = 'Stop'
$ExpectedHash = '62fb8588d2deee7d662dbcbd386702adbf19643764c971c38aa4839472eee232'
$ExpectedUrl = 'https://github.com/brechtsanders/winlibs_mingw/releases/download/16.1.0posix-14.0.0-ucrt-r2/winlibs-x86_64-posix-seh-gcc-16.1.0-mingw-w64ucrt-14.0.0-r2.7z'
$ExpectedCompilerSHA = '61faf79766e5e4f9170d1a3776ad13b4daf380d11f3d7fbaa0d94c4d71533496'
$ExpectedCompilerBlake3 = 'blake3:3d3fc5366f262a8de80e9650cbd174c0ad075874cb8d1691a9cca2b29cd05edd'
$ExpectedPayloadSHA = '004555fc4f053cc1c7ed58594c9c71ab95c902d954b4591a618959b94759564b'
function Regular-File([string]$path) {
  if (-not [IO.Path]::IsPathFullyQualified($path)) { throw 'Relative file authority refused' }
  $item = Get-Item -LiteralPath $path -Force
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Nonregular file authority refused' }
  [ordered]@{path=$item.FullName;length=$item.Length;attributes=[string]$item.Attributes;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
}
function Checked-Directory([string]$path) {
  if (-not [IO.Path]::IsPathFullyQualified($path)) { throw 'Relative directory authority refused' }
  $item = Get-Item -LiteralPath $path -Force
  if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Foreign directory authority refused' }
  $item.FullName
}
function Prefix-Census([string]$prefix) {
  $prefix = Checked-Directory $prefix
  $rows = @()
  foreach ($item in @(Get-ChildItem -LiteralPath $prefix -Force -Recurse | Sort-Object FullName)) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse member refused' }
    $rel = [IO.Path]::GetRelativePath($prefix,$item.FullName)
    if ($rel.StartsWith('..') -or [IO.Path]::IsPathRooted($rel)) { throw 'Escaped prefix member refused' }
    if ($item.PSIsContainer) { $rows += [ordered]@{name=$rel;kind='directory';attributes=[string]$item.Attributes} }
    else { $f=Regular-File $item.FullName; $rows += [ordered]@{name=$rel;kind='file';attributes=$f.attributes;length=$f.length;sha256=$f.sha256} }
  }
  $rows
}
function Validate-Profile($profile,[string]$store) {
  if ($profile.packageSelector -cne 'gcc' -or $profile.installMethod -cne 'tarball' -or $profile.packageId -cne 'gcc-winlibs@16.1.0') { throw 'Foreign GCC package refused' }
  if ($profile.tarballSha256 -cne $ExpectedHash -or $profile.tarballUrl -cne $ExpectedUrl -or $profile.archiveType -cne '7z' -or $profile.stripComponents -ne 1 -or $profile.declaredExecutablePath -cne 'bin/gcc.exe') { throw 'Foreign GCC archive contract refused' }
  $prefix=Checked-Directory $profile.selectedStorePath
  $allowed=(Checked-Directory (Join-Path $store 'prefixes')) + [IO.Path]::DirectorySeparatorChar
  if (-not $prefix.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Foreign realized prefix refused' }
  foreach($parent in @($store,(Join-Path $store 'prefixes'),(Split-Path $prefix -Parent),$prefix)) { Checked-Directory $parent | Out-Null }
  $exe=Regular-File $profile.resolvedExecutablePath
  if ($exe.sha256 -cne $ExpectedCompilerSHA -or $profile.resolvedExecutableDigest -cne $ExpectedCompilerBlake3) { throw 'Archive-bound compiler digest refused' }
  $expected=[IO.Path]::GetFullPath((Join-Path $prefix 'bin/gcc.exe'))
  if ($exe.path -ine $expected -or @($profile.pathSearchList).Count -ne 1 -or $profile.pathSearchList[0] -ine (Split-Path $expected -Parent)) { throw 'Foreign compiler path refused' }
  $stream=[IO.File]::Open($exe.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  try {
    $reader=[IO.BinaryReader]::new($stream)
    if($reader.ReadUInt16() -ne 0x5a4d){throw 'Missing DOS image header'}
    $stream.Position=0x3c;$pe=$reader.ReadUInt32()
    if($pe -gt $stream.Length-26){throw 'Truncated PE image'}
    $stream.Position=$pe
    if($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664){throw 'Non-AMD64 compiler refused'}
    $stream.Position=$pe+24
    if($reader.ReadUInt16() -ne 0x20b){throw 'Non-PE32+ compiler refused'}
  } finally {$stream.Dispose()}
  [ordered]@{prefix=$prefix;executable=$exe}
}
function Validate-Payload($rows) {
  $byName=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
  foreach($row in $rows) {
    $name=$row.name.Replace([char]92,[char]47)
    if($name.Contains([char]0) -or $name.Contains("`n") -or $name.Contains("`r")){throw 'Malformed package member name'}
    if($name -ceq '.repro-receipt' -or $name -ceq '.reprobuild-tarball-receipt.json'){continue}
    if($byName.ContainsKey($name)){throw 'Duplicate payload member'}
    $byName.Add($name,$row)
  }
  if($byName.Count -ne 12153){throw 'Archive payload membership refused'}
  $names=[Collections.Generic.List[string]]::new();foreach($name in $byName.Keys){$names.Add($name)};$names.Sort([StringComparer]::Ordinal)
  $encoded=[Text.StringBuilder]::new()
  foreach($name in $names){
    $r=$byName[$name]
    if($r.kind -ceq 'directory'){[void]$encoded.Append("D`0$name`n")}
    elseif($r.kind -ceq 'file'){[void]$encoded.Append("F`0$name`0$($r.length)`0$($r.sha256)`n")}
    else{throw 'Foreign payload member type'}
  }
  $sha=[Security.Cryptography.SHA256]::Create()
  try{$digest=[Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($encoded.ToString()))).ToLowerInvariant()}finally{$sha.Dispose()}
  if($digest -cne $ExpectedPayloadSHA){throw 'Actual runtime/header payload differs from declared archive'}
  $digest
}
function Freeze-Owning([string]$root,[string]$git) {
  $head=@(& $git rev-parse --verify HEAD);if($LASTEXITCODE -ne 0 -or $head.Count -ne 1){throw 'Owning HEAD unavailable'}
  $index=@(& $git rev-parse --path-format=absolute --git-path index);if($LASTEXITCODE -ne 0 -or $index.Count -ne 1){throw 'Owning index unavailable'}
  [ordered]@{head=$head[0];index=(Regular-File $index[0]);recipe=(Regular-File (Join-Path $root 'repro.nim'));lock=(Regular-File (Join-Path $root 'repro.lock'))}
}
function Verified-Archive([string]$store,[string]$root) {
  $cache=Join-Path $store "downloads/$ExpectedHash.archive"
  if(Test-Path -LiteralPath $cache){$file=Regular-File $cache;if($file.sha256 -cne $ExpectedHash){throw 'Actual cached archive integrity refused'};return $file}
  # A source-bound cache substitution may have no download. Retrieve the same
  # declared bytes into a new task-owned file; never overwrite a cache member.
  $path=Join-Path $root ('.repro/gcc-declared-archive-'+[Guid]::NewGuid().ToString('N')+'.7z')
  $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  $client=[Net.Http.HttpClient]::new()
  try{$input=$client.GetStreamAsync($ExpectedUrl).GetAwaiter().GetResult();try{$input.CopyTo($stream)}finally{$input.Dispose()}}finally{$stream.Dispose();$client.Dispose()}
  $file=Regular-File $path;if($file.sha256 -cne $ExpectedHash){throw 'Actual retrieved archive integrity refused'};$file
}
function Write-AcquisitionAttempt([string]$root,$receipt) {
  $root=Checked-Directory $root
  $metadataPath=Join-Path $root '.repro'
  if (-not (Test-Path -LiteralPath $metadataPath)) {
    # No Force: a raced existing entry is a refusal, never an overwrite.
    New-Item -ItemType Directory -Path $metadataPath -ErrorAction Stop | Out-Null
  }
  $directory=Checked-Directory $metadataPath
  $out=Join-Path $directory ('gcc-profile-acquisition-attempt-'+[Guid]::NewGuid().ToString('N')+'.json')
  $stream=[IO.File]::Open($out,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{$bytes=[Text.Encoding]::UTF8.GetBytes(($receipt|ConvertTo-Json -Depth 8));$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
  $out
}
function Acquire-DeclaredGcc {
  if($env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'X64' -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64'){throw 'Native Windows x64 boundary required'}
  $root=(Get-Location).Path
  $store=Join-Path $root '.repro/build/repro/tool-store'
  $git=(Get-Command git -CommandType Application -ErrorAction Stop).Source
  $gitBefore=Regular-File $git
  $ownBefore=Freeze-Owning $root $git
  $pathFile=Regular-File $env:GITHUB_PATH
  $pathBefore=[IO.File]::ReadAllBytes($pathFile.path)
  $public=(Get-Command repro -CommandType Application -ErrorAction Stop).Source
  $publicBefore=Regular-File $public
  $scriptBefore=Regular-File $PSCommandPath
  try {
  $sdk=[ordered]@{}
  foreach($name in @('nim.exe','gcc.exe')) {
    $candidate=Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
    if($candidate){$sdk[$name]=Regular-File $candidate.Source}
  }
  $attempt=[ordered]@{scope='pre-graph authority only; GCC profile and product actions unexecuted';publicCLI=$publicBefore;script=$scriptBefore;git=$gitBefore;owning=$ownBefore;workflow=(Regular-File (Join-Path $root '.github/workflows/ci-reprobuild.yml'));sdkCandidates=$sdk}
  $attemptPath=Write-AcquisitionAttempt $root $attempt
  Write-Output "Pre-graph authority receipt: $attemptPath"
  $raw = & $public graph test --json --tool-provisioning=tarball
  if($LASTEXITCODE -ne 0){throw 'Declared tarball graph acquisition failed'}
  $graph=($raw -join "`n") | ConvertFrom-Json
  $inspection=Regular-File $graph.toolInspectionPath
  $payload=Get-Content -LiteralPath $inspection.path -Raw | ConvertFrom-Json
  $profiles=@($payload.profiles | Where-Object {$_.packageSelector -ceq 'gcc'})
  if($profiles.Count -ne 1){throw 'Expected one declared GCC profile'}
  $bound=Validate-Profile $profiles[0] $store
  $archiveFile=Verified-Archive $store $root
  $archive=$archiveFile.path
  $before=@(Prefix-Census $bound.prefix)
  $payloadDigest=Validate-Payload $before
  $provenance=Get-Content -LiteralPath (Join-Path $bound.prefix ".reprobuild-tarball-receipt.json") -Raw | ConvertFrom-Json
  if($provenance.installMethod -cne "tarball" -or $provenance.packageSelector -cne "gcc" -or $provenance.packageId -cne "gcc-winlibs@16.1.0" -or $provenance.sha256 -cne $ExpectedHash -or $provenance.url -cne $ExpectedUrl -or $provenance.archiveType -cne "7z" -or $provenance.stripComponents -ne 1 -or @($provenance.prunePaths).Count -ne 0 -or $provenance.declaredExecutablePath -cne "bin/gcc.exe"){throw "Foreign realization provenance refused"}
  if(-not @($before | Where-Object {$_.kind -eq 'file' -and $_.name -match '(?i)(^|[\\/])include[\\/]string\.h$'}).Count){throw 'Complete compiler header closure missing'}
  if(-not @($before | Where-Object {$_.kind -eq 'file' -and $_.name -match '(?i)\.dll$'}).Count){throw 'Complete compiler DLL closure missing'}
  if(-not @($before | Where-Object {$_.kind -eq 'file' -and $_.name -match '(?i)(^|[\\/])cc1\.exe$'}).Count){throw 'Compiler frontend closure missing'}
  $version=@(& $bound.executable.path -dumpfullversion 2>&1 | ForEach-Object {"$_"})
  if($LASTEXITCODE -ne 0 -or $version.Count -ne 1 -or $version[0] -notmatch '^\d+\.\d+(\.\d+)?$' -or [Version]$version[0] -lt [Version]'12.0'){throw 'Real compiler floor refused'}
  $target=@(& $bound.executable.path -dumpmachine 2>&1 | ForEach-Object {"$_"})
  if($LASTEXITCODE -ne 0 -or $target.Count -ne 1 -or $target[0] -cne 'x86_64-w64-mingw32'){throw 'Real compiler architecture refused'}
  $after=@(Prefix-Census $bound.prefix)
  Validate-Payload $after | Out-Null
  $ownAfter=Freeze-Owning $root $git
  if(($ownBefore|ConvertTo-Json -Depth 6 -Compress) -cne ($ownAfter|ConvertTo-Json -Depth 6 -Compress) -or (Regular-File $git).sha256 -cne $gitBefore.sha256){throw "Owning source/index/HEAD/tool changed"}
  if(($before|ConvertTo-Json -Depth 8 -Compress) -cne ($after|ConvertTo-Json -Depth 8 -Compress)){throw 'Compiler runtime/header closure changed'}
  if((Regular-File $public).sha256 -cne $publicBefore.sha256 -or (Regular-File $PSCommandPath).sha256 -cne $scriptBefore.sha256 -or (Regular-File $archive).sha256 -cne $archiveFile.sha256 -or (Regular-File $inspection.path).sha256 -cne $inspection.sha256){throw 'Acquisition source/principal changed'}
  $receipt=[ordered]@{scope='declared GCC preparation only; original actions unexecuted';publicCLI=$publicBefore;script=$scriptBefore;inspection=$inspection;archive=$archiveFile;profile=[ordered]@{packageSelector=$profiles[0].packageSelector;packageId=$profiles[0].packageId;archiveSha256=$ExpectedHash;profileFingerprint=$profiles[0].profileFingerprint;resolvedExecutableDigest=$profiles[0].resolvedExecutableDigest};git=$gitBefore;owningBefore=$ownBefore;owningAfter=$ownAfter;payloadSha256=$payloadDigest;compiler=$bound.executable;version=$version[0];target=$target[0];before=$before;after=$after}
  $out=Join-Path $root ('.repro/gcc-profile-acquisition-'+[Guid]::NewGuid().ToString('N')+'.json')
  $stream=[IO.File]::Open($out,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{$bytes=[Text.Encoding]::UTF8.GetBytes(($receipt|ConvertTo-Json -Depth 10));$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
  if(-not ([Convert]::ToBase64String($pathBefore) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($pathFile.path)))){throw "GITHUB_PATH changed before activation"}
  $stream=[IO.File]::Open($pathFile.path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  try{$stream.Seek(0,[IO.SeekOrigin]::End)|Out-Null;$bytes=[Text.Encoding]::UTF8.GetBytes((Split-Path $bound.executable.path -Parent)+"`n");$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
  Write-Output "Declared GCC acquisition receipt: $out"
  } finally {
    $finalOwn=Freeze-Owning $root $git
    if(($ownBefore|ConvertTo-Json -Depth 6 -Compress) -cne ($finalOwn|ConvertTo-Json -Depth 6 -Compress) -or (Regular-File $git).sha256 -cne $gitBefore.sha256 -or (Regular-File $public).sha256 -cne $publicBefore.sha256 -or (Regular-File $PSCommandPath).sha256 -cne $scriptBefore.sha256){throw 'Acquisition final source/principal guard refused'}
  }
}
if($MyInvocation.InvocationName -ne '.') { Acquire-DeclaredGcc }
