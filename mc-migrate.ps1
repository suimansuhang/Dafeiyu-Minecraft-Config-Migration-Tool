#requires -Version 5.1
<#
.SYNOPSIS
    Minecraft 整合包实例配置迁移工具（无需安装任何依赖）

.DESCRIPTION
    整合包更新后，新实例里没有旧的按键设置、模组配置、存档、地图路径点。
    本工具把旧实例中的这些"个人数据"复制到新实例：只复制、只覆盖，绝不删除文件；
    覆盖前会自动打包备份，随时可以还原。

    支持两种启动方式：
      * 图形界面：双击 "启动迁移工具.bat"（推荐）
      * 命令行  ：.\mc-migrate.ps1 -Source 旧实例 -Target 新实例 -DryRun

.PARAMETER Source
    旧实例根目录（包含 options.txt / config / saves / mods 的那一层）

.PARAMETER Target
    新实例根目录

.PARAMETER Preset
    all（全部）、settings（设置+配置+服务器列表）、worlds（存档+地图）

.PARAMETER Include
    自定义类别 id，配合 -Preset custom 使用，如 settings,worlds

.PARAMETER Mode
    overwrite  覆盖新实例里的同名文件（默认，最接近"完整继承"）
    skip       新实例里已有的一律保留，只补充缺失的文件
    newer      旧文件比新文件修改时间更晚时才覆盖
    keybinds   只把旧 options.txt 里的 key_ 按键行合并进新 options.txt，其它设置保持新包原样

.PARAMETER NoBackup
    不创建备份（不建议）

.PARAMETER DryRun
    只扫描并打印计划，不写入任何文件

.PARAMETER Force
    跳过"看起来不像实例"的确认

.PARAMETER Restore
    从备份 zip 还原

.EXAMPLE
    .\mc-migrate.ps1 -Source "D:\MC\old" -Target "D:\MC\new" -DryRun

.EXAMPLE
    .\mc-migrate.ps1 -Source "D:\MC\old" -Target "D:\MC\new" -Mode keybinds

.EXAMPLE
    .\mc-migrate.ps1 -Restore "C:\Users\me\Documents\MC迁移备份\new-20261030-164500.zip"
#>
[CmdletBinding(DefaultParameterSetName = 'Gui')]
param(
    [Parameter(ParameterSetName = 'Gui')]
    [switch]$Gui,

    [Parameter(ParameterSetName = 'Gui')]
    [string]$Capture,

    [Parameter(Mandatory = $true, ParameterSetName = 'Cli')]
    [string]$Source,

    [Parameter(Mandatory = $true, ParameterSetName = 'Cli')]
    [string]$Target,

    [Parameter(ParameterSetName = 'Cli')]
    [ValidateSet('all', 'settings', 'worlds', 'custom')]
    [string]$Preset = 'all',

    [Parameter(ParameterSetName = 'Cli')]
    [string[]]$Include = @(),

    [Parameter(ParameterSetName = 'Cli')]
    [ValidateSet('overwrite', 'skip', 'newer', 'keybinds')]
    [string]$Mode = 'overwrite',

    [Parameter(ParameterSetName = 'Cli')]
    [switch]$NoBackup,

    [Parameter(ParameterSetName = 'Cli')]
    [string]$BackupRoot,

    [Parameter(ParameterSetName = 'Cli')]
    [switch]$DryRun,

    [Parameter(ParameterSetName = 'Cli')]
    [switch]$Force,

    [Parameter(Mandatory = $true, ParameterSetName = 'Restore')]
    [string]$Restore,

    [Parameter(ParameterSetName = 'Restore')]
    [string]$RestoreTo
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# ───────────────────────────── 全局状态 ─────────────────────────────

$script:ExcludedNames = @('session.lock', '.DS_Store', 'desktop.ini', 'Thumbs.db')
$script:LogLines = New-Object 'System.Collections.Generic.List[string]'
$script:UiLogSink = $null
$script:BackupRootDefault = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'MC迁移备份'
if ($env:MC_MIGRATE_BACKUP) { $script:BackupRootDefault = $env:MC_MIGRATE_BACKUP }

# ───────────────────────────── 日志 ─────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $script:LogLines.Add($line)
    if ($script:UiLogSink) {
        try { & $script:UiLogSink $line $Level } catch { }
        return
    }
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        'DIM'   { Write-Host $line -ForegroundColor DarkGray }
        default { Write-Host $line }
    }
}

# ───────────────────────────── 通用工具 ─────────────────────────────

function Resolve-FullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.Trim().Trim('"').Trim("'")
    if ($p.StartsWith('~')) { $p = $env:USERPROFILE + $p.Substring(1) }
    try { $full = [IO.Path]::GetFullPath($p) } catch { return $null }
    if ($full.Length -gt 3) { $full = $full.TrimEnd([char[]]('\', '/')) }
    return $full
}

function Test-ChildOf {
    param([string]$Parent, [string]$Child)
    $p = $Parent.TrimEnd([char[]]('\', '/')) + '\'
    return $Child.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)
}

function Get-InstanceInfo {
    param([string]$Path)
    $info = [pscustomobject]@{
        Path         = $Path
        Name         = (Split-Path -Leaf $Path)
        Exists       = $false
        IsInstance   = $false
        IsLauncher   = $false
        HasOptions   = $false
        HasConfig    = $false
        HasMods      = $false
        HasSaves     = $false
        HasVersions  = $false
        ModCount     = 0
        ConfigCount  = 0
    }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $info }
    $info.Exists = $true
    $info.HasOptions  = Test-Path -LiteralPath (Join-Path $Path 'options.txt') -PathType Leaf
    $info.HasConfig   = Test-Path -LiteralPath (Join-Path $Path 'config') -PathType Container
    $info.HasMods     = Test-Path -LiteralPath (Join-Path $Path 'mods') -PathType Container
    $info.HasSaves    = Test-Path -LiteralPath (Join-Path $Path 'saves') -PathType Container
    $info.HasVersions = Test-Path -LiteralPath (Join-Path $Path 'versions') -PathType Container

    if ($info.HasMods) {
        try { $info.ModCount = @(Get-ChildItem -LiteralPath (Join-Path $Path 'mods') -Filter *.jar -File -Force -ErrorAction SilentlyContinue).Count } catch { }
    }
    if ($info.HasConfig) {
        try { $info.ConfigCount = @(Get-ChildItem -LiteralPath (Join-Path $Path 'config') -File -Recurse -Force -ErrorAction SilentlyContinue).Count } catch { }
    }

    $hasGameData = $info.HasOptions -or $info.HasConfig -or $info.HasMods -or $info.HasSaves
    if (-not $hasGameData) {
        $extra = @('journeymap', 'xaero', 'XaeroWaypoints', 'XaeroWorldMap', 'resourcepacks', 'shaderpacks', 'servers.dat', 'saves')
        foreach ($e in $extra) {
            if (Test-Path -LiteralPath (Join-Path $Path $e)) { $hasGameData = $true; break }
        }
    }
    $info.IsInstance = $hasGameData
    $info.IsLauncher = ($info.HasVersions -and -not $hasGameData)
    return $info
}

# 在某个目录下寻找"真正的实例文件夹"（用于用户误选了启动器根目录的情况）
function Get-ChildInstances {
    param([string]$Path)
    $found = New-Object 'System.Collections.Generic.List[string]'
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $found }
    $subDirs = @()
    foreach ($sub in @('versions', 'instances', 'Instances', 'profiles')) {
        $p = Join-Path $Path $sub
        if (Test-Path -LiteralPath $p -PathType Container) {
            $subDirs += @(Get-ChildItem -LiteralPath $p -Directory -Force -ErrorAction SilentlyContinue)
        }
    }
    if ($subDirs.Count -eq 0) {
        $subDirs = @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue)
    }
    foreach ($d in $subDirs) {
        $i = Get-InstanceInfo -Path $d.FullName
        if ($i.IsInstance) { [void]$found.Add($d.FullName) }
    }
    return $found
}

