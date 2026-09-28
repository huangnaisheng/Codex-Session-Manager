# Codex 会话管理器

一个 PowerShell 小工具，用会话标题查找 Codex CLI 的本地会话，并通过 Codex 官方删除命令安全清理。

## 功能

- 扫描 `%USERPROFILE%\.codex\sessions` 下的 `.jsonl` 会话文件。
- 提取第一条用户消息作为可读标题。
- 显示标题、最后修改时间和会话 UUID 的对应关系。
- 使用关键词筛选会话。
- 删除前显示完整目标，并要求输入 `DELETE` 确认。
- 通过 `codex delete <UUID> --force` 删除，不直接修改会话文件。

## 使用

在 PowerShell 中进入项目目录：

```powershell
Set-Location 'D:\Study\codex\会话管理器'
```

只查看全部会话：

```powershell
.\codex-session-cleaner.ps1
```

按标题关键词筛选：

```powershell
.\codex-session-cleaner.ps1 -Query '只回复 ok'
```

进入删除模式：

```powershell
.\codex-session-cleaner.ps1 -Query '只回复 ok' -Delete
```

脚本显示编号后，输入单个编号、逗号分隔的多个编号，或 `all`。随后输入大写 `DELETE` 才会继续删除。

强制删除模式适合自动化使用：

```powershell
.\codex-session-cleaner.ps1 -Query '测试会话' -Delete -Force
```

指定其他 Codex 数据目录：

```powershell
.\codex-session-cleaner.ps1 -CodexHome 'C:\另一个用户\.codex'
```

## 要求

- Windows PowerShell 5.1 或 PowerShell 7+
- Codex CLI 已安装，并且 `codex` 命令可用

## 安全说明

`codex delete` 是永久删除操作。默认情况下脚本只读；删除模式会再次列出目标并要求确认。请在删除前核对编号、标题和 UUID。

## 许可证

MIT License，见 [LICENSE](LICENSE)。
