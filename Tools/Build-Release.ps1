<#
.SYNOPSIS
    Cosmic Indifference 打包脚本：一次运行同时产出 Release 包与 Debug 包。

.DESCRIPTION
    本 mod 为纯 XML + 音频，无 C# 工程，因此脚本不含编译步骤。
    版本号唯一来源为 About/About.xml 的 <modVersion>，脚本负责：
      1. 校验工作区状态与 tag 是否已存在（仅告警，不阻塞；未建 git 仓库时跳过）；
      2. 按白名单组装两个包（About / Patches / Sounds），开发文件（Tools、dist）不进包；
      3. Debug 包把包内 <modVersion> 改写为 "<版本>-debug"，仓库原文件不动；
      4. 压缩为 dist/ 下的两个 zip（显式 UTF-8 条目名，兼容中文文件名）。

.PARAMETER CreateRelease
    打包完成后调用 gh CLI 创建 GitHub Release 并上传两个 zip（需先 push 并已登录 gh）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Tools\Build-Release.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Tools\Build-Release.ps1 -CreateRelease

.NOTES
    本文件必须保存为 UTF-8 with BOM：Windows PowerShell 5.1 会把无 BOM 的 UTF-8 脚本按系统
    ANSI（中文系统为 GBK）解码，中文字符串乱码后连引号一起被吞掉，脚本直接报语法错误。
#>
[CmdletBinding()]
param(
    [switch]$CreateRelease
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==== 可配置项 ====
$PackageName    = 'CosmicIndifference'              # 发布包顶层文件夹名（zip 解压后的目录名）
$IncludeDirs    = @('About', 'Patches', 'Sounds')   # 进入发布包的目录白名单（根级布局，无版本子目录）
$RequiredDirs   = @('About', 'Patches', 'Sounds')   # 缺失即报错的目录
$IncludeRootFiles = @()                             # 根级必需文件（本 mod 无 LoadFolders.xml）
$DistDirName    = 'dist'                            # 打包输出目录（已被 .gitignore 忽略）
$DebugModSuffix = 'debug'                           # 调试包版本号与文件名后缀
# ==================

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$AboutPath = Join-Path $RepoRoot 'About\About.xml'
$DistDir   = Join-Path $RepoRoot $DistDirName
$StageDir  = Join-Path $DistDir 'stage'

<#
.SYNOPSIS 输出阶段提示。
#>
function Write-Step {
    param([string]$Text)
    Write-Host "==> $Text" -ForegroundColor Cyan
}

<#
.SYNOPSIS 从 About.xml 读取 <modVersion>（版本号唯一人工编辑点）。
.PARAMETER Path About.xml 的绝对路径。
#>
function Get-ModVersion {
    param([string]$Path)

    if (-not (Test-Path $Path)) { throw "未找到 About.xml：$Path" }

    [xml]$xml = Get-Content -Path $Path -Raw
    $version = $xml.ModMetaData.modVersion
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "About.xml 中缺少 <modVersion>，请先补全后再打包"
    }
    return $version.Trim()
}