# ───────────────────────────── 迁移类别 ─────────────────────────────

function Get-CategoryDefs {
    @(
        [pscustomobject]@{ Id = 'settings';    Name = '游戏设置与按键 (options.txt)'; Entries = @('options.txt', 'optionsof.txt', 'optionsshaders.txt'); Hint = '按键绑定、视角、语言、亮度等'; Default = $true }
        [pscustomobject]@{ Id = 'modconfig';   Name = '模组配置 (config 文件夹)';      Entries = @('config');                                             Hint = '各模组自己的设置文件';         Default = $false }
        [pscustomobject]@{ Id = 'worlds';      Name = '存档 (saves)';                  Entries = @('saves');                                              Hint = '单人世界，含 level.dat';       Default = $true }
        [pscustomobject]@{ Id = 'maps';        Name = '地图与小地图路径点';            Entries = @('journeymap', 'xaero', 'XaeroWaypoints', 'XaeroWorldMap', 'mapwriter', 'voxelmap', 'mcmap'); Hint = 'JourneyMap / Xaero 等'; Default = $true }
        [pscustomobject]@{ Id = 'packs';       Name = '资源包 (resourcepacks)';        Entries = @('resourcepacks');                                      Hint = '';                            Default = $false }
        [pscustomobject]@{ Id = 'shaders';     Name = '光影包 (shaderpacks)';          Entries = @('shaderpacks');                                        Hint = '';                            Default = $false }
        [pscustomobject]@{ Id = 'servers';     Name = '服务器列表 (servers.dat)';      Entries = @('servers.dat', 'servers.dat_old');                     Hint = '';                            Default = $true }
        [pscustomobject]@{ Id = 'screenshots'; Name = '截图 (screenshots)';            Entries = @('screenshots');                                        Hint = '';                            Default = $false }
        [pscustomobject]@{ Id = 'schematics';  Name = '投影/蓝图 (schematics)';        Entries = @('schematics');                                         Hint = 'Create/投影模组的结构文件';   Default = $false }
        [pscustomobject]@{ Id = 'mods';        Name = '模组文件 (mods)';               Entries = @('mods');                                               Hint = '不建议：新旧版本混用容易崩溃'; Default = $false }
    )
}

function Get-CategoryIdsForPreset {
    param([string]$PresetName)
    switch ($PresetName) {
        'settings' { return @('settings', 'modconfig', 'servers') }
        'worlds'   { return @('worlds', 'maps') }
        'all'      { return @('settings', 'modconfig', 'worlds', 'maps', 'packs', 'shaders', 'servers', 'screenshots', 'schematics') }
        default    { return @('settings', 'modconfig', 'worlds', 'maps', 'packs', 'shaders', 'servers') }
    }
}

function Get-DefaultCategoryIds {
    @((Get-CategoryDefs) | Where-Object { $_.Default } | ForEach-Object { $_.Id })
}

# ───────────────────────────── 迁移计划 ─────────────────────────────

function Get-MigrationPlan {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string[]]$CategoryIds,
        [string]$Mode = 'overwrite'
    )
    $list = New-Object 'System.Collections.Generic.List[object]'
    $cats = Get-CategoryDefs

    foreach ($cat in $cats) {
        if ($CategoryIds -notcontains $cat.Id) { continue }
        foreach ($entry in $cat.Entries) {
            $pattern = Join-Path $SourceRoot $entry
            $nodes = @()
            if ($entry -match '[\*\?\[]') { $nodes = @(Get-Item -Path $pattern -Force -ErrorAction SilentlyContinue) }
            else { $nodes = @(Get-Item -LiteralPath $pattern -Force -ErrorAction SilentlyContinue) }

            foreach ($node in $nodes) {
                $files = @()
                if ($node.PSIsContainer) {
                    $files = @(Get-ChildItem -LiteralPath $node.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)
                } else {
                    $files = @($node)
                }
                foreach ($file in $files) {
                    if ($script:ExcludedNames -contains $file.Name) { continue }
                    if ($file.FullName.Length -le $SourceRoot.Length) { continue }
                    $rel = $file.FullName.Substring($SourceRoot.Length).TrimStart([char[]]('\', '/'))
                    $tgt = Join-Path $TargetRoot $rel
                    $action = 'copy'
                    $reason = '新实例中不存在'

                    if (Test-Path -LiteralPath $tgt -PathType Leaf) {
                        $tgtItem = Get-Item -LiteralPath $tgt -Force
                        switch ($Mode) {
                            'skip' {
                                $action = 'skip'; $reason = '新实例中已存在（保留新文件）'
                            }
                            'newer' {
                                if ($file.LastWriteTimeUtc -gt $tgtItem.LastWriteTimeUtc) { $action = 'overwrite'; $reason = '旧文件的时间更新' }
                                else { $action = 'skip'; $reason = '新实例中的文件不比旧文件旧' }
                            }
                            'keybinds' {
                                if ($rel -eq 'options.txt') { $action = 'merge'; $reason = '把旧按键绑定合并进新 options.txt' }
                                else { $action = 'skip'; $reason = '按键合并模式只处理 options.txt' }
                            }
                            default {
                                $action = 'overwrite'; $reason = '覆盖新实例中的同名文件'
                            }
                        }
                        if ($action -eq 'overwrite' -and $file.Length -eq $tgtItem.Length -and $file.LastWriteTimeUtc -eq $tgtItem.LastWriteTimeUtc) {
                            $action = 'same'; $reason = '新旧文件完全相同，跳过'
                        }
                    }

                    $list.Add([pscustomobject]@{
                        Category   = $cat.Name
                        CategoryId = $cat.Id
                        Relative   = $rel
                        Source     = $file.FullName
                        Target     = $tgt
                        Size       = $file.Length
                        Time       = $file.LastWriteTime
                        Action     = $action
                        Reason     = $reason
                    })
                }
            }
        }
    }
    return $list
}

function Get-PlanSummary {
    param($Items)
    $arr = @($Items)
    $copy = @($arr | Where-Object { $_.Action -eq 'copy' }).Count
    $over = @($arr | Where-Object { $_.Action -eq 'overwrite' }).Count
    $merge = @($arr | Where-Object { $_.Action -eq 'merge' }).Count
    $skip = @($arr | Where-Object { $_.Action -eq 'skip' }).Count
    $same = @($arr | Where-Object { $_.Action -eq 'same' }).Count
    $bytes = 0
    foreach ($i in $arr) { if ($i.Action -in @('copy', 'overwrite', 'merge')) { $bytes += $i.Size } }
    [pscustomobject]@{
        Total = $arr.Count; Copy = $copy; Overwrite = $over; Merge = $merge
        Skip = $skip; Same = $same; Bytes = $bytes
    }
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [int]$Bytes)
}

# ───────────────────────────── 备份 / 还原 ─────────────────────────────

function New-Backup {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)]$Files,
        [hashtable]$Meta = @{}
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $dir = Split-Path -Parent $ZipPath
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }

    $zip = [IO.Compression.ZipFile]::Open($ZipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in $Files) {
            if (-not (Test-Path -LiteralPath $f.Target -PathType Leaf)) { continue }
            $rel = ($f.Relative -replace '\\', '/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.Target, ('files/' + $rel), [IO.Compression.CompressionLevel]::Optimal)
        }
        $json = ($Meta | ConvertTo-Json -Depth 6)
        $entry = $zip.CreateEntry('manifest.json')
        $writer = New-Object IO.StreamWriter($entry.Open(), (New-Object Text.UTF8Encoding($false)))
        try { $writer.Write($json) } finally { $writer.Dispose() }
    } finally {
        $zip.Dispose()
    }
}

