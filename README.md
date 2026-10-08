# ChatGPT 会话按标题批量删除

一个独立运行的 Windows PowerShell 5.1 脚本，通过 Chrome 的 Windows UI Automation 控制 ChatGPT 中文界面。它使用浏览器现有的登录状态，不需要密码、Cookie、API Key 或第三方依赖。

**删除不可撤销。** 脚本只按完整标题匹配；执行前会扫描整个普通聊天侧边栏。默认每次点击“删除聊天”后等待至少 10 秒，再等待确认框关闭，然后处理下一条。默认不逐条核验会话是否从列表消失，因此日志中的“已提交”不能当作服务器已删除的证明。

## 快速开始

1. 在 Chrome 登录 `chatgpt.com`，展开聊天侧边栏，保持 Windows 解锁。运行期间不要操作这个 Chrome 窗口。
2. 复制 `titles.example.txt` 为本地 `titles.txt`，把示例内容全部替换成待删会话的**完整标题**，每行一条，保存为 UTF-8。`titles.txt` 已被 Git 忽略。
3. 双击 `run-check.cmd` 做只读扫描。核对输出中的 `Ready`、`NotFound`、`Ambiguous`。
4. 确认清单后双击 `run-delete.cmd` 执行。也可以将自己的 TXT 文件拖到这两个 CMD 文件上。

命令行用法：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\chatgpt-bulk-delete.ps1 -ListPath .\titles.txt
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\chatgpt-bulk-delete.ps1 -ListPath .\titles.txt -Execute
```

脚本不会因 `NotFound` 改用相似标题；同名多条会话会阻止整批开始。输入去重只影响重复的清单行，不会放宽标题匹配。

## 执行与恢复

运行记录写入 `runs/<运行编号>/`：`manifest.json` 记录输入指纹和参数，`plan.json` 记录扫描结果，`events.jsonl` 记录各步事件，`results.json` 在本轮结束时记录结果。`runs/` 和本地标题文件不应上传到 GitHub。

- `SubmittedWithoutVerification`：确认框已关闭，未核验删除结果。
- `SubmissionUnconfirmed`：确认框超时且可取消；脚本取消后跳过该条。
- `DeletedAndVerified`：仅显式启用 `-VerifyDeletion` 时可能出现。
- `NotFound`：完整扫描中未找到标题。已删除的标题也会得到这个状态。
- `Stopped`：界面身份、焦点或其他安全条件变化，本轮停止；重新运行会重新扫描，而不是盲目沿用旧行身份。

默认至少等待 10 秒，若确认框仍在，会再等最多 60 秒；请求尚在处理时“取消”按钮可能被禁用。可用 `-WaitSeconds 15` 增加初始等待，或用 `-TimeoutSeconds 90` 增加后续等待。若确实需要旧版逐条核验，可显式加 `-VerifyDeletion`。大批量运行结束后，可再执行一次 `run-check.cmd` 做只读总检查。

退出码 `0` 表示本轮处理完毕且没有未找到或未确认项；`1` 表示中途停止；`2` 表示有 `NotFound` 或未确认项。因已删除标题通常为 `NotFound`，检查命令的退出码 `2` 不一定代表故障，应查看 `plan.json`。

## 适用范围

当前代码面向 Windows、Chrome 和 ChatGPT 中文界面中的普通聊天侧边栏，也处理侧边栏可见的项目会话；不扫描归档会话。脚本不读取聊天正文。页面控件名称、加载方式或 Chrome 无障碍树改变时，脚本可能停止，需要重新适配。多个 ChatGPT Chrome 窗口同时存在时，可用 `-WindowHandle` 指定窗口。

## 文件

| 文件 | 用途 |
| --- | --- |
| `chatgpt-bulk-delete.ps1` | Chrome UI Automation、扫描、删除和日志主流程 |
| `ChatDelete.Core.psm1` | UTF-8 清单读取、精确匹配和 URL/确认文字校验 |
| `run-check.cmd` / `run-delete.cmd` | Windows 双击入口 |
| `titles.example.txt` | 虚构标题示例；真实清单只放在本地 |
| `tests/` | 不操作浏览器的回归测试 |
| `docs/LESSONS_LEARNED.md` | 实际问题、修复依据和后续优化 |

运行测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-core.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\test-workflow.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\test-history.ps1
```

`tests/test-core.ps1` 会生成本地测试夹具，已由 `.gitignore` 排除。发布仓库前请检查 `git status`，确保真实标题、运行日志和浏览器信息没有进入暂存区。这个发布目录不含私人运行数据；开源许可证由仓库所有者自行选择。