<#
.SYNOPSIS 按白名单组装单个发布包目录。
.PARAMETER ModRoot 目标包根目录（即包内顶层文件夹）。
.PARAMETER IsDebug 是否为调试包（决定是否改写 modVersion）。
.PARAMETER Version 版本号（用于调试包改写）。
#>
function Copy-PackageLayout {
    param(
        [string]$ModRoot,
        [bool]$IsDebug,
        [string]$Version
    )

    if (Test-Path $ModRoot) { Remove-Item $ModRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $ModRoot -Force | Out-Null

    foreach ($dir in $IncludeDirs) {
        $src = Join-Path $RepoRoot $dir
        if (-not (Test-Path $src)) {
            if ($RequiredDirs -contains $dir) { throw "发布包必需目录缺失：$dir" }
            Write-Warning "目录不存在，已跳过：$dir"
            continue
        }
        # robocopy 退出码 0-7 为成功（含「跳过若干文件」），>=8 才是真失败；
        # /R:2 /W:1 避免目标文件被游戏占用时长时间重试卡住脚本
        $null = & robocopy $src (Join-Path $ModRoot $dir) /E /NFL /NDL /NJH /NJS /NP /R:2 /W:1
        if ($LASTEXITCODE -ge 8) { throw "复制目录失败（robocopy exit $LASTEXITCODE）：$src" }
    }

    foreach ($file in $IncludeRootFiles) {
        $src = Join-Path $RepoRoot $file
        if (-not (Test-Path $src)) { throw "发布包必需文件缺失：$file" }
        Copy-Item -Path $src -Destination (Join-Path $ModRoot $file) -Force
    }

    # 调试包：改写包内版本号，便于玩家在游戏内 mod 列表区分（不改动仓库原文件）
    if ($IsDebug) {
        $targetAbout = Join-Path $ModRoot 'About\About.xml'
        $text = [System.IO.File]::ReadAllText($targetAbout)
        $text = [regex]::Replace($text, '<modVersion>.*?</modVersion>', "<modVersion>$Version-$DebugModSuffix</modVersion>")
        [System.IO.File]::WriteAllText($targetAbout, $text, (New-Object System.Text.UTF8Encoding $true))
    }
}

<#
.SYNOPSIS 将目录压缩为 zip（保留顶层文件夹，显式 UTF-8 条目名以兼容中文文件名）。
.PARAMETER SourceDir 待压缩目录（其父目录作为 zip 内路径基准）。
.PARAMETER DestZip 目标 zip 路径。
#>
function New-ZipFromDirectory {
    param([string]$SourceDir, [string]$DestZip)

    Add-Type -AssemblyName System.IO.Compression | Out-Null

    if (Test-Path $DestZip) { Remove-Item $DestZip -Force }
    New-Item -ItemType Directory -Path (Split-Path -Parent $DestZip) -Force | Out-Null

    $baseDir = Split-Path -Parent $SourceDir
    $fileStream = [System.IO.File]::Open($DestZip, [System.IO.FileMode]::Create)
    $archive = New-Object -TypeName System.IO.Compression.ZipArchive -ArgumentList $fileStream, ([System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -Path $SourceDir -Recurse -File) {
            $entryName = $file.FullName.Substring($baseDir.Length + 1).Replace('\', '/')
            $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            try {
                $inStream = [System.IO.File]::OpenRead($file.FullName)
                try { $inStream.CopyTo($entryStream) } finally { $inStream.Dispose() }
            } finally {
                $entryStream.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
        $fileStream.Dispose()
    }
}

# ================== 主流程 ==================

$version = Get-ModVersion -Path $AboutPath
Write-Step "版本号：$version"

$gitDir = Join-Path $RepoRoot '.git'
if (Test-Path $gitDir) {
    # 工作区未提交改动会导致包内容不对应任何 commit，仅告警
    $dirty = & git -C $RepoRoot status --porcelain
    if ($dirty) {
        Write-Warning "工作区存在未提交改动，Debug/Release 包可能不对应任何 commit：`n$dirty"
    }

    # 同名 tag 已存在通常意味着忘记提升版本号
    $existingTag = & git -C $RepoRoot tag -l "v$version"
    if ($existingTag) {
        Write-Warning "tag v$version 已存在，请确认是否已提升 <modVersion>"
    }
} else {
    Write-Warning "未检测到 .git 目录，跳过工作区与 tag 校验（打包继续）"
}

if (Test-Path $StageDir) { Remove-Item $StageDir -Recurse -Force }
New-Item -ItemType Directory -Path $StageDir -Force | Out-Null

$releaseModRoot = Join-Path $StageDir "release\$PackageName"
$debugModRoot   = Join-Path $StageDir "$DebugModSuffix\$PackageName"

Copy-PackageLayout -ModRoot $releaseModRoot -IsDebug $false -Version $version
Copy-PackageLayout -ModRoot $debugModRoot   -IsDebug $true  -Version $version

$releaseZip = Join-Path $DistDir "$PackageName-$version.zip"
$debugZip   = Join-Path $DistDir "$PackageName-$version-$DebugModSuffix.zip"

New-ZipFromDirectory -SourceDir $releaseModRoot -DestZip $releaseZip
New-ZipFromDirectory -SourceDir $debugModRoot -DestZip $debugZip

Write-Step "打包完成"
Write-Host "  Release 包：$releaseZip"
Write-Host "  Debug   包：$debugZip"
Write-Host "  组装目录  ：$StageDir"

# 1.7 工坊上传口径提示：本 mod 同时支持 1.6 与 1.7，属「含旧版本」情形
Write-Host "  工坊勾选  ：本 mod 支持 1.6/1.7，上传时【不要】勾 Don't upload source textures（1.6 读不了 Assets.zip）" -ForegroundColor Yellow
Write-Host "  （bake 只由游戏内上传器触发；若勾 Build asset pack，产物落在开发目录，勿手工放进 dist/）" -ForegroundColor DarkGray
if (-not (Test-Path (Join-Path $RepoRoot 'About\PublishedFileId.txt'))) {
    Write-Host "  工坊提示  ：About\PublishedFileId.txt 不存在——首次上传后由游戏生成并保留在包内，勿删除" -ForegroundColor DarkGray
}

if ($CreateRelease) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Warning "未检测到 gh CLI，跳过自动发布。请手动在 GitHub 创建 Release 并上传上述两个 zip。"
    } else {
        Write-Step "创建 GitHub Release v$version（请确认代码已 push，否则 tag 会指向远程旧 commit）"
        & gh release create "v$version" $releaseZip $debugZip --title "v$version" --generate-notes
        if ($LASTEXITCODE -ne 0) { throw "gh release create 失败（exit $LASTEXITCODE）" }
    }
}