function Restore-Backup {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [string]$TargetRoot
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { throw "找不到备份文件：$ZipPath" }

    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $manifest = $null
        foreach ($e in $zip.Entries) {
            if ($e.FullName -eq 'manifest.json') {
                $reader = New-Object IO.StreamReader($e.Open())
                try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            }
        }
        if (-not $TargetRoot) {
            $TargetRoot = Resolve-FullPath ([string]$manifest.target)
        }
        if (-not $TargetRoot) { throw '备份里没有记录目标实例，请用 -RestoreTo 指定要还原到哪个实例。' }
        if (-not (Test-Path -LiteralPath $TargetRoot -PathType Container)) { throw "目标实例不存在：$TargetRoot" }

        Write-Log "开始还原：$ZipPath" 'INFO'
        Write-Log "还原到：$TargetRoot" 'INFO'
        $count = 0
        foreach ($e in $zip.Entries) {
            if (-not $e.FullName.StartsWith('files/')) { continue }
            $rel = $e.FullName.Substring(6) -replace '/', '\'
            $dest = Join-Path $TargetRoot $rel
            $destDir = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $destDir)) { [void](New-Item -ItemType Directory -Path $destDir -Force) }
            [void][IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
            $count++
        }
        Write-Log "还原完成，共恢复 $count 个文件。" 'OK'
        return $count
    } finally {
        $zip.Dispose()
    }
}

# ───────────────────────────── 按键合并 ─────────────────────────────

function Merge-Keybinds {
    param([string]$SourceFile, [string]$TargetFile)
    $srcLines = [IO.File]::ReadAllLines($SourceFile)
    $tgtLines = [IO.File]::ReadAllLines($TargetFile)

    $kv = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $order = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $srcLines) {
        if ($line -match '^(key_[^:]*):(.*)$') {
            $k = $matches[1]; $v = $matches[2]
            if (-not $kv.ContainsKey($k)) { $order.Add($k) }
            $kv[$k] = $v
        }
    }
    if ($kv.Count -eq 0) { return 0 }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $out = New-Object 'System.Collections.Generic.List[string]'
    $changed = 0
    foreach ($line in $tgtLines) {
        $replaced = $false
        if ($line -match '^(key_[^:]*):(.*)$') {
            $k = $matches[1]
            if ($kv.ContainsKey($k)) {
                $newLine = $k + ':' + $kv[$k]
                if ($newLine -ne $line) { $changed++ }
                $out.Add($newLine)
                [void]$seen.Add($k)
                $replaced = $true
            }
        }
        if (-not $replaced) { $out.Add($line) }
    }
    foreach ($k in $order) {
        if (-not $seen.Contains($k)) {
            $out.Add($k + ':' + $kv[$k])
            $changed++
        }
    }

    [IO.File]::WriteAllLines($TargetFile, $out.ToArray(), (New-Object Text.UTF8Encoding($false)))
    return $changed
}

# ───────────────────────────── 执行迁移 ─────────────────────────────

function Invoke-Migration {
    param(
        [Parameter(Mandatory = $true)]$Items,
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [bool]$DoBackup = $true,
        [string]$BackupRoot = $script:BackupRootDefault,
        [scriptblock]$Progress = $null
    )
    $arr = @($Items)
    $todo = @($arr | Where-Object { $_.Action -in @('copy', 'overwrite', 'merge') })
    $needBackup = @($arr | Where-Object { $_.Action -in @('overwrite', 'merge') })

    $zipPath = $null
    if ($DoBackup -and $needBackup.Count -gt 0) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $safeName = (Split-Path -Leaf $TargetRoot) -replace '[\\/:*?"<>|]', '_'
        $zipPath = Join-Path $BackupRoot ("{0}-{1}.zip" -f $safeName, $stamp)
        Write-Log "正在备份将被覆盖的 $($needBackup.Count) 个文件..." 'INFO'
        try {
            New-Backup -ZipPath $zipPath -Files $needBackup -Meta @{
                time    = (Get-Date).ToString('s')
                target  = $TargetRoot
                count   = $needBackup.Count
                files   = @($needBackup | ForEach-Object { $_.Relative })
                version = '1.0'
            }
        } catch {
            throw ("备份失败（{0}）。请确认备份文件夹可以写入，或关闭占用它的网盘/同步软件；`n也可以取消勾选【备份】后重试（不建议），或改用 -BackupRoot 指定别的备份位置。" -f $_.Exception.Message)
        }
        Write-Log "备份已保存：$zipPath" 'OK'
    }

    $done = 0
    $ok = 0
    $fail = 0
    $mergedKeys = 0
    $total = $todo.Count

    foreach ($item in $todo) {
        try {
            $destDir = Split-Path -Parent $item.Target
            if (-not (Test-Path -LiteralPath $destDir)) { [void](New-Item -ItemType Directory -Path $destDir -Force) }

            switch ($item.Action) {
                'merge' {
                    $mergedKeys += (Merge-Keybinds -SourceFile $item.Source -TargetFile $item.Target)
                }
                default {
                    Copy-Item -LiteralPath $item.Source -Destination $item.Target -Force
                }
            }
            $ok++
        } catch {
            $fail++
            Write-Log "复制失败：$($item.Relative) —— $($_.Exception.Message)" 'ERROR'
        }

        $done++
        if ($Progress) {
            try { & $Progress $done $total $item } catch { }
        }
    }

    if ($zipPath) { Write-Log "备份：$zipPath" 'DIM' }
    return [pscustomobject]@{
        Total = $total; Success = $ok; Failed = $fail; MergedKeys = $mergedKeys; Backup = $zipPath
    }
}

