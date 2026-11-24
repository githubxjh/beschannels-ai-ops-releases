[CmdletBinding()]
param(
    # Another agent's skill folder to fill as well, for an agent whose folder does not exist yet.
    # It is remembered, so every later update keeps it current. Same as BESCHANNELS_AI_EXTRA_SKILL_ROOTS (';' separated).
    [string[]]$ExtraSkillRoot,
    # Do not download anything: copy the skills of the version that is already installed into every agent folder.
    [switch]$SyncOnly
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Version = '0.1.0-candidate.40'
$Channel = 'pilot'
$ArchiveUrl = 'https://raw.githubusercontent.com/githubxjh/beschannels-ai-ops-releases/v0.1.0-candidate.40/releases/0.1.0-candidate.40/beschannels-ai-ops-0.1.0-candidate.40-windows-x64.zip'
$ArchiveSha256 = 'E2CB55EB50AFC81F64D2A42FE17848AA2205C72B4C84D422F3EE3DD688C06FD6'
$ManifestUrl = 'https://raw.githubusercontent.com/githubxjh/beschannels-ai-ops-releases/v0.1.0-candidate.40/releases/0.1.0-candidate.40/manifest.json'
$ManifestSha256 = '808289ED063410B8AFF310B9E3EDED1D858556097634312FA519BABED4987F97'
$SignedChannelBase = $ManifestUrl.Substring(0, $ManifestUrl.IndexOf('/releases/')) + '/channels'
$InstallRoot = if ($env:BESCHANNELS_AI_HOME) {
    [IO.Path]::GetFullPath($env:BESCHANNELS_AI_HOME)
} else {
    Join-Path $env:LOCALAPPDATA 'Programs\BesChannelsAIOps'
}
# The runtime finds the user's folder through USERPROFILE; use the same source so both agree.
$UserHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$SkillRoot = if ($env:BESCHANNELS_AI_SKILL_ROOT) {
    [IO.Path]::GetFullPath($env:BESCHANNELS_AI_SKILL_ROOT)
} else {
    Join-Path $UserHome '.codex\skills'
}
$ExtraSkillRoots = New-Object System.Collections.Generic.List[string]
foreach ($row in @($ExtraSkillRoot)) { if ($row) { $ExtraSkillRoots.Add($row) } }
if ($env:BESCHANNELS_AI_EXTRA_SKILL_ROOTS) {
    foreach ($row in ($env:BESCHANNELS_AI_EXTRA_SKILL_ROOTS -split ';')) { if ($row.Trim()) { $ExtraSkillRoots.Add($row.Trim()) } }
}
$SyncOnlyMode = $SyncOnly.IsPresent -or ($env:BESCHANNELS_AI_INSTALL_SYNC_ONLY -eq '1')
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('BesChannelsAIOps-' + [guid]::NewGuid().ToString('N'))
$ArchivePath = Join-Path $TempRoot 'release.zip'
$ManifestPath = Join-Path $TempRoot 'manifest.json'
$Staging = Join-Path $TempRoot 'staging'

# The "already installed" branch used to sit here. It now runs after the helper functions below,
# because it has to copy the skills into every agent folder and those helpers must exist first.

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

# ---- Agent skill folders -------------------------------------------------------------------
# Codex reads ~\.codex\skills, DeepSeek Harness reads ~\.agents\skills, Claude Code reads ~\.claude\skills.
# The installed runtime has to reach every one of them that exists, or an agent keeps working from an old copy.
# These helpers mirror src/beschannels_ai/paths.py and updater.py; the same folders, the same registry file.

function Get-DataRoot {
    if ($env:BESCHANNELS_AI_DATA_HOME) { return [IO.Path]::GetFullPath($env:BESCHANNELS_AI_DATA_HOME) }
    return (Join-Path $env:LOCALAPPDATA 'BesChannelsAIOps')
}

# Folders someone asked us to keep in sync (written by -ExtraSkillRoot here or by "sync-skills --add-root").
function Get-RegisteredSkillRoots {
    $registry = Join-Path (Get-DataRoot) 'skill-roots.json'
    if (-not (Test-Path -LiteralPath $registry -PathType Leaf)) { return }
    try {
        $payload = Get-Content -LiteralPath $registry -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($row in @($payload.extra_roots)) {
            if (($row -is [string]) -and $row.Trim()) { $row }
        }
    } catch { }
}

function Save-RegisteredSkillRoots([string[]]$Roots) {
    $wanted = @($Roots | Where-Object { $_ })
    if ($wanted.Count -eq 0) { return }
    $merged = New-Object System.Collections.Generic.List[string]
    foreach ($row in (@(Get-RegisteredSkillRoots) + $wanted)) {
        $full = [IO.Path]::GetFullPath([string]$row)
        if (-not ($merged | Where-Object { $_ -ieq $full })) { $merged.Add($full) }
    }
    Write-JsonAtomic (Join-Path (Get-DataRoot) 'skill-roots.json') @{ schema_version = 1; extra_roots = $merged.ToArray() }
}

# Where a folder really points, so a junction or link to the primary folder is not written twice.
function Get-RealPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if ($item.LinkType -and $item.Target) {
            $target = [string](@($item.Target)[0])
            if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path (Split-Path -Parent $full) $target }
            return [IO.Path]::GetFullPath($target).TrimEnd('\')
        }
    }
    return $full
}

