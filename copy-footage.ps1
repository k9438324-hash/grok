<#
.SYNOPSIS
  把本机素材复制进收件箱。失败只停一次。

.DESCRIPTION
  整理成 <客户>\<片名>\口播、B-roll、对标、拍摄清单.md。
  只在本机复制。不上传，不调用付费接口，不循环重试。
#>
[CmdletBinding()]
param(
  [string]$Client,
  [string]$Title,
  [string]$Source,
  [string]$ARoll,
  [string]$BRoll,
  [string]$Reference,
  [string]$InboxRoot,
  [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Utf8 = New-Object System.Text.UTF8Encoding $false
$script:StdOut = [Console]::OpenStandardOutput()
$script:StdErr = [Console]::OpenStandardError()

function Write-OutLine {
  param([string]$Text)
  $bytes = $script:Utf8.GetBytes($Text + "`n")
  $script:StdOut.Write($bytes, 0, $bytes.Length)
  $script:StdOut.Flush()
}

function Write-ErrLine {
  param([string]$Text)
  $bytes = $script:Utf8.GetBytes($Text + "`n")
  $script:StdErr.Write($bytes, 0, $bytes.Length)
  $script:StdErr.Flush()
}

function Fail {
  param([string]$Message)
  throw $Message
}

function Test-SafeName {
  param([string]$Value, [string]$Label)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    Fail "失败：缺少 -Client 或 -Title。`n下一步：写上客户名和片名后再运行一次。例如 -Client '徐州陈茹一站式建材仓库' -Title '仓库开业口播'。"
  }
  if ($Value -match '[\x00-\x1F\\/:*?"<>|]') {
    Fail "失败：$Label 不能用作文件夹名：$Value`n下一步：去掉 \ / : * ? `" < > | 和控制字符，然后只运行一次。"
  }
  if ($Value.EndsWith(' ') -or $Value.EndsWith('.')) {
    Fail "失败：$Label 不能以空格或句点结尾：$Value`n下一步：改掉结尾的空格或句点，然后只运行一次。"
  }
  $reserved = @('CON','PRN','AUX','NUL','COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9','LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9')
  $stem = $Value
  $dot = $Value.IndexOf('.')
  if ($dot -gt 0) { $stem = $Value.Substring(0, $dot) }
  if ($reserved -contains $stem.ToUpperInvariant()) {
    Fail "失败：$Label 是 Windows 保留名：$Value`n下一步：换一个名字，然后只运行一次。"
  }
}

function Test-JunkName {
  param([string]$Name)
  switch ($Name.ToLowerInvariant()) {
    'desktop.ini' { return $true }
    'thumbs.db' { return $true }
    'ehthumbs.db' { return $true }
    '.ds_store' { return $true }
    default { return $false }
  }
}

function Test-IsUnderOrSame {
  param([string]$Child, [string]$Parent)
  $sep = [System.IO.Path]::DirectorySeparatorChar
  $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
  $childFull = [System.IO.Path]::GetFullPath($Child).TrimEnd('\', '/')
  if ($childFull.Equals($parentFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  return $childFull.StartsWith($parentFull + $sep, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-FilesUnder {
  param([string]$Root)
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push([System.IO.Path]::GetFullPath($Root))
  while ($stack.Count -gt 0) {
    $current = $stack.Pop()
    foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($current)) {
      $attr = [System.IO.File]::GetAttributes($entry)
      if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "失败：遇到链接，已停止，没有继续复制：$entry`n下一步：把真实文件放进目录，去掉快捷方式或符号链接，然后只运行一次。"
      }
      if (($attr -band [System.IO.FileAttributes]::Directory) -ne 0) {
        $stack.Push($entry)
      } else {
        Write-Output $entry
      }
    }
  }
}

function Get-RelativePath {
  param([string]$Root, [string]$Full)
  $sep = [System.IO.Path]::DirectorySeparatorChar
  $rootFull = [System.IO.Path]::GetFullPath($Root)
  if (-not $rootFull.EndsWith($sep)) { $rootFull = $rootFull + $sep }
  $full = [System.IO.Path]::GetFullPath($Full)
  if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail "失败：素材路径跑出来源目录了：$Full`n下一步：检查有没有用链接把别的位置套进来。去掉之后只运行一次。"
  }
  return $full.Substring($rootFull.Length)
}

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Join-SubPath {
  param([string]$Root, [string]$Relative)
  $path = $Root
  foreach ($part in ($Relative -split '[\\/]')) {
    if ($part -eq '' -or $part -eq '.') { continue }
    if ($part -eq '..') {
      Fail "失败：素材相对路径越界：$Relative`n下一步：移动这个文件，去掉路径里的 .. ，然后只运行一次。"
    }
    $path = Join-Path $path $part
  }
  return $path
}

function ConvertTo-JsonString {
  param([string]$Text)
  if ($null -eq $Text) { $Text = '' }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  foreach ($ch in $Text.ToCharArray()) {
    $code = [int][char]$ch
    if ($ch -eq '"') { [void]$sb.Append('\"') }
    elseif ($ch -eq '\') { [void]$sb.Append('\\') }
    elseif ($ch -eq "`b") { [void]$sb.Append('\b') }
    elseif ($ch -eq "`t") { [void]$sb.Append('\t') }
    elseif ($ch -eq "`n") { [void]$sb.Append('\n') }
    elseif ($ch -eq "`f") { [void]$sb.Append('\f') }
    elseif ($ch -eq "`r") { [void]$sb.Append('\r') }
    elseif ($code -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
    else { [void]$sb.Append($ch) }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function ConvertTo-JsonBool {
  param([bool]$Value)
  if ($Value) { return 'true' }
  return 'false'
}

function Get-CopyState {
  param([string]$SourcePath, [string]$DestPath)
  if (-not (Test-Path -LiteralPath $DestPath -PathType Leaf)) { return 'new' }
  if ((Get-Sha256 $SourcePath) -eq (Get-Sha256 $DestPath)) { return 'same' }
  return 'diff'
}

function Write-Manifest {
  param(
    [string]$Path,
    [string]$ClientName,
    [string]$TitleName,
    [string]$InboxPath,
    [string]$BotPath,
    [hashtable]$Counts,
    [hashtable]$Present,
    [object[]]$Files
  )
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('{')
  [void]$sb.AppendLine(('  "client": {0},' -f (ConvertTo-JsonString $ClientName)))
  [void]$sb.AppendLine(('  "title": {0},' -f (ConvertTo-JsonString $TitleName)))
  [void]$sb.AppendLine(('  "inboxPath": {0},' -f (ConvertTo-JsonString $InboxPath)))
  [void]$sb.AppendLine(('  "botPath": {0},' -f (ConvertTo-JsonString $BotPath)))
  [void]$sb.AppendLine('  "fileCounts": {')
  [void]$sb.AppendLine(('    "口播": {0},' -f [int]$Counts['口播']))
  [void]$sb.AppendLine(('    "B-roll": {0},' -f [int]$Counts['B-roll']))
  [void]$sb.AppendLine(('    "对标": {0}' -f [int]$Counts['对标']))
  [void]$sb.AppendLine('  },')
  [void]$sb.AppendLine('  "present": {')
  [void]$sb.AppendLine(('    "拍摄清单.md": {0},' -f (ConvertTo-JsonBool ([bool]$Present['拍摄清单.md']))))
  [void]$sb.AppendLine(('    "口播": {0},' -f (ConvertTo-JsonBool ([bool]$Present['口播']))))
  [void]$sb.AppendLine(('    "B-roll": {0},' -f (ConvertTo-JsonBool ([bool]$Present['B-roll']))))
  [void]$sb.AppendLine(('    "对标": {0}' -f (ConvertTo-JsonBool ([bool]$Present['对标']))))
  [void]$sb.AppendLine('  },')
  [void]$sb.AppendLine('  "files": [')
  for ($i = 0; $i -lt $Files.Count; $i++) {
    $file = $Files[$i]
    $comma = ''
    if ($i -lt ($Files.Count - 1)) { $comma = ',' }
    [void]$sb.AppendLine('    {')
    [void]$sb.AppendLine(('      "bucket": {0},' -f (ConvertTo-JsonString $file.Bucket)))
    [void]$sb.AppendLine(('      "path": {0},' -f (ConvertTo-JsonString $file.Path)))
    [void]$sb.AppendLine(('      "sha256": {0},' -f (ConvertTo-JsonString $file.Sha256)))
    [void]$sb.AppendLine(('      "bytes": {0}' -f [int64]$file.Bytes))
    [void]$sb.AppendLine(('    }}{0}' -f $comma))
  }
  [void]$sb.AppendLine('  ]')
  [void]$sb.AppendLine('}')
  [System.IO.File]::WriteAllText($Path, $sb.ToString(), $script:Utf8)
}

$BucketNames = @('口播', 'B-roll', '对标')
$AliasToBucket = @{
  '口播' = '口播'
  'aroll' = '口播'
  'a-roll' = '口播'
  'a_roll' = '口播'
  'b-roll' = 'B-roll'
  'broll' = 'B-roll'
  'b_roll' = 'B-roll'
  '对标' = '对标'
  'reference' = '对标'
}

try {
  Test-SafeName $Client '客户名'
  Test-SafeName $Title '片名'

  $explicit = @{}
  if (-not [string]::IsNullOrWhiteSpace($ARoll)) { $explicit['口播'] = $ARoll }
  if (-not [string]::IsNullOrWhiteSpace($BRoll)) { $explicit['B-roll'] = $BRoll }
  if (-not [string]::IsNullOrWhiteSpace($Reference)) { $explicit['对标'] = $Reference }

  if ([string]::IsNullOrWhiteSpace($Source) -and $explicit.Count -eq 0) {
    Fail "失败：没有指定素材位置。`n下一步：加上 -Source 'D:\拍好的素材'，或用 -ARoll / -BRoll / -Reference 指出目录，然后只运行一次。"
  }

  if (-not [string]::IsNullOrWhiteSpace($Source)) {
    if (-not (Test-Path -LiteralPath $Source)) {
      Fail "失败：来源目录不存在：$Source`n下一步：核对 -Source 路径。改对之后只再运行一次，不要循环重试。"
    }
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
      Fail "失败：来源不是文件夹：$Source`n下一步：-Source 要指向文件夹，而不是单个文件。改对之后只运行一次。"
    }
    $Source = [System.IO.Path]::GetFullPath($Source)
  }

  foreach ($bucket in @($explicit.Keys)) {
    $given = $explicit[$bucket]
    if (-not (Test-Path -LiteralPath $given -PathType Container)) {
      Fail "失败：指定的 $bucket 目录不存在或不是文件夹：$given`n下一步：核对 -ARoll / -BRoll / -Reference。改对之后只运行一次。"
    }
    $explicit[$bucket] = [System.IO.Path]::GetFullPath($given)
  }

  $auto = @{ '口播' = ''; 'B-roll' = ''; '对标' = '' }
  $handled = New-Object System.Collections.Generic.List[string]
  foreach ($bucket in @($explicit.Keys)) { [void]$handled.Add($explicit[$bucket]) }

  if (-not [string]::IsNullOrWhiteSpace($Source)) {
    foreach ($dir in [System.IO.Directory]::GetDirectories($Source)) {
      $attr = [System.IO.File]::GetAttributes($dir)
      $name = [System.IO.Path]::GetFileName($dir)
      $key = $name.ToLowerInvariant()
      if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "失败：来源里有链接，已停止：$dir`n下一步：改用真实文件夹，不要用快捷方式套一层，然后只运行一次。"
      }
      if (-not $AliasToBucket.ContainsKey($key)) { continue }
      $bucket = $AliasToBucket[$key]
      [void]$handled.Add([System.IO.Path]::GetFullPath($dir))
      if ($explicit.ContainsKey($bucket)) { continue }
      if (-not [string]::IsNullOrWhiteSpace($auto[$bucket])) {
        Fail "失败：「$bucket」对上了两个文件夹：$($auto[$bucket]) 和 $dir`n下一步：只留一个，或改用 -ARoll / -BRoll / -Reference 指定，然后只运行一次。"
      }
      $auto[$bucket] = [System.IO.Path]::GetFullPath($dir)
    }
  }

  $roots = @{ '口播' = ''; 'B-roll' = ''; '对标' = '' }
  foreach ($bucket in $BucketNames) {
    if ($explicit.ContainsKey($bucket)) { $roots[$bucket] = $explicit[$bucket] }
    elseif (-not [string]::IsNullOrWhiteSpace($auto[$bucket])) { $roots[$bucket] = $auto[$bucket] }
  }

  if ([string]::IsNullOrWhiteSpace($InboxRoot)) {
    $InboxRoot = Join-Path (Get-Location) 'customers-footage'
  }
  $destRoot = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $InboxRoot $Client) $Title))
  $botPath = "/workspace/客户片/$Client/$Title/"

  $places = New-Object System.Collections.Generic.List[object]
  if (-not [string]::IsNullOrWhiteSpace($Source)) {
    $places.Add([pscustomobject]@{ Label = '来源目录'; Path = $Source })
  }
  foreach ($bucket in $BucketNames) {
    if (-not [string]::IsNullOrWhiteSpace($roots[$bucket])) {
      $places.Add([pscustomobject]@{ Label = $bucket; Path = $roots[$bucket] })
    }
  }
  foreach ($place in $places) {
    if (Test-IsUnderOrSame $destRoot $place.Path) {
      Fail "失败：收件箱落在$($place.Label)里面：$destRoot`n下一步：换一个 -InboxRoot，让收件箱位于素材目录之外，然后只运行一次。"
    }
    if (Test-IsUnderOrSame $place.Path $destRoot) {
      Fail "失败：$($place.Label)落在收件箱里面：$($place.Path)`n下一步：换一个 -InboxRoot 或素材目录，避免互相套住，然后只运行一次。"
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($Source)) {
    $loose = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(Get-FilesUnder $Source)) {
      $base = [System.IO.Path]::GetFileName($file)
      if (Test-JunkName $base) { continue }
      $parent = [System.IO.Path]::GetDirectoryName($file)
      $atRoot = $parent.Equals($Source, [System.StringComparison]::OrdinalIgnoreCase)
      if ($atRoot -and ($base.Equals('拍摄清单.md', [System.StringComparison]::OrdinalIgnoreCase) -or $base.Equals('manifest.json', [System.StringComparison]::OrdinalIgnoreCase))) {
        continue
      }
      $covered = $false
      foreach ($dir in $handled) {
        if (Test-IsUnderOrSame $file $dir) { $covered = $true; break }
      }
      if ($covered) { continue }
      $looseRelative = (Get-RelativePath $Source $file) -replace '\\', '/'
      [void]$loose.Add($looseRelative)
    }
    if ($loose.Count -gt 0) {
      $sb = New-Object System.Text.StringBuilder
      [void]$sb.AppendLine("失败：有 $($loose.Count) 个文件无法归类，已停止，没有复制。")
      $shown = 0
      foreach ($item in $loose) {
        if ($shown -ge 20) { break }
        [void]$sb.AppendLine("  - $item")
        $shown++
      }
      if ($loose.Count -gt 20) { [void]$sb.AppendLine("  - …还有 $($loose.Count - 20) 个") }
      [void]$sb.Append('下一步：把文件放进子目录 口播、B-roll 或 对标（也认 aroll、broll、reference），或加上 -ARoll、-BRoll、-Reference。本脚本不会猜测，也不会重试。')
      Fail $sb.ToString()
    }
  }

  $ops = New-Object System.Collections.Generic.List[object]
  foreach ($bucket in $BucketNames) {
    if ([string]::IsNullOrWhiteSpace($roots[$bucket])) { continue }
    $seen = @{}
    foreach ($file in @(Get-FilesUnder $roots[$bucket])) {
      if (Test-JunkName ([System.IO.Path]::GetFileName($file))) { continue }
      $relative = (Get-RelativePath $roots[$bucket] $file) -replace '\\', '/'
      $key = $relative.ToLowerInvariant()
      if ($seen.ContainsKey($key)) {
        Fail "失败：「$bucket」里有两个只是大小写不同的文件：$relative`n下一步：改成不同的文件名，然后只运行一次。"
      }
      $seen[$key] = $true
      $ops.Add([pscustomobject]@{
        SourcePath = $file
        DestPath = Join-SubPath (Join-Path $destRoot $bucket) $relative
        Display = "$bucket/$relative"
      })
    }
  }

  if ($ops.Count -eq 0) {
    Fail "失败：没有找到可归类的素材文件。`n下一步：确认 口播、B-roll、对标 里至少有一类真有文件，然后只运行一次。"
  }

  $shotSource = ''
  if (-not [string]::IsNullOrWhiteSpace($Source)) {
    foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($Source)) {
      $attr = [System.IO.File]::GetAttributes($entry)
      if (($attr -band [System.IO.FileAttributes]::Directory) -ne 0) { continue }
      $base = [System.IO.Path]::GetFileName($entry)
      if ($base.Equals('拍摄清单.md', [System.StringComparison]::OrdinalIgnoreCase)) {
        $shotSource = $entry
        break
      }
    }
  }
  $shotDest = Join-Path $destRoot '拍摄清单.md'
  $templatePath = Join-Path $PSScriptRoot (Join-Path 'templates' '拍摄清单.md')
  if (-not [string]::IsNullOrWhiteSpace($shotSource)) {
    $ops.Add([pscustomobject]@{
      SourcePath = $shotSource
      DestPath = $shotDest
      Display = '拍摄清单.md'
    })
  } elseif (-not (Test-Path -LiteralPath $shotDest -PathType Leaf)) {
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
      Fail "失败：找不到拍摄清单模板：$templatePath`n下一步：把仓库里的 templates/拍摄清单.md 放回去，然后只运行一次。"
    }
    $ops.Add([pscustomobject]@{
      SourcePath = $templatePath
      DestPath = $shotDest
      Display = '拍摄清单.md'
    })
  }

  if (-not $Force) {
    $conflicts = New-Object System.Collections.Generic.List[string]
    foreach ($op in $ops) {
      if ((Get-CopyState $op.SourcePath $op.DestPath) -eq 'diff') { [void]$conflicts.Add($op.Display) }
    }
    if ($conflicts.Count -gt 0) {
      $sb = New-Object System.Text.StringBuilder
      [void]$sb.AppendLine('失败：目标里已有内容不同的文件，已停止，没有覆盖。')
      foreach ($item in $conflicts) { [void]$sb.AppendLine("  - $item") }
      [void]$sb.Append('下一步：确认可以替换后，加上 -Force 再运行一次；或者换一个 -Title。不要反复重试同一条命令。')
      Fail $sb.ToString()
    }
  }

  foreach ($bucket in $BucketNames) {
    $dir = Join-Path $destRoot $bucket
    if (-not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
  }

  $copied = 0
  $skipped = 0
  $overwritten = 0
  foreach ($op in $ops) {
    $state = Get-CopyState $op.SourcePath $op.DestPath
    if ($state -eq 'same') { $skipped++; continue }
    if ($state -eq 'diff' -and -not $Force) {
      Fail "失败：目标文件在检查之后变了：$($op.Display)`n下一步：确认没有别人同时在写这个收件箱，然后只再运行一次。需要替换时加上 -Force。"
    }
    $parent = Split-Path -Parent $op.DestPath
    if (-not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::Copy($op.SourcePath, $op.DestPath, $true)
    if ($state -eq 'diff') { $overwritten++ } else { $copied++ }
  }

  $rows = New-Object System.Collections.Generic.List[object]
  $counts = @{ '口播' = 0; 'B-roll' = 0; '对标' = 0 }
  foreach ($bucket in $BucketNames) {
    $bucketDir = Join-Path $destRoot $bucket
    foreach ($file in @(Get-FilesUnder $bucketDir)) {
      if (Test-JunkName ([System.IO.Path]::GetFileName($file))) { continue }
      $relative = (Get-RelativePath $bucketDir $file) -replace '\\', '/'
      $counts[$bucket]++
      $rows.Add([pscustomobject]@{
        Bucket = $bucket
        Path = $relative
        Sha256 = Get-Sha256 $file
        Bytes = (New-Object System.IO.FileInfo $file).Length
        Sort = $bucket
      })
    }
  }
  $shotExists = Test-Path -LiteralPath $shotDest -PathType Leaf
  if ($shotExists) {
    $rows.Add([pscustomobject]@{
      Bucket = '拍摄清单.md'
      Path = '拍摄清单.md'
      Sha256 = Get-Sha256 $shotDest
      Bytes = (New-Object System.IO.FileInfo $shotDest).Length
      Sort = '拍摄清单.md'
    })
  }

  $order = @{ '口播' = 0; 'B-roll' = 1; '对标' = 2; '拍摄清单.md' = 3 }
  $sorted = @($rows | Sort-Object @{ Expression = { $order[$_.Sort] } }, @{ Expression = { $_.Path } })
  $present = @{
    '拍摄清单.md' = [bool]$shotExists
    '口播' = ($counts['口播'] -gt 0)
    'B-roll' = ($counts['B-roll'] -gt 0)
    '对标' = ($counts['对标'] -gt 0)
  }
  Write-Manifest -Path (Join-Path $destRoot 'manifest.json') -ClientName $Client -TitleName $Title -InboxPath $destRoot -BotPath $botPath -Counts $counts -Present $present -Files $sorted

  Write-OutLine "本地收件箱：$destRoot"
  Write-OutLine "机器人路径：$botPath"
  Write-OutLine '请在聊天里告诉嘉豪复制这个文件夹（不要通过参谋长机器人传输）。'
  Write-OutLine "复制 $copied 个，跳过相同 $skipped 个，覆盖 $overwritten 个。"
  exit 0
} catch {
  $msg = $_.Exception.Message
  if ($msg -notlike '失败：*') {
    $msg = "失败：未预期的错误：$msg`n下一步：按这一行改好之后只再运行一次。不要循环重试。"
  }
  Write-ErrLine $msg
  exit 1
}