function Save-LogFile {
    param([string]$Directory, [string]$Prefix = 'migrate')
    try {
        if (-not (Test-Path -LiteralPath $Directory)) { [void](New-Item -ItemType Directory -Path $Directory -Force) }
        $file = Join-Path $Directory ('{0}-{1}.log' -f $Prefix, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        [IO.File]::WriteAllLines($file, $script:LogLines.ToArray(), (New-Object Text.UTF8Encoding($false)))
        return $file
    } catch { return $null }
}

# ───────────────────────────── 实例检测（GUI 用） ─────────────────────────────

function Get-DetectedInstances {
    $found = New-Object 'System.Collections.Generic.List[string]'
    $candidates = New-Object 'System.Collections.Generic.List[string]'

    $bases = @(
        (Join-Path $env:APPDATA '.minecraft'),
        (Join-Path $env:USERPROFILE 'curseforge\minecraft\Instances'),
        (Join-Path $env:APPDATA 'PrismLauncher\instances'),
        (Join-Path $env:APPDATA 'ModrinthApp\profiles'),
        (Join-Path $env:APPDATA 'MultiMC\instances'),
        (Join-Path $env:APPDATA 'ATLauncher\instances')
    )
    foreach ($b in $bases) { if (Test-Path -LiteralPath $b -PathType Container) { $candidates.Add($b) } }

    foreach ($c in $candidates) {
        $info = Get-InstanceInfo -Path $c
        if ($info.IsInstance) { if (-not $found.Contains($c)) { $found.Add($c) } }
        $kids = @()
        if ($c -like '*\.minecraft') { $kids = @(Get-ChildItem -LiteralPath (Join-Path $c 'versions') -Directory -Force -ErrorAction SilentlyContinue) }
        else { $kids = @(Get-ChildItem -LiteralPath $c -Directory -Force -ErrorAction SilentlyContinue) }
        foreach ($k in $kids) {
            $ki = Get-InstanceInfo -Path $k.FullName
            if ($ki.IsInstance -and -not $found.Contains($k.FullName)) { $found.Add($k.FullName) }
        }
    }
    return $found
}

# ───────────────────────────── 图形界面 ─────────────────────────────

function Show-InstancePicker {
    param([string]$Parent, $Candidates)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $f = New-Object Windows.Forms.Form
    $f.Text = '选择实例文件夹'
    $f.ClientSize = New-Object Drawing.Size(560, 360)
    $f.StartPosition = 'CenterParent'
    $f.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

    $lbl = New-Object Windows.Forms.Label
    $lbl.Text = "所选文件夹不是单个实例，但里面找到了这些实例，请选择一个："
    $lbl.AutoSize = $false
    $lbl.Location = New-Object Drawing.Point(12, 10)
    $lbl.Size = New-Object Drawing.Size(536, 40)
    $f.Controls.Add($lbl)

    $list = New-Object Windows.Forms.ListBox
    $list.Location = New-Object Drawing.Point(12, 52)
    $list.Size = New-Object Drawing.Size(536, 250)
    foreach ($c in $Candidates) { [void]$list.Items.Add($c) }
    if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
    $f.Controls.Add($list)

    $ok = New-Object Windows.Forms.Button
    $ok.Text = '确定'
    $ok.Location = New-Object Drawing.Point(372, 314)
    $ok.Size = New-Object Drawing.Size(84, 30)
    $ok.DialogResult = 'OK'
    $f.Controls.Add($ok)

    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.Location = New-Object Drawing.Point(464, 314)
    $cancel.Size = New-Object Drawing.Size(84, 30)
    $cancel.DialogResult = 'Cancel'
    $f.Controls.Add($cancel)
    $f.AcceptButton = $ok
    $f.CancelButton = $cancel

    if ($f.ShowDialog() -eq 'OK' -and $list.SelectedItem) { return [string]$list.SelectedItem }
    return $null
}

# ───────────────────────────── 拖放 / 选择实例 ─────────────────────────────

function Resolve-DropFolder {
    param([string]$Path)
    if (-not $Path) { return $null }
    if ($Path -like '*.lnk') {
        try {
            $ws = New-Object -ComObject WScript.Shell
            return $ws.CreateShortcut($Path).TargetPath
        } catch { }
    }
    return $Path
}

function Set-InstanceField {
    param($Box, [string]$Path)
    if (-not $Path) { return }
    $Path = Resolve-DropFolder $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Add-UiLog ("这不是文件夹：$Path") 'WARN'
        return
    }
    $info = Get-InstanceInfo -Path $Path
    if (-not $info.IsInstance) {
        $kids = @(Get-ChildInstances -Path $Path)
        if ($kids.Count -eq 1) {
            $Path = $kids[0]
        } elseif ($kids.Count -gt 1) {
            $sel = Show-InstancePicker -Parent $Path -Candidates $kids
            if (-not $sel) { return }
            $Path = $sel
        } else {
            [Windows.Forms.MessageBox]::Show("这个文件夹不像整合包实例：`n$Path`n`n请拖入包含 options.txt / config / mods / saves 的那一层文件夹。", '不是实例文件夹', 'OK', 'Warning') | Out-Null
            return
        }
    }
    $Box.Text = $Path
    Add-UiLog ('已选择：' + $Path)
}

function Receive-InstanceDrop {
    param($TargetControl, $DragEvent)
    $raw = @($DragEvent.Data.GetData([Windows.Forms.DataFormats]::FileDrop))
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in $raw) {
        $rp = Resolve-DropFolder ([string]$p)
        if ($rp -and (Test-Path -LiteralPath $rp -PathType Container)) { $dirs.Add($rp) }
    }
    if ($dirs.Count -eq 0) {
        Add-UiLog '拖进来的不是文件夹，请拖入整合包实例文件夹。' 'WARN'
        return
    }
    if ($dirs.Count -ge 2) {
        Set-InstanceField -Box $script:UiState.Source -Path $dirs[0]
        Set-InstanceField -Box $script:UiState.Target -Path $dirs[1]
        return
    }

    $pt = $TargetControl.PointToScreen((New-Object Drawing.Point([int]$DragEvent.X, [int]$DragEvent.Y)))
    $srcRect = $script:UiState.Source.RectangleToScreen($script:UiState.Source.ClientRectangle)
    $dstRect = $script:UiState.Target.RectangleToScreen($script:UiState.Target.ClientRectangle)
    if ($srcRect.Contains($pt)) {
        Set-InstanceField -Box $script:UiState.Source -Path $dirs[0]
    } elseif ($dstRect.Contains($pt)) {
        Set-InstanceField -Box $script:UiState.Target -Path $dirs[0]
    } elseif ([string]::IsNullOrWhiteSpace($script:UiState.Source.Text)) {
        Set-InstanceField -Box $script:UiState.Source -Path $dirs[0]
    } else {
        Set-InstanceField -Box $script:UiState.Target -Path $dirs[0]
    }
}

function Set-DropHighlight {
    param($Control, [int]$X, [int]$Y)
    $pt = $Control.PointToScreen((New-Object Drawing.Point($X, $Y)))
    $hot = [Drawing.Color]::FromArgb(255, 250, 205)
    $white = [Drawing.Color]::White
    $srcRect = $script:UiState.Source.RectangleToScreen($script:UiState.Source.ClientRectangle)
    $dstRect = $script:UiState.Target.RectangleToScreen($script:UiState.Target.ClientRectangle)
    if ($script:UiState.PhSource) { $script:UiState.PhSource.Visible = $false }
    if ($script:UiState.PhTarget) { $script:UiState.PhTarget.Visible = $false }
    if ($srcRect.Contains($pt)) { $script:UiState.Source.BackColor = $hot } else { $script:UiState.Source.BackColor = $white }
    if ($dstRect.Contains($pt)) { $script:UiState.Target.BackColor = $hot } else { $script:UiState.Target.BackColor = $white }
}

function Clear-DropHighlight {
    $script:UiState.Source.BackColor = [Drawing.Color]::White
    $script:UiState.Target.BackColor = [Drawing.Color]::White
    if ($script:UiState.PhSource) {
        $script:UiState.PhSource.Visible = [string]::IsNullOrWhiteSpace($script:UiState.Source.Text)
    }
    if ($script:UiState.PhTarget) {
        $script:UiState.PhTarget.Visible = [string]::IsNullOrWhiteSpace($script:UiState.Target.Text)
    }
}

function Register-DropTargets {
    param($Form)
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Form)
    while ($queue.Count -gt 0) {
        $c = $queue.Dequeue()
        try {
            $c.AllowDrop = $true
            $c.Add_DragEnter({
                param($s, $e)
                if ($e.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
                    $e.Effect = [Windows.Forms.DragDropEffects]::Copy
                    Set-DropHighlight -Control $s -X ([int]$e.X) -Y ([int]$e.Y)
                }
            })
            $c.Add_DragLeave({
                param($s, $e)
                Clear-DropHighlight
            })
            $c.Add_DragDrop({
                param($s, $e)
                Receive-InstanceDrop -TargetControl $s -DragEvent $e
                Clear-DropHighlight
            })
        } catch { }
        foreach ($child in $c.Controls) { $queue.Enqueue($child) }
    }
}