# The primary folder first. Naming one folder with BESCHANNELS_AI_SKILL_ROOT means "only that folder" (the runtime
# does the same); otherwise every agent folder that exists on this machine plus the remembered ones.
function Get-SkillSyncRoots {
    $SkillRoot
    if (-not $env:BESCHANNELS_AI_SKILL_ROOT) {
        foreach ($relative in '.codex\skills', '.agents\skills', '.claude\skills') {
            $candidate = Join-Path $UserHome $relative
            if (Test-Path -LiteralPath $candidate -PathType Container) { [IO.Path]::GetFullPath($candidate) }
        }
        foreach ($row in @(Get-RegisteredSkillRoots)) { [IO.Path]::GetFullPath($row) }
    }
    foreach ($row in $ExtraSkillRoots) { [IO.Path]::GetFullPath($row) }
}

# Replace our two skill folders inside one skill root; put the old ones back if anything fails.
function Install-SkillsInto([string]$Root, [string]$VersionRoot) {
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    $managed = @('beschannels-ai-ops', 'beschannels-marketing-automation')
    $sources = @{}
    foreach ($dir in @(Get-ChildItem -LiteralPath (Join-Path $VersionRoot 'skills') -Directory)) { $sources[$dir.Name] = $dir.FullName }
    if (-not $sources.ContainsKey('beschannels-ai-ops')) { throw '安装包缺少统一入口 Skill。' }
    $names = @($managed) + @($sources.Keys | Where-Object { $managed -notcontains $_ })
    $suffix = [guid]::NewGuid().ToString('N')
    $staged = @{}
    $backups = @{}
    $activated = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($name in $sources.Keys) {
            $stage = Join-Path $Root ('.' + $name + '-' + $suffix)
            Copy-Item -LiteralPath $sources[$name] -Destination $stage -Recurse
            $staged[$name] = $stage
        }
        foreach ($name in $names) {
            $target = Join-Path $Root $name
            $backup = Join-Path $Root ('.' + $name + '-backup-' + $suffix)
            if (Test-Path -LiteralPath $target) {
                [IO.Directory]::Move($target, $backup)
                $backups[$name] = $backup
            }
            if ($staged.ContainsKey($name)) {
                [IO.Directory]::Move($staged[$name], $target)
                $activated.Add($name)
            }
        }
    } catch {
        foreach ($name in $activated) { Remove-Item -LiteralPath (Join-Path $Root $name) -Recurse -Force }
        foreach ($name in $backups.Keys) { [IO.Directory]::Move($backups[$name], (Join-Path $Root $name)) }
        throw
    } finally {
        foreach ($stage in $staged.Values) {
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        }
    }
    foreach ($backup in $backups.Values) { Remove-Item -LiteralPath $backup -Recurse -Force }
}

# One row per folder: path, role (primary or extra), status (synced or failed). The primary folder must succeed;
# another agent's folder that cannot be written is reported, and the install still goes on.
function Sync-AgentSkills([string]$VersionRoot) {
    $primaryReal = (Get-RealPath $SkillRoot).ToLowerInvariant()
    $seen = @{}
    foreach ($root in @(Get-SkillSyncRoots)) {
        $real = (Get-RealPath $root).ToLowerInvariant()
        if ($seen.ContainsKey($real)) { continue }
        $seen[$real] = $true
        $role = if ($real -eq $primaryReal) { 'primary' } else { 'extra' }
        try {
            Install-SkillsInto $root $VersionRoot
            @{ path = $root; role = $role; status = 'synced' }
        } catch {
            if ($role -eq 'primary') { throw }
            @{ path = $root; role = $role; status = 'failed'; reason = $_.Exception.GetType().Name }
        }
    }
}

