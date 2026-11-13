# 覆盖：成功、拒绝覆盖不同文件、来源不存在。另外核对无法归类、英文目录名、显式参数。
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:POWERSHELL_TELEMETRY_OPTOUT = '1'
$env:POWERSHELL_UPDATECHECK = 'Off'

$repoRoot = Split-Path -Parent $PSScriptRoot
$script:CopyScript = Join-Path $repoRoot 'copy-footage.ps1'
$script:Template = Join-Path $repoRoot (Join-Path 'templates' '拍摄清单.md')
$utf8 = New-Object System.Text.UTF8Encoding $false

function Assert-That {
  param([bool]$Ok, [string]$Message)
  if (-not $Ok) { throw $Message }
}

function ChildPath {
  param([string]$Base, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Parts)
  $path = $Base
  foreach ($part in $Parts) { $path = Join-Path $path $part }
  return $path
}

function New-TextFile {
  param([string]$Path, [string]$Content)
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Quote-WindowsArg {
  param([string]$Arg)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $slashes = 0
  foreach ($ch in $Arg.ToCharArray()) {
    if ($ch -eq '\') { $slashes++; continue }
    if ($ch -eq '"') {
      [void]$sb.Append('\', (2 * $slashes + 1))
      [void]$sb.Append('"')
      $slashes = 0
      continue
    }
    if ($slashes -gt 0) {
      [void]$sb.Append('\', $slashes)
      $slashes = 0
    }
    [void]$sb.Append($ch)
  }
  if ($slashes -gt 0) { [void]$sb.Append('\', ($slashes * 2)) }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function Invoke-Footage {
  param([string]$WorkDir, [string[]]$UserArgs)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = (Get-Process -Id $PID).Path
  $psi.WorkingDirectory = $WorkDir
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = $utf8
  $psi.StandardErrorEncoding = $utf8
  $pieces = @('-NoProfile', '-File', $script:CopyScript) + $UserArgs
  if ($null -ne $psi.PSObject.Properties['ArgumentList']) {
    foreach ($piece in $pieces) { [void]$psi.ArgumentList.Add($piece) }
  } else {
    $psi.Arguments = (($pieces | ForEach-Object { Quote-WindowsArg $_ }) -join ' ')
  }
  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()
  $outTask = $proc.StandardOutput.ReadToEndAsync()
  $errTask = $proc.StandardError.ReadToEndAsync()
  [void]$proc.WaitForExit()
  return [pscustomobject]@{
    ExitCode = $proc.ExitCode
    StdOut = $outTask.Result
    StdErr = $errTask.Result
  }
}

function Get-Sha256Text {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Read-Manifest {
  param([string]$Path)
  $json = [System.IO.File]::ReadAllText($Path, $utf8)
  return ($json | ConvertFrom-Json)
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('footage-inbox-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $root | Out-Null
$failures = New-Object System.Collections.Generic.List[string]

function Invoke-Test {
  param([string]$Name, [scriptblock]$Body)
  try {
    & $Body
    Write-Host "PASS $Name"
  } catch {
    $failures.Add("$Name`: $($_.Exception.Message)")
    Write-Host "FAIL $Name"
    Write-Host $_.Exception.Message
  }
}

try {
  Invoke-Test 'script has no network calls' {
    $text = [System.IO.File]::ReadAllText($script:CopyScript, $utf8)
    Assert-That (Test-Path -LiteralPath $script:Template) 'missing template'
    Assert-That ($text -notmatch 'Invoke-WebRequest|Invoke-RestMethod|curl|ChatCut|Start-Sleep') $text
  }

  Invoke-Test 'happy path' {
    $work = Join-Path $root 'happy'
    $source = Join-Path $work 'source'
    $inbox = Join-Path $work 'inbox'
    New-TextFile (ChildPath $source '口播' '开场.txt') 'talk-v1'
    New-TextFile (ChildPath $source '口播' 'desktop.ini') 'junk'
    New-TextFile (Join-Path $source 'desktop.ini') 'junk-root'
    New-TextFile (ChildPath $source 'B-roll' 'wide.txt') 'wide'
    New-TextFile (ChildPath $source 'B-roll' '房间' '墙面.txt') 'wall'
    New-TextFile (ChildPath $source '对标' 'ref.txt') 'ref'
    New-TextFile (Join-Path $source '拍摄清单.md') '清单甲'
    $title = '仓库开业口播'
    $client = '徐州陈茹一站式建材仓库'
    $result = Invoke-Footage $work @(
      '-Client', $client, '-Title', $title, '-Source', $source, '-InboxRoot', $inbox
    )
    Assert-That ($result.ExitCode -eq 0) "exit $($result.ExitCode)`n$($result.StdErr)`n$($result.StdOut)"
    Assert-That ([string]::IsNullOrWhiteSpace($result.StdErr)) $result.StdErr
    Assert-That ($result.StdOut -notmatch 'copy-footage\.ps1:') $result.StdOut
    $dest = Join-Path (Join-Path $inbox $client) $title
    Assert-That ($result.StdOut.Contains("本地收件箱：$dest")) $result.StdOut
    Assert-That ($result.StdOut.Contains("机器人路径：/workspace/客户片/$client/$title/")) $result.StdOut
    Assert-That ($result.StdOut.Contains('请在聊天里告诉嘉豪复制这个文件夹（不要通过参谋长机器人传输）。')) $result.StdOut
    Assert-That ($result.StdOut.Contains('复制 5 个，跳过相同 0 个，覆盖 0 个。')) $result.StdOut
    Assert-That ((Get-Content -LiteralPath (ChildPath $dest '口播' '开场.txt') -Raw) -eq 'talk-v1') 'aroll content'
    Assert-That ((Get-Content -LiteralPath (ChildPath $dest 'B-roll' '房间' '墙面.txt') -Raw) -eq 'wall') 'nested content'
    Assert-That (-not (Test-Path -LiteralPath (ChildPath $dest '口播' 'desktop.ini'))) 'junk copied'
    $before = (Get-Item -LiteralPath (ChildPath $dest '口播' '开场.txt')).LastWriteTimeUtc
    $manifestBefore = [System.IO.File]::ReadAllText((Join-Path $dest 'manifest.json'), $utf8)
    $again = Invoke-Footage $work @(
      '-Client', $client, '-Title', $title, '-Source', $source, '-InboxRoot', $inbox
    )
    Assert-That ($again.ExitCode -eq 0) $again.StdErr
    Assert-That ($again.StdOut.Contains('复制 0 个，跳过相同 5 个，覆盖 0 个。')) $again.StdOut
    $after = (Get-Item -LiteralPath (ChildPath $dest '口播' '开场.txt')).LastWriteTimeUtc
    Assert-That ($before -eq $after) 'identical file was rewritten'
    $manifest = Read-Manifest (Join-Path $dest 'manifest.json')
    Assert-That ($manifest.client -eq $client) 'client'
    Assert-That ($manifest.title -eq $title) 'title'
    Assert-That ($manifest.botPath -eq "/workspace/客户片/$client/$title/") $manifest.botPath
    Assert-That ($manifest.fileCounts.'口播' -eq 1) 'count aroll'
    Assert-That ($manifest.fileCounts.'B-roll' -eq 2) 'count broll'
    Assert-That ($manifest.fileCounts.'对标' -eq 1) 'count ref'
    Assert-That ($manifest.present.'拍摄清单.md' -eq $true) 'shot present'
    Assert-That ($manifest.present.'口播' -eq $true) 'aroll present'
    Assert-That ($manifest.present.'B-roll' -eq $true) 'broll present'
    Assert-That ($manifest.present.'对标' -eq $true) 'ref present'
    $wall = @($manifest.files | Where-Object { $_.path -eq '房间/墙面.txt' })
    Assert-That ($wall.Count -eq 1) 'nested manifest row'
    Assert-That ($wall[0].bucket -eq 'B-roll') 'nested bucket'
    Assert-That ($wall[0].sha256 -eq (Get-Sha256Text (ChildPath $dest 'B-roll' '房间' '墙面.txt'))) 'hash'
    Assert-That ($wall[0].bytes -eq 4) 'bytes'
    $shot = @($manifest.files | Where-Object { $_.bucket -eq '拍摄清单.md' })
    Assert-That ($shot.Count -eq 1) 'shot row'
    Assert-That ($shot[0].sha256 -eq (Get-Sha256Text (Join-Path $dest '拍摄清单.md'))) 'shot hash'
    Assert-That ($manifestBefore -eq [System.IO.File]::ReadAllText((Join-Path $dest 'manifest.json'), $utf8)) 'manifest changed on identical rerun'
  }

  Invoke-Test 'refuse overwrite of a different file' {
    $work = Join-Path $root 'overwrite'
    $source = Join-Path $work 'source'
    $inbox = Join-Path $work 'inbox'
    $client = '大连老张旧房改造'
    $title = '老房水电改造'
    New-TextFile (ChildPath $source '口播' 'a.txt') 'v1'
    New-TextFile (ChildPath $source 'B-roll' 'b.txt') 'b'
    $first = Invoke-Footage $work @('-Client', $client, '-Title', $title, '-Source', $source, '-InboxRoot', $inbox)
    Assert-That ($first.ExitCode -eq 0) $first.StdErr
    $dest = Join-Path (Join-Path $inbox $client) $title
    $manifestBefore = [System.IO.File]::ReadAllText((Join-Path $dest 'manifest.json'), $utf8)
    New-TextFile (ChildPath $source '口播' 'a.txt') 'v2'
    $second = Invoke-Footage $work @('-Client', $client, '-Title', $title, '-Source', $source, '-InboxRoot', $inbox)
    Assert-That ($second.ExitCode -eq 1) "expected failure`n$($second.StdOut)"
    Assert-That ($second.StdErr.Contains('失败：目标里已有内容不同的文件')) $second.StdErr
    Assert-That ($second.StdErr.Contains('口播/a.txt')) $second.StdErr
    Assert-That ($second.StdErr.Contains('-Force')) $second.StdErr
    Assert-That ($second.StdErr.Contains('下一步：')) $second.StdErr
    Assert-That ($second.StdOut -notmatch '嘉豪') $second.StdOut
    Assert-That ($second.StdErr -notmatch 'copy-footage\.ps1:') $second.StdErr
    Assert-That ((Get-Content -LiteralPath (ChildPath $dest '口播' 'a.txt') -Raw) -eq 'v1') 'file changed'
    Assert-That ((Get-Content -LiteralPath (ChildPath $dest 'B-roll' 'b.txt') -Raw) -eq 'b') 'other file changed'
    Assert-That ($manifestBefore -eq [System.IO.File]::ReadAllText((Join-Path $dest 'manifest.json'), $utf8)) 'manifest rewritten'
    $forced = Invoke-Footage $work @('-Client', $client, '-Title', $title, '-Source', $source, '-InboxRoot', $inbox, '-Force')
    Assert-That ($forced.ExitCode -eq 0) $forced.StdErr
    Assert-That ($forced.StdOut.Contains('覆盖 1 个')) $forced.StdOut
    Assert-That ((Get-Content -LiteralPath (ChildPath $dest '口播' 'a.txt') -Raw) -eq 'v2') 'force did not replace'
    $manifest = Read-Manifest (Join-Path $dest 'manifest.json')
    $forcedHash = @($manifest.files | Where-Object { $_.path -eq 'a.txt' } | ForEach-Object { $_.sha256 })
    Assert-That ($forcedHash[0] -eq (Get-Sha256Text (ChildPath $dest '口播' 'a.txt'))) 'force hash'
  }

  Invoke-Test 'missing source' {
    $work = Join-Path $root 'missing'
    $inbox = Join-Path $work 'inbox'
    $missing = Join-Path $work 'does-not-exist'
    New-Item -ItemType Directory -Path $work | Out-Null
    $result = Invoke-Footage $work @(
      '-Client', '徐州陈茹一站式建材仓库', '-Title', '仓库开业口播', '-Source', $missing, '-InboxRoot', $inbox
    )
    Assert-That ($result.ExitCode -eq 1) $result.StdOut
    Assert-That ($result.StdErr.Contains('失败：来源目录不存在：')) $result.StdErr
    Assert-That ($result.StdErr.Contains($missing)) $result.StdErr
    Assert-That ($result.StdErr.Contains('下一步：')) $result.StdErr
    Assert-That ($result.StdOut -notmatch '本地收件箱') $result.StdOut
    Assert-That ($result.StdOut -notmatch '嘉豪') $result.StdOut
    Assert-That (-not (Test-Path -LiteralPath $inbox)) 'inbox was created'
  }

  Invoke-Test 'source is a file' {
    $work = Join-Path $root 'source-file'
    $inbox = Join-Path $work 'inbox'
    $file = Join-Path $work 'clip.txt'
    New-TextFile $file 'x'
    $result = Invoke-Footage $work @(
      '-Client', '大连老张旧房改造', '-Title', '老房水电改造', '-Source', $file, '-InboxRoot', $inbox
    )
    Assert-That ($result.ExitCode -eq 1) $result.StdOut
    Assert-That ($result.StdErr.Contains('来源不是文件夹')) $result.StdErr
    Assert-That (-not (Test-Path -LiteralPath $inbox)) 'inbox was created for a file source'
  }

  Invoke-Test 'unclassified files' {
    $work = Join-Path $root 'loose'
    $source = Join-Path $work 'source'
    $inbox = Join-Path $work 'inbox'
    New-TextFile (ChildPath $source '口播' 'ok.txt') 'ok'
    New-TextFile (Join-Path $source 'loose.txt') 'loose'
    New-TextFile (ChildPath $source '其他' 'x.txt') 'x'
    $result = Invoke-Footage $work @(
      '-Client', '徐州陈茹一站式建材仓库', '-Title', '无法归类', '-Source', $source, '-InboxRoot', $inbox
    )
    Assert-That ($result.ExitCode -eq 1) $result.StdOut
    Assert-That ($result.StdErr.Contains('无法归类')) $result.StdErr
    Assert-That ($result.StdErr.Contains('loose.txt')) $result.StdErr
    Assert-That ($result.StdErr.Contains('其他/x.txt')) $result.StdErr
    Assert-That ($result.StdErr.Contains('下一步：')) $result.StdErr
    Assert-That ($result.StdOut -notmatch '嘉豪') $result.StdOut
    Assert-That (-not (Test-Path -LiteralPath $inbox)) 'copied despite loose files'
  }

  Invoke-Test 'english aliases and template' {
    $work = Join-Path $root 'alias'
    $source = Join-Path $work 'source'
    $inbox = Join-Path $work 'inbox'
    New-TextFile (ChildPath $source 'A-Roll' 'a.txt') 'a'
    New-TextFile (ChildPath $source 'broll' 'b.txt') 'b'
    New-TextFile (ChildPath $source 'reference' 'c.txt') 'c'
    $client = '大连老张旧房改造'
    $title = '英文目录名'
    $result = Invoke-Footage $work @('-Client', $client, '-Title', $title, '-Source', $source, '-InboxRoot', $inbox)
    Assert-That ($result.ExitCode -eq 0) "$($result.StdErr)`n$($result.StdOut)"
    $dest = Join-Path (Join-Path $inbox $client) $title
    Assert-That ((Get-Content -LiteralPath (ChildPath $dest '口播' 'a.txt') -Raw) -eq 'a') 'alias aroll'
    Assert-That ((Get-Content -LiteralPath (ChildPath $dest 'B-roll' 'b.txt') -Raw) -eq 'b') 'alias broll'
    Assert-That ((Get-Content -LiteralPath (ChildPath $dest '对标' 'c.txt') -Raw) -eq 'c') 'alias reference'
    $shot = [System.IO.File]::ReadAllText((Join-Path $dest '拍摄清单.md'), $utf8)
    $template = [System.IO.File]::ReadAllText($script:Template, $utf8)
    Assert-That ($shot -eq $template) 'template was not copied'
    $manifest = Read-Manifest (Join-Path $dest 'manifest.json')
    Assert-That ($manifest.present.'拍摄清单.md' -eq $true) 'template not present'
  }

  Invoke-Test 'explicit folders override source aliases' {
    $work = Join-Path $root 'explicit'
    $source = Join-Path $work 'source'
    $outside = Join-Path $work 'outside-aroll'
    $inbox = Join-Path $work 'inbox'
    New-TextFile (ChildPath $source '口播' 'ignored.txt') 'ignored'
    New-TextFile (ChildPath $source 'B-roll' 'from-source.txt') 'from-source'
    New-TextFile (Join-Path $outside 'from-explicit.txt') 'from-explicit'
    $client = '徐州陈茹一站式建材仓库'
    $title = '显式目录'
    $result = Invoke-Footage $work @(
      '-Client', $client, '-Title', $title, '-Source', $source, '-InboxRoot', $inbox, '-ARoll', $outside
    )
    Assert-That ($result.ExitCode -eq 0) "$($result.StdErr)`n$($result.StdOut)"
    $dest = Join-Path (Join-Path $inbox $client) $title
    Assert-That ((Get-Content -LiteralPath (ChildPath $dest '口播' 'from-explicit.txt') -Raw) -eq 'from-explicit') 'explicit aroll'
    Assert-That (-not (Test-Path -LiteralPath (ChildPath $dest '口播' 'ignored.txt'))) 'source aroll was also copied'
    Assert-That ((Get-Content -LiteralPath (ChildPath $dest 'B-roll' 'from-source.txt') -Raw) -eq 'from-source') 'source broll'
    Assert-That (Test-Path -LiteralPath (Join-Path $dest '对标')) 'empty reference dir'
    $manifest = Read-Manifest (Join-Path $dest 'manifest.json')
    Assert-That ($manifest.present.'对标' -eq $false) 'empty reference marked present'
    Assert-That ($manifest.fileCounts.'对标' -eq 0) 'reference count'
    Assert-That ($result.StdOut.Contains('请在聊天里告诉嘉豪复制这个文件夹（不要通过参谋长机器人传输）。')) $result.StdOut
  }
} finally {
  if (Test-Path -LiteralPath $root) {
    Remove-Item -LiteralPath $root -Recurse -Force
  }
}

if ($failures.Count -gt 0) {
  Write-Host "FAILED $($failures.Count)"
  exit 1
}
Write-Host 'OK'
exit 0