function Show-InstanceMenu {
    param($Box, $MenuButton)
    $items = @()
    if ($script:DetectedInstances) { $items = @($script:DetectedInstances) }
    if ($items.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show("没有自动找到整合包实例。`n请用【浏览...】选择，或直接把实例文件夹拖进输入框。", '没有可选项', 'OK', 'Information') | Out-Null
        return
    }
    $menu = New-Object Windows.Forms.ContextMenuStrip
    $menu.Tag = $Box
    foreach ($p in $items) {
        $mi = $menu.Items.Add((Split-Path -Leaf $p) + '    ' + $p)
        $mi.Tag = $p
    }
    $menu.Add_ItemClicked({ param($s, $e) Set-InstanceField -Box $s.Tag -Path ([string]$e.ClickedItem.Tag) })
    $menu.Show($MenuButton, (New-Object Drawing.Point(0, $MenuButton.Height)))
}

function Start-Gui {
    param([string]$CapturePath = $null)

    $script:CapturePath = $CapturePath

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object Windows.Forms.Form
    $form.Text = '大肥鱼MC迁移工具 v1.1'
    $form.ClientSize = New-Object Drawing.Size(806, 772)
    $form.MinimumSize = New-Object Drawing.Size(820, 810)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

    # 窗口/任务栏图标（ico 与脚本放在同一目录）
    if ($PSScriptRoot) {
        $icoPath = Join-Path $PSScriptRoot '大肥鱼MC迁移工具.ico'
        if (Test-Path -LiteralPath $icoPath) {
            try { $form.Icon = New-Object System.Drawing.Icon($icoPath) } catch { }
        }
    }

    # ── 实例路径 ──
    $lblSrc = New-Object Windows.Forms.Label
    $lblSrc.Text = '旧实例（要继承的配置从这里来）'
    $lblSrc.Location = New-Object Drawing.Point(14, 6)
    $lblSrc.Size = New-Object Drawing.Size(600, 18)
    $form.Controls.Add($lblSrc)

    $txtSrc = New-Object Windows.Forms.TextBox
    $txtSrc.Multiline = $true
    $txtSrc.AcceptsReturn = $false
    $txtSrc.Location = New-Object Drawing.Point(14, 24)
    $txtSrc.Size = New-Object Drawing.Size(640, 52)
    $txtSrc.Anchor = 'Top,Left,Right'
    $form.Controls.Add($txtSrc)

    # 输入框为空时显示浅灰提示（不写入 Text，不影响实际内容）
    $phSrc = New-Object Windows.Forms.Label
    $phSrc.Text = '把旧实例文件夹拖到这里，或点右边「浏览」选择'
    $phSrc.ForeColor = [Drawing.Color]::FromArgb(160, 160, 160)
    $phSrc.BackColor = [Drawing.Color]::White
    $phSrc.Location = New-Object Drawing.Point(19, 28)
    $phSrc.Size = New-Object Drawing.Size(630, 20)
    $phSrc.Anchor = 'Top,Left,Right'
    $phSrc.Cursor = [Windows.Forms.Cursors]::IBeam
    $form.Controls.Add($phSrc)
    $phSrc.BringToFront()

    $btnSrcList = New-Object Windows.Forms.Button
    $btnSrcList.Text = '▼'
    $btnSrcList.Font = New-Object Drawing.Font('Microsoft YaHei UI', 7)
    $btnSrcList.Location = New-Object Drawing.Point(658, 36)
    $btnSrcList.Size = New-Object Drawing.Size(26, 27)
    $btnSrcList.Anchor = 'Top,Right'
    $form.Controls.Add($btnSrcList)

    $btnSrc = New-Object Windows.Forms.Button
    $btnSrc.Text = '浏览...'
    $btnSrc.Location = New-Object Drawing.Point(690, 36)
    $btnSrc.Size = New-Object Drawing.Size(100, 27)
    $btnSrc.Anchor = 'Top,Right'
    $form.Controls.Add($btnSrc)

    $lblDst = New-Object Windows.Forms.Label
    $lblDst.Text = '新实例（刚下载、要迁移进去的）'
    $lblDst.Location = New-Object Drawing.Point(14, 86)
    $lblDst.Size = New-Object Drawing.Size(600, 18)
    $form.Controls.Add($lblDst)

    $txtDst = New-Object Windows.Forms.TextBox
    $txtDst.Multiline = $true
    $txtDst.AcceptsReturn = $false
    $txtDst.Location = New-Object Drawing.Point(14, 104)
    $txtDst.Size = New-Object Drawing.Size(640, 52)
    $txtDst.Anchor = 'Top,Left,Right'
    $form.Controls.Add($txtDst)

    $phDst = New-Object Windows.Forms.Label
    $phDst.Text = '把新实例文件夹拖到这里，或点右边「浏览」选择'
    $phDst.ForeColor = [Drawing.Color]::FromArgb(160, 160, 160)
    $phDst.BackColor = [Drawing.Color]::White
    $phDst.Location = New-Object Drawing.Point(19, 108)
    $phDst.Size = New-Object Drawing.Size(630, 20)
    $phDst.Anchor = 'Top,Left,Right'
    $phDst.Cursor = [Windows.Forms.Cursors]::IBeam
    $form.Controls.Add($phDst)
    $phDst.BringToFront()

    # 占位提示：输入框为空时显示，有内容就隐藏
    $txtSrc.Add_TextChanged({ $phSrc.Visible = [string]::IsNullOrWhiteSpace($txtSrc.Text) })
    $phSrc.Add_Click({ $txtSrc.Focus() })
    $txtDst.Add_TextChanged({ $phDst.Visible = [string]::IsNullOrWhiteSpace($txtDst.Text) })
    $phDst.Add_Click({ $txtDst.Focus() })

    $btnDstList = New-Object Windows.Forms.Button
    $btnDstList.Text = '▼'
    $btnDstList.Font = New-Object Drawing.Font('Microsoft YaHei UI', 7)
    $btnDstList.Location = New-Object Drawing.Point(658, 116)
    $btnDstList.Size = New-Object Drawing.Size(26, 27)
    $btnDstList.Anchor = 'Top,Right'
    $form.Controls.Add($btnDstList)

    $btnDst = New-Object Windows.Forms.Button
    $btnDst.Text = '浏览...'
    $btnDst.Location = New-Object Drawing.Point(690, 116)
    $btnDst.Size = New-Object Drawing.Size(100, 27)
    $btnDst.Anchor = 'Top,Right'
    $form.Controls.Add($btnDst)

    $hint = New-Object Windows.Forms.Label
    $hint.Text = '提示：可以直接把文件夹拖进上面的输入框（拖到哪一栏就填哪一栏）；要选包含 options.txt / config / mods / saves 的那一层。'
    $hint.Location = New-Object Drawing.Point(14, 164)
    $hint.Size = New-Object Drawing.Size(776, 18)
    $hint.ForeColor = [Drawing.Color]::DimGray
    $form.Controls.Add($hint)

    # ── 类别 ──
    $grpCat = New-Object Windows.Forms.GroupBox
    $grpCat.Text = '要迁移的内容'
    $grpCat.Location = New-Object Drawing.Point(14, 188)
    $grpCat.Size = New-Object Drawing.Size(470, 252)
    $form.Controls.Add($grpCat)

    $clb = New-Object Windows.Forms.CheckedListBox
    $clb.Location = New-Object Drawing.Point(10, 22)
    $clb.Size = New-Object Drawing.Size(448, 218)
    $clb.CheckOnClick = $true
    $clb.Anchor = 'Top,Left,Right'
    $grpCat.Controls.Add($clb)

    $cats = @(Get-CategoryDefs)
    $script:UiStateCatIds = @()
    for ($i = 0; $i -lt $cats.Count; $i++) {
        $c = $cats[$i]
        $label = $c.Name
        if ($c.Hint) { $label = $label + '  —— ' + $c.Hint }
        [void]$clb.Items.Add($label)
        $script:UiStateCatIds += $c.Id
        if ($c.Default) { $clb.SetItemChecked($i, $true) }
    }

    # ── 冲突处理 ──
    $grpMode = New-Object Windows.Forms.GroupBox
    $grpMode.Text = '冲突处理方式'
    $grpMode.Location = New-Object Drawing.Point(494, 188)
    $grpMode.Size = New-Object Drawing.Size(296, 252)
    $form.Controls.Add($grpMode)

    $rbOver = New-Object Windows.Forms.RadioButton
    $rbOver.Text = '覆盖新实例中的同名文件'
    $rbOver.Location = New-Object Drawing.Point(12, 22)
    $rbOver.Size = New-Object Drawing.Size(272, 22)
    $rbOver.Checked = $true
    $grpMode.Controls.Add($rbOver)

    $rbSkip = New-Object Windows.Forms.RadioButton
    $rbSkip.Text = '保留新实例文件，只补缺失的'
    $rbSkip.Location = New-Object Drawing.Point(12, 48)
    $rbSkip.Size = New-Object Drawing.Size(272, 22)
    $grpMode.Controls.Add($rbSkip)

    $rbNewer = New-Object Windows.Forms.RadioButton
    $rbNewer.Text = '只在新文件更旧时覆盖'
    $rbNewer.Location = New-Object Drawing.Point(12, 74)
    $rbNewer.Size = New-Object Drawing.Size(272, 22)
    $grpMode.Controls.Add($rbNewer)

    $rbKeys = New-Object Windows.Forms.RadioButton
    $rbKeys.Text = '只合并按键（智能）'
    $rbKeys.Location = New-Object Drawing.Point(12, 100)
    $rbKeys.Size = New-Object Drawing.Size(272, 22)
    $grpMode.Controls.Add($rbKeys)

    $chkBackup = New-Object Windows.Forms.CheckBox
    $chkBackup.Text = '覆盖前自动备份（推荐）'
    $chkBackup.Location = New-Object Drawing.Point(12, 132)
    $chkBackup.Size = New-Object Drawing.Size(272, 22)
    $chkBackup.Checked = $true
    $grpMode.Controls.Add($chkBackup)

    $lblMode = New-Object Windows.Forms.Label
    $lblMode.Text = '按键合并：只把旧 options.txt 里 key_ 开头的行写进新文件，新包的其它设置保持不动。'
    $lblMode.Location = New-Object Drawing.Point(12, 158)
    $lblMode.Size = New-Object Drawing.Size(272, 48)
    $lblMode.ForeColor = [Drawing.Color]::DimGray
    $grpMode.Controls.Add($lblMode)

    # ── 按钮 ──
    $btnPreview = New-Object Windows.Forms.Button
    $btnPreview.Text = '扫描预览'
    $btnPreview.Location = New-Object Drawing.Point(14, 452)
    $btnPreview.Size = New-Object Drawing.Size(104, 32)
    $form.Controls.Add($btnPreview)

    $btnRun = New-Object Windows.Forms.Button
    $btnRun.Text = '开始迁移'
    $btnRun.Location = New-Object Drawing.Point(126, 452)
    $btnRun.Size = New-Object Drawing.Size(120, 32)
    $btnRun.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9, [Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnRun)

    $btnRestore = New-Object Windows.Forms.Button
    $btnRestore.Text = '还原备份...'
    $btnRestore.Location = New-Object Drawing.Point(254, 452)
    $btnRestore.Size = New-Object Drawing.Size(110, 32)
    $form.Controls.Add($btnRestore)

    $btnOpenBak = New-Object Windows.Forms.Button
    $btnOpenBak.Text = '打开备份文件夹'
    $btnOpenBak.Location = New-Object Drawing.Point(372, 452)
    $btnOpenBak.Size = New-Object Drawing.Size(130, 32)
    $form.Controls.Add($btnOpenBak)

    # ── 进度 & 日志 ──
    $bar = New-Object Windows.Forms.ProgressBar
    $bar.Location = New-Object Drawing.Point(14, 494)
    $bar.Size = New-Object Drawing.Size(776, 16)
    $bar.Anchor = 'Top,Left,Right'
    $bar.Minimum = 0
    $bar.Maximum = 100
    $form.Controls.Add($bar)

    $grpLog = New-Object Windows.Forms.GroupBox
    $grpLog.Text = '日志'
    $grpLog.Location = New-Object Drawing.Point(14, 518)
    $grpLog.Size = New-Object Drawing.Size(776, 234)
    $grpLog.Anchor = 'Top,Bottom,Left,Right'
    $form.Controls.Add($grpLog)

    $txtLog = New-Object Windows.Forms.TextBox
    $txtLog.Multiline = $true
    $txtLog.ReadOnly = $true
    $txtLog.ScrollBars = 'Vertical'
    $txtLog.WordWrap = $false
    $txtLog.Location = New-Object Drawing.Point(10, 20)
    $txtLog.Size = New-Object Drawing.Size(756, 202)
    $txtLog.Anchor = 'Top,Bottom,Left,Right'
    $txtLog.BackColor = [Drawing.Color]::FromArgb(250, 250, 250)
    $txtLog.Font = New-Object Drawing.Font('Consolas', 9)
    $grpLog.Controls.Add($txtLog)

    $script:UiState = @{
        Form     = $form
        Source   = $txtSrc
        Target   = $txtDst
        Clb      = $clb
        Progress = $bar
        Log      = $txtLog
        Backup   = $chkBackup
        ModeRb   = @{ overwrite = $rbOver; skip = $rbSkip; newer = $rbNewer; keybinds = $rbKeys }
        Buttons  = @($btnPreview, $btnRun, $btnRestore)
        PhSource = $phSrc
        PhTarget = $phDst
        LastBackup = $null
    }

    $script:UiLogSink = {
        param($line, $level)
        $box = $script:UiState.Log
        $box.AppendText($line + [Environment]::NewLine)
        $box.SelectionStart = $box.TextLength
        $box.ScrollToCaret()
        [Windows.Forms.Application]::DoEvents()
    }

    # 预扫描常见位置，供“▼”菜单使用
    try { $script:DetectedInstances = @(Get-DetectedInstances) } catch { $script:DetectedInstances = @() }

    # ── 事件 ──
    $browse = {
        param($box)
        $dlg = New-Object Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择整合包实例文件夹（包含 options.txt / config / mods 的那一层）'
        $dlg.ShowNewFolderButton = $false
        $cur = Resolve-FullPath $box.Text
        if ($cur -and (Test-Path -LiteralPath $cur)) { $dlg.SelectedPath = $cur }
        if ($dlg.ShowDialog() -ne 'OK') { return }
        Set-InstanceField -Box $box -Path $dlg.SelectedPath
    }

    $btnSrc.Add_Click({ & $browse $txtSrc })
    $btnDst.Add_Click({ & $browse $txtDst })
    $btnSrcList.Add_Click({ Show-InstanceMenu -Box $txtSrc -MenuButton $btnSrcList })
    $btnDstList.Add_Click({ Show-InstanceMenu -Box $txtDst -MenuButton $btnDstList })

    $btnOpenBak.Add_Click({
        try {
            if (-not (Test-Path -LiteralPath $script:BackupRootDefault)) { [void](New-Item -ItemType Directory -Path $script:BackupRootDefault -Force) }
            Start-Process explorer.exe $script:BackupRootDefault
        } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, '打不开', 'OK', 'Warning') | Out-Null }
    })

    $btnPreview.Add_Click({
        try { Invoke-UiPreview } catch {
            Add-UiLog ('错误：' + $_.Exception.Message) 'ERROR'
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, '扫描失败', 'OK', 'Error') | Out-Null
        }
    })

    $btnRun.Add_Click({
        try { Invoke-UiMigration } catch {
            Add-UiLog ('错误：' + $_.Exception.Message) 'ERROR'
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, '迁移失败', 'OK', 'Error') | Out-Null
        }
    })

    $btnRestore.Add_Click({ Invoke-UiRestore })

    # 让窗口里所有控件都能接收拖入的文件夹（按松手位置判断填到哪一栏）
    Register-DropTargets -Form $form

    $form.Add_Shown({
        Add-UiLog '把"旧实例"和"新实例"两个文件夹选好（也可以直接把文件夹拖进输入框），点"扫描预览"看看会复制哪些文件，再点"开始迁移"。'
        Add-UiLog '迁移前请先完全退出游戏，否则存档可能被占用。'
        if ($script:CapturePath) {
            $form.Refresh()
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 500
            [Windows.Forms.Application]::DoEvents()
            try {
                $bmp = New-Object Drawing.Bitmap([int]$form.Width, [int]$form.Height)
                $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)))
                $bmp.Save($script:CapturePath, [Drawing.Imaging.ImageFormat]::Png)
                $bmp.Dispose()
            } catch { }
            $form.Close()
        }
    })

    [void]$form.ShowDialog()
    $script:UiLogSink = $null
}

