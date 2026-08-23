[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Version = '0.1.0-candidate.15'
$Channel = 'pilot'
$ArchiveUrl = 'https://raw.githubusercontent.com/githubxjh/beschannels-ai-ops-releases/v0.1.0-candidate.15/releases/0.1.0-candidate.15/beschannels-ai-ops-0.1.0-candidate.15-windows-x64.zip'
$ArchiveSha256 = '9E70984753322AD5BBFB52C2084B33968EF5851080BD07AC3F8804D89C7F63B3'
$ManifestUrl = 'https://raw.githubusercontent.com/githubxjh/beschannels-ai-ops-releases/v0.1.0-candidate.15/releases/0.1.0-candidate.15/manifest.json'
$ManifestSha256 = 'F0562428C7DCA37E86CCCA83622AC323E6AD5E5BF095D370737D5C2FF227AA2B'
$SignedChannelBase = $ManifestUrl.Substring(0, $ManifestUrl.IndexOf('/releases/')) + '/channels'
$InstallRoot = if ($env:BESCHANNELS_AI_HOME) {
    [IO.Path]::GetFullPath($env:BESCHANNELS_AI_HOME)
} else {
    Join-Path $env:LOCALAPPDATA 'Programs\BesChannelsAIOps'
}
$SkillRoot = if ($env:BESCHANNELS_AI_SKILL_ROOT) {
    [IO.Path]::GetFullPath($env:BESCHANNELS_AI_SKILL_ROOT)
} else {
    Join-Path $HOME '.codex\skills'
}
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('BesChannelsAIOps-' + [guid]::NewGuid().ToString('N'))
$ArchivePath = Join-Path $TempRoot 'release.zip'
$ManifestPath = Join-Path $TempRoot 'manifest.json'
$Staging = Join-Path $TempRoot 'staging'

$ExistingCurrentPath = Join-Path $InstallRoot 'current.json'
if (Test-Path -LiteralPath $ExistingCurrentPath -PathType Leaf) {
    $existing = Get-Content -LiteralPath $ExistingCurrentPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $existingExecutable = Join-Path $InstallRoot ([string]$existing.relative_path + '\bin\beschannels-ai.exe')
    if (Test-Path -LiteralPath $existingExecutable -PathType Leaf) {
        $oldReleaseBase = $env:BESCHANNELS_AI_RELEASE_BASE_URL
        try {
            $env:BESCHANNELS_AI_RELEASE_BASE_URL = $SignedChannelBase
            $update = & $existingExecutable update --channel $Channel --output json | ConvertFrom-Json
        } finally {
            $env:BESCHANNELS_AI_RELEASE_BASE_URL = $oldReleaseBase
        }
        if (-not $update.ok) {
            throw '致趣 AI 工作台更新检查失败，现有版本保持不变。'
        }
        @{
            ok = $true
            product_name = '致趣 AI 工作台'
            display_name = '致趣 AI 工作台·协作版'
            version = $update.data.version
            status = $update.data.status
            update_deferred = ($update.data.status -eq 'update_deferred')
        } | ConvertTo-Json -Compress
        return
    }
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Write-JsonAtomic([string]$Path, [object]$Value) {
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $json = $Value | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, $Utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Invoke-Download([string]$Url, [string]$Destination) {
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object Net.Http.HttpClient
    try {
        $bytes = $client.GetByteArrayAsync($Url).GetAwaiter().GetResult()
        [IO.File]::WriteAllBytes($Destination, $bytes)
    } finally {
        $client.Dispose()
    }
}

function Expand-SafeArchive([string]$ZipPath, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                throw '安装包包含越界路径。'
            }
            if ([string]::IsNullOrEmpty($entry.Name)) {
                [IO.Directory]::CreateDirectory($target) | Out-Null
            } else {
                [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            }
        }
    } finally {
        $archive.Dispose()
    }
}

function Test-ReleaseFiles([string]$Root, [object]$Manifest) {
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $expected = @{}
    foreach ($row in $Manifest.files) {
        $expected[[string]$row.path] = $row
    }
    $actual = Get-ChildItem -LiteralPath $Root -Recurse -File
    if ($actual.Count -ne $expected.Count) {
        throw '安装包文件集合与签名清单不一致。'
    }
    foreach ($file in $actual) {
        $fileFull = [IO.Path]::GetFullPath($file.FullName)
        if (-not $fileFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw '安装包文件路径越界。'
        }
        $relative = $fileFull.Substring($rootFull.Length + 1).Replace('\', '/')
        if (-not $expected.ContainsKey($relative)) {
            throw '安装包包含清单外文件。'
        }
        $row = $expected[$relative]
        if ($file.Length -ne [long]$row.size -or (Get-FileSha256 $file.FullName) -ne [string]$row.sha256) {
            throw '安装包文件哈希与清单不一致。'
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'bin\beschannels-ai.exe') -PathType Leaf)) {
        throw '安装包缺少运行程序。'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'skills\beschannels-ai-ops\SKILL.md') -PathType Leaf)) {
        throw '安装包缺少统一入口 Skill。'
    }
}