# The version current.json points at, or $null when nothing usable is installed.
function Get-InstalledVersion {
    $pointerPath = Join-Path $InstallRoot 'current.json'
    if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) { return $null }
    $pointer = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $installFull = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\') + '\'
    $versionRoot = [IO.Path]::GetFullPath((Join-Path $InstallRoot ([string]$pointer.relative_path)))
    if (-not $versionRoot.StartsWith($installFull, [StringComparison]::OrdinalIgnoreCase)) { throw '当前版本指针越界。' }
    if (-not (Test-Path -LiteralPath (Join-Path $versionRoot 'skills\beschannels-ai-ops\SKILL.md') -PathType Leaf)) { return $null }
    return @{ Root = $versionRoot; Version = [string]$pointer.version }
}

# -SyncOnly: download nothing, copy the installed version's skills into every agent folder.
if ($SyncOnlyMode) {
    $Installed = Get-InstalledVersion
    if (-not $Installed) {
        throw '还没有安装致趣 AI 工作台。先运行完整安装命令；-SyncOnly 只同步已经装好的版本。'
    }
    Save-RegisteredSkillRoots $ExtraSkillRoots.ToArray()
    $SyncRows = @(Sync-AgentSkills $Installed.Root)
    @{
        ok = $true
        product_name = '致趣 AI 工作台'
        display_name = '致趣 AI 工作台·协作版'
        version = $Installed.Version
        status = 'skills_synced'
        update_deferred = $false
        skill_roots = $SyncRows
    } | ConvertTo-Json -Compress -Depth 6
    return
}

$ExistingCurrentPath = Join-Path $InstallRoot 'current.json'
if (Test-Path -LiteralPath $ExistingCurrentPath -PathType Leaf) {
    $existing = Get-Content -LiteralPath $ExistingCurrentPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $existingExecutable = Join-Path $InstallRoot ([string]$existing.relative_path + '\bin\beschannels-ai.exe')
    # Legacy runtimes cannot parse component manifests; migrate via the verified installer.
    $ExistingComponents = Join-Path $InstallRoot ([string]$existing.relative_path + '\components.json')
    if ((Test-Path -LiteralPath $existingExecutable -PathType Leaf) -and (Test-Path -LiteralPath $ExistingComponents -PathType Leaf)) {
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
        if ($update.data.status -ne 'update_deferred') {
            # The runtime that just ran can be an old one, and an old one only knows the single skill folder it was
            # built for. Copy the installed version's skills into every agent folder from here, where this can be fixed.
            $Installed = Get-InstalledVersion
            $UpdateRows = @()
            if ($Installed) {
                Save-RegisteredSkillRoots $ExtraSkillRoots.ToArray()
                $UpdateRows = @(Sync-AgentSkills $Installed.Root)
            }
            @{
                ok = $true
                product_name = '致趣 AI 工作台'
                display_name = '致趣 AI 工作台·协作版'
                version = $update.data.version
                status = $update.data.status
                update_deferred = $false
                skill_roots = $UpdateRows
            } | ConvertTo-Json -Compress -Depth 6
            return
        }
        # Older clients may defer because of a stale run; continue with the signed installer below.
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
        # The download temp directory and the configured install root may be on
        # different Windows volumes. Copy into a verified same-volume stage,
        # then keep the final directory switch atomic.
        $ActivationStage = Join-Path $VersionsRoot ('.activation-' + $Version + '-' + [guid]::NewGuid().ToString('N'))
        try {
            [IO.Directory]::CreateDirectory($ActivationStage) | Out-Null
            Get-ChildItem -LiteralPath $Staging -Force | Copy-Item -Destination $ActivationStage -Recurse -Force
            Test-ReleaseFiles $ActivationStage $manifest
            [IO.Directory]::Move($ActivationStage, $Target)
        } finally {
            if (Test-Path -LiteralPath $ActivationStage) {
                Remove-Item -LiteralPath $ActivationStage -Recurse -Force
            }
        }
    }

    # The skills go into every agent folder that exists (Codex, DeepSeek Harness, Claude Code) plus any named
    # with -ExtraSkillRoot. The primary folder must succeed; another folder that cannot be written is reported.
    Save-RegisteredSkillRoots $ExtraSkillRoots.ToArray()
    $SkillRows = @(Sync-AgentSkills $Target)

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
        skill_roots = $SkillRows
    } | ConvertTo-Json -Compress -Depth 6
} finally {
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force
    }
}