function Add-UiLog {
    param([string]$Text, [string]$Level = 'INFO')
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text
    $script:LogLines.Add($line)
    if ($script:UiLogSink) { & $script:UiLogSink $line $Level }
}

function Get-UiSelection {
    $src = Resolve-FullPath $script:UiState.Source.Text
    $dst = Resolve-FullPath $script:UiState.Target.Text
    if (-not $src) { throw '请先选择旧实例文件夹。' }
    if (-not $dst) { throw '请先选择新实例文件夹。' }
    if (-not (Test-Path -LiteralPath $src -PathType Container)) { throw "旧实例文件夹不存在：$src" }
    if (-not (Test-Path -LiteralPath $dst -PathType Container)) { throw "新实例文件夹不存在：$dst" }
    if ($src -eq $dst) { throw '旧实例和新实例是同一个文件夹，不需要迁移。' }
    if ((Test-ChildOf -Parent $src -Child $dst) -or (Test-ChildOf -Parent $dst -Child $src)) {
        throw '两个文件夹互相嵌套，无法安全迁移，请重新选择。'
    }

    $mode = 'overwrite'
    foreach ($k in @('overwrite', 'skip', 'newer', 'keybinds')) {
        if ($script:UiState.ModeRb[$k].Checked) { $mode = $k }
    }

    $ids = @()
    for ($i = 0; $i -lt $script:UiState.Clb.Items.Count; $i++) {
        if ($script:UiState.Clb.GetItemChecked($i)) { $ids += $script:UiStateCatIds[$i] }
    }
    if ($ids.Count -eq 0) { throw '请至少勾选一项要迁移的内容。' }

    [pscustomobject]@{ Source = $src; Target = $dst; Mode = $mode; CategoryIds = $ids }
}

