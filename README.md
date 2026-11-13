# 素材收件箱

杨磊拍完短片后，用这个脚本把本机素材整理成固定目录。嘉豪只从机器人上的对应路径读片。

脚本只在本机复制文件。失败就停，只说明一次下一步。不会循环重试，不会上传到 ChatCut，也不会调用付费接口。

## 整理成什么样

`-InboxRoot` 默认是当前目录下的 `customers-footage`：

```
customers-footage/<客户名>/<片名>/
  口播/
  B-roll/
  对标/
  拍摄清单.md
  manifest.json
```

机器人上的对应路径：

```
/workspace/客户片/<客户名>/<片名>/
```

`对标` 可以没有文件。`manifest.json` 记录客户、片名、三类文件的数量、每个文件的 SHA256，以及 `拍摄清单.md`、`口播`、`B-roll`、`对标` 是否有内容。

## 怎么运行

在本仓库目录打开 PowerShell：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\copy-footage.ps1 -Client '徐州陈茹一站式建材仓库' -Title '仓库开业口播' -Source 'D:\拍好的素材'
```

`./copy-footage.ps1` 就是这个文件。执行策略拦住脚本时，用上面的 `-ExecutionPolicy Bypass` 写法。

来源文件夹里如果已经分好了子目录，会自动对应：

| 来源子目录 | 放进 |
| --- | --- |
| `口播`、`aroll`、`a-roll`、`a_roll` | `口播` |
| `B-roll`、`broll`、`b_roll` | `B-roll` |
| `对标`、`reference` | `对标` |

来源根目录的 `拍摄清单.md` 会一并复制。没有这份文件时，收件箱里会放上 `templates/拍摄清单.md`。收件箱里已经有清单时，不会用模板覆盖。

也可以直接指定目录。显式参数优先于来源里的同名子目录：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\copy-footage.ps1 -Client '大连老张旧房改造' -Title '老房水电改造' -ARoll 'D:\老张\口播' -BRoll 'D:\老张\空镜' -Reference 'D:\老张\对标'
```

来源里对不上号、又没有被这些参数接住的文件，脚本会停下来列出文件。它不会猜这些文件属于哪一类，也不会停在那里等键盘输入。

相同内容（SHA256 一样）会跳过。目标里已有不同内容的同名文件时，不加 `-Force` 就整次停止，一个都不覆盖。脚本不会删除收件箱里多出来的旧文件。来源根目录的 `manifest.json`，以及 `desktop.ini`、`Thumbs.db`、`.DS_Store` 会略过。

## 两个客户的例子

徐州陈茹一站式建材仓库：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\copy-footage.ps1 -Client '徐州陈茹一站式建材仓库' -Title '仓库开业口播' -Source 'D:\拍好的素材' -InboxRoot 'D:\customers-footage'
```

大连老张旧房改造：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\copy-footage.ps1 -Client '大连老张旧房改造' -Title '老房水电改造' -Source 'D:\老张\第三集' -InboxRoot 'D:\customers-footage'
```

## 成功

成功时会打印：

```
本地收件箱：D:\customers-footage\大连老张旧房改造\老房水电改造
机器人路径：/workspace/客户片/大连老张旧房改造/老房水电改造/
请在聊天里告诉嘉豪复制这个文件夹（不要通过参谋长机器人传输）。
复制 4 个，跳过相同 0 个，覆盖 0 个。
```

把机器人路径发给嘉豪，让嘉豪复制这个文件夹。传片走这一条，不要交给参谋长机器人转发。

## 失败

失败时退出码是 1，不会打印成功那几行。看完提示改一次再运行。

来源路径不存在：

```
失败：来源目录不存在：D:\拍好的素材
下一步：核对 -Source 路径。改对之后只再运行一次，不要循环重试。
```

片子直接堆在来源根目录，脚本不知道该放进哪一类：

```
失败：有 2 个文件无法归类，已停止，没有复制。
  - 口播成片.mp4
  - 空镜.mp4
下一步：把文件放进子目录 口播、B-roll 或 对标（也认 aroll、broll、reference），或加上 -ARoll、-BRoll、-Reference。本脚本不会猜测，也不会重试。
```

收件箱里已经有一份不同的文件：

```
失败：目标里已有内容不同的文件，已停止，没有覆盖。
  - 口播/开场.mp4
下一步：确认可以替换后，加上 -Force 再运行一次；或者换一个 -Title。不要反复重试同一条命令。
```

## 测试

测试只用几十字节的文本文件，不带真实视频。

```powershell
pwsh -NoProfile -File .\tests\run-tests.ps1
```

没有 PowerShell 7 时：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

## 边界

- 素材只留在本机收件箱。真实拍摄文件不要提交进 git。
- 传给嘉豪的是机器人路径，由嘉豪复制文件夹。
- 失败后按提示改好，再运行一次。