try {
    [IO.Directory]::CreateDirectory($TempRoot) | Out-Null
    Invoke-Download ($ArchiveUrl + '?sha=' + $ArchiveSha256) $ArchivePath
    Invoke-Download ($ManifestUrl + '?sha=' + $ArchiveSha256) $ManifestPath
    if ((Get-FileSha256 $ArchivePath) -ne $ArchiveSha256) {
        throw '安装包 SHA256 校验失败。'
    }
    if ((Get-FileSha256 $ManifestPath) -ne $ManifestSha256) {
        throw '发布清单 SHA256 校验失败。'
    }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$manifest.version -ne $Version -or [string]$manifest.archive_sha256 -ne $ArchiveSha256) {
        throw '发布清单与安装入口不匹配。'
    }
    Expand-SafeArchive $ArchivePath $Staging
    Test-ReleaseFiles $Staging $manifest

    $VersionsRoot = Join-Path $InstallRoot 'versions'
    $Target = Join-Path $VersionsRoot $Version
    [IO.Directory]::CreateDirectory($VersionsRoot) | Out-Null
    if (Test-Path -LiteralPath $Target) {
        Test-ReleaseFiles $Target $manifest
    } else {
        [IO.Directory]::Move($Staging, $Target)
    }

    [IO.Directory]::CreateDirectory($SkillRoot) | Out-Null
    $SkillTarget = Join-Path $SkillRoot 'beschannels-ai-ops'
    $SkillStaging = Join-Path $SkillRoot ('.beschannels-ai-ops-' + [guid]::NewGuid().ToString('N'))
    Copy-Item -LiteralPath (Join-Path $Target 'skills\beschannels-ai-ops') -Destination $SkillStaging -Recurse
    $SkillBackup = Join-Path $SkillRoot '.beschannels-ai-ops-previous'
    if (Test-Path -LiteralPath $SkillBackup) {
        Remove-Item -LiteralPath $SkillBackup -Recurse -Force
    }
    if (Test-Path -LiteralPath $SkillTarget) {
        [IO.Directory]::Move($SkillTarget, $SkillBackup)
    }
    [IO.Directory]::Move($SkillStaging, $SkillTarget)

    $CurrentPath = Join-Path $InstallRoot 'current.json'
    $previous = $null
    if (Test-Path -LiteralPath $CurrentPath -PathType Leaf) {
        $previous = (Get-Content -LiteralPath $CurrentPath -Raw -Encoding UTF8 | ConvertFrom-Json).version
    }
    $metadata = @{schema_version = 1; channel = $Channel; manifest = $manifest}
    Write-JsonAtomic (Join-Path $InstallRoot ('release-metadata\' + $Version + '.json')) $metadata
    $pointer = @{
        schema_version = 1
        version = $Version
        relative_path = ('versions/' + $Version)
        archive_sha256 = $ArchiveSha256
        previous_version = $previous
        channel = $Channel
    }
    Write-JsonAtomic $CurrentPath $pointer

    $Executable = Join-Path $Target 'bin\beschannels-ai.exe'
    $doctor = & $Executable doctor --output json | ConvertFrom-Json
    if (-not $doctor.ok) {
        throw '安装后 doctor 验证失败。'
    }
    $signedCheck = $null
    $oldReleaseBase = $env:BESCHANNELS_AI_RELEASE_BASE_URL
    try {
        $env:BESCHANNELS_AI_RELEASE_BASE_URL = $SignedChannelBase
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $signedCheck = & $Executable update --channel $Channel --output json | ConvertFrom-Json
            if ($signedCheck.ok) { break }
            Start-Sleep -Seconds (2 * $attempt)
        }
    } finally {
        $env:BESCHANNELS_AI_RELEASE_BASE_URL = $oldReleaseBase
    }
    if (-not $signedCheck.ok) {
        throw '安装包已落盘，但签名发布通道验证失败。'
    }
    @{
        ok = $true
        product_name = '致趣 AI 工作台'
        display_name = '致趣 AI 工作台·协作版'
        version = $Version
        status = switch ($Channel) {
            'canary' { 'canary_released'; break }
            'pilot' { 'pilot_released'; break }
            'stable' { 'stable_released'; break }
            default { 'candidate_not_released' }
        }
    } | ConvertTo-Json -Compress
} finally {
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force
    }
}