function Invoke-UiPreview {
    $sel = Get-UiSelection
    Add-UiLog "扫描：$($sel.Source)  ->  $($sel.Target)" 'INFO'
    $plan = Get-MigrationPlan -SourceRoot $sel.Source -TargetRoot $sel.Target -CategoryIds $sel.CategoryIds -Mode $sel.Mode
    $sum = Get-PlanSummary -Items $plan

    Add-UiLog ("共 {0} 个文件：新增 {1}，覆盖 {2}，合并按键 {3}，跳过 {4}，相同 {5}，约 {6}" -f `
        $sum.Total, $sum.Copy, $sum.Overwrite, $sum.Merge, $sum.Skip, $sum.Same, (Format-Size $sum.Bytes)) 'OK'

    foreach ($cat in (Get-CategoryDefs)) {
        if ($sel.CategoryIds -notcontains $cat.Id) { continue }
        $sub = @($plan | Where-Object { $_.CategoryId -eq $cat.Id })
        if ($sub.Count -eq 0) { continue }
        $s = Get-PlanSummary -Items $sub
        Add-UiLog ("  · {0}：{1} 个文件，新增 {2} / 覆盖 {3} / 跳过 {4}" -f $cat.Name, $sub.Count, $s.Copy, $s.Overwrite, $s.Skip) 'DIM'
        foreach ($sample in @($sub | Select-Object -First 3)) { Add-UiLog ('      ' + $sample.Relative) 'DIM' }
    }

    # 模组数量差异提醒
    $si = Get-InstanceInfo -Path $sel.Source
    $ti = Get-InstanceInfo -Path $sel.Target
    if ($si.ModCount -gt 0 -and $ti.ModCount -gt 0 -and $si.ModCount -ne $ti.ModCount) {
        Add-UiLog ("注意：新旧实例模组数量不同（旧 {0} / 新 {1}），旧配置里可能有新包已移除模组的条目，一般不影响游戏。" -f $si.ModCount, $ti.ModCount) 'WARN'
    }
    $script:UiState.Progress.Value = 0
}

function Invoke-UiMigration {
    $sel = Get-UiSelection
    $plan = Get-MigrationPlan -SourceRoot $sel.Source -TargetRoot $sel.Target -CategoryIds $sel.CategoryIds -Mode $sel.Mode
    $sum = Get-PlanSummary -Items $plan

    if ($sum.Total -eq 0) { throw '在旧实例里没有找到所选项对应的文件，请确认选对了文件夹。' }
    if (($sum.Copy + $sum.Overwrite + $sum.Merge) -eq 0) {
        [Windows.Forms.MessageBox]::Show('没有需要写入的文件（全部被跳过或已相同）。', '无事可做', 'OK', 'Information') | Out-Null
        return
    }

    $modeText = @{
        overwrite = '覆盖新实例中的同名文件'
        skip      = '保留新实例文件，只补充缺失的'
        newer     = '只在新文件更旧时覆盖'
        keybinds  = '只合并 options.txt 里的按键'
    }[$sel.Mode]

    $msg = "即将把旧实例的数据迁移到新实例：`n`n新增 {0} 个文件`n覆盖 {1} 个文件`n合并按键 {2} 处`n跳过 {3} 个文件`n共约 {4}`n`n冲突处理：{5}`n`n是否继续？" -f `
        $sum.Copy, $sum.Overwrite, $sum.Merge, $sum.Skip, (Format-Size $sum.Bytes), $modeText
    $ans = [Windows.Forms.MessageBox]::Show($msg, '确认迁移', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { Add-UiLog '已取消。' 'WARN'; return }

    Add-UiLog "开始迁移（$modeText）..." 'INFO'

    foreach ($b in $script:UiState.Buttons) { $b.Enabled = $false }
    try {
        $script:UiState.Progress.Value = 0
        $result = Invoke-Migration -Items $plan -TargetRoot $sel.Target -DoBackup ([bool]$script:UiState.Backup.Checked) -BackupRoot $script:BackupRootDefault -Progress {
            param($done, $total, $item)
            if ($total -gt 0) { $script:UiState.Progress.Value = [int](100.0 * $done / $total) }
            if ($done -eq $total -or ($done % 25) -eq 0) {
                Add-UiLog ("  [{0}/{1}] {2}" -f $done, $total, $item.Relative) 'DIM'
            }
        }
        $script:UiState.Progress.Value = 100
        $script:UiState.LastBackup = $result.Backup

        Add-UiLog ("完成：成功 {0} 个，失败 {1} 个，合并按键 {2} 条，备份：{3}" -f $result.Success, $result.Failed, $result.MergedKeys, $(if ($result.Backup) { $result.Backup } else { '未备份' })) 'OK'
        if ($result.Failed -gt 0) { Add-UiLog '有文件复制失败，通常是游戏还开着或文件被占用，关掉游戏后重试即可。' 'WARN' }

        $logFile = Save-LogFile -Directory (Join-Path $script:BackupRootDefault 'logs') -Prefix 'migrate'
        if ($logFile) { Add-UiLog "本次日志：$logFile" 'DIM' }

        $doneMsg = "迁移完成。`n`n成功 {0} 个，失败 {1} 个。`n{2}" -f $result.Success, $result.Failed, $(if ($result.Backup) { "备份：$($result.Backup)" } else { '' })
        [Windows.Forms.MessageBox]::Show($doneMsg, '完成', 'OK', 'Information') | Out-Null
    } finally {
        foreach ($b in $script:UiState.Buttons) { $b.Enabled = $true }
    }
}

function Invoke-UiRestore {
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Title = '选择备份文件'
    $dlg.Filter = '备份文件 (*.zip)|*.zip'
    if (Test-Path -LiteralPath $script:BackupRootDefault) { $dlg.InitialDirectory = $script:BackupRootDefault }
    if ($dlg.ShowDialog() -ne 'OK') { return }

    $target = Resolve-FullPath $script:UiState.Target.Text
    if (-not $target -or -not (Test-Path -LiteralPath $target -PathType Container)) {
        $target = $null
        $pick = New-Object Windows.Forms.FolderBrowserDialog
        $pick.Description = '选择要还原到哪个实例文件夹'
        if ($pick.ShowDialog() -ne 'OK') { return }
        $target = $pick.SelectedPath
    }
    if ([Windows.Forms.MessageBox]::Show("确定把备份还原到：`n$target`n`n备份中的同名文件会被覆盖。", '确认还原', 'YesNo', 'Question') -ne 'Yes') { return }

    try {
        $n = Restore-Backup -ZipPath $dlg.FileName -TargetRoot $target
        Add-UiLog "还原完成，恢复 $n 个文件到 $target" 'OK'
        [Windows.Forms.MessageBox]::Show("已恢复 $n 个文件。", '还原完成', 'OK', 'Information') | Out-Null
    } catch {
        Add-UiLog ('还原失败：' + $_.Exception.Message) 'ERROR'
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, '还原失败', 'OK', 'Error') | Out-Null
    }
}

# ───────────────────────────── 命令行入口 ─────────────────────────────

function Invoke-CliMigration {
    $src = Resolve-FullPath $Source
    $dst = Resolve-FullPath $Target
    if (-not (Test-Path -LiteralPath $src -PathType Container)) { throw "旧实例文件夹不存在：$src" }
    if (-not (Test-Path -LiteralPath $dst -PathType Container)) { throw "新实例文件夹不存在：$dst" }
    if ($src -eq $dst) { throw '旧实例和新实例是同一个文件夹。' }

    $si = Get-InstanceInfo -Path $src
    $ti = Get-InstanceInfo -Path $dst
    if (-not $si.IsInstance) { throw "旧实例文件夹看起来不像整合包实例：$src`n（应包含 options.txt / config / mods / saves 中的至少一个）" }
    if (-not $ti.IsInstance -and -not $Force) { throw "新实例文件夹看起来不像整合包实例：$dst`n如果确定没错，加 -Force 再运行。" }

    $ids = @()
    if ($Preset -eq 'custom') {
        if (-not $Include -or $Include.Count -eq 0) { throw '-Preset custom 需要同时用 -Include 指定类别，例如 -Include settings,worlds' }
        $ids = @($Include)
    } else {
        $ids = @(Get-CategoryIdsForPreset -PresetName $Preset)
    }
    $valid = @((Get-CategoryDefs) | ForEach-Object { $_.Id })
    foreach ($id in $ids) { if ($valid -notcontains $id) { throw "未知类别：$id。可用类别：$($valid -join ', ')" } }

    Write-Log "旧实例：$src" 'INFO'
    Write-Log "新实例：$dst" 'INFO'
    Write-Log ("类别：{0}；冲突处理：{1}" -f ($ids -join ', '), $Mode) 'INFO'

    $plan = Get-MigrationPlan -SourceRoot $src -TargetRoot $dst -CategoryIds $ids -Mode $Mode
    $sum = Get-PlanSummary -Items $plan
    Write-Log ("共 {0} 个文件：新增 {1}，覆盖 {2}，合并按键 {3}，跳过 {4}，相同 {5}，约 {6}" -f `
            $sum.Total, $sum.Copy, $sum.Overwrite, $sum.Merge, $sum.Skip, $sum.Same, (Format-Size $sum.Bytes)) 'OK'

    if ($DryRun) {
        foreach ($cat in (Get-CategoryDefs)) {
            if ($ids -notcontains $cat.Id) { continue }
            $sub = @($plan | Where-Object { $_.CategoryId -eq $cat.Id })
            if ($sub.Count -eq 0) { continue }
            $cs = Get-PlanSummary -Items $sub
            Write-Host ("  [{0}] {1} 个文件：新增 {2} / 覆盖 {3} / 合并 {4} / 跳过 {5}" -f $cat.Name, $sub.Count, $cs.Copy, $cs.Overwrite, $cs.Merge, $cs.Skip) -ForegroundColor Cyan
        }
        Write-Host ''
        $preview = @($plan | Where-Object { $_.Action -in @('copy', 'overwrite', 'merge') } | Select-Object -First 40)
        if ($preview.Count -gt 0) {
            $preview | Select-Object Action, Relative, Reason | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
            if ($sum.Copy + $sum.Overwrite + $sum.Merge -gt 40) {
                Write-Log ("（只显示前 40 条，实际会写入 {0} 个文件）" -f ($sum.Copy + $sum.Overwrite + $sum.Merge)) 'DIM'
            }
        }
        Write-Log '这是预览（-DryRun），没有写入任何文件。' 'WARN'
        return
    }
    if (($sum.Copy + $sum.Overwrite + $sum.Merge) -eq 0) {
        Write-Log '没有需要写入的文件。' 'WARN'
        return
    }

    $backupDir = $script:BackupRootDefault
    if ($BackupRoot) { $backupDir = Resolve-FullPath $BackupRoot }
    $result = Invoke-Migration -Items $plan -TargetRoot $dst -DoBackup (-not $NoBackup) -BackupRoot $backupDir
    Write-Log ("完成：成功 {0}，失败 {1}，合并按键 {2} 条" -f $result.Success, $result.Failed, $result.MergedKeys) 'OK'
    if ($result.Backup) { Write-Log "备份文件：$($result.Backup)" 'OK' }
    [void](Save-LogFile -Directory (Join-Path $backupDir 'logs') -Prefix 'migrate')
    Write-Log '迁移结束。现在可以启动新实例了（建议先备份一次存档再开游戏）。' 'INFO'
}

# ───────────────────────────── 分发 ─────────────────────────────

try {
    switch ($PSCmdlet.ParameterSetName) {
        'Restore' {
            $to = $null
            if ($RestoreTo) { $to = Resolve-FullPath $RestoreTo }
            [void](Restore-Backup -ZipPath (Resolve-FullPath $Restore) -TargetRoot $to)
        }
        'Cli' {
            Invoke-CliMigration
        }
        default {
            Start-Gui -CapturePath $Capture
        }
    }
}
catch {
    $msg = $_.Exception.Message
    if ($PSCmdlet.ParameterSetName -eq 'Gui' -or $PSBoundParameters.ContainsKey('Gui')) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [Windows.Forms.MessageBox]::Show($msg, '出错啦', 'OK', 'Error') | Out-Null
        } catch { Write-Host $msg -ForegroundColor Red }
    } else {
        Write-Host $msg -ForegroundColor Red
        exit 1
    }
}
