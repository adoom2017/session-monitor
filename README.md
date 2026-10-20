# SessionMonitor

## 使用说明

SessionMonitor 是 macOS 14 及以上版本的悬浮窗与菜单栏应用，用于查看 Claude Code 和 Codex 会话状态。

### 安装与接入

1. 将 `SessionMonitor.app` 放入 `/Applications`，然后启动。
2. 点击菜单栏图标 → **设置…** → **集成**，为需要监控的 Claude Code 或 Codex 点击 **安装**。
3. 使用 Codex 时，在 Codex 会话中输入 `/hooks`，批准 SessionMonitor 的条目；安装后重启已打开的 Codex 会话。
4. 允许系统通知。需要调整权限时，打开 **系统设置 → 通知 → SessionMonitor**。

安装 hook 会保留其他工具的配置，并在修改前备份到 `~/.session-monitor/backups/`。App 更新后会自动同步已安装的 hook 程序。

### 查看与操作会话

- 按 **⌥⌘S** 显示或隐藏悬浮窗；点击胶囊展开会话列表。
- 绿色表示工作中，蓝色表示完成未读，橙色表示需要授权，黄色表示等待输入，灰色表示空闲。
- 点击会话跳转到对应终端，并标记为已读；右键菜单可复制工作目录、复制会话 ID 或移除会话。
- 菜单栏提供全部已读、开机启动、设置、查看日志和退出。
- 在设置中分别开启或关闭授权、输入和完成通知。

tmux 会话可定位到对应窗格；使用该功能需要安装 tmux。首次切换终端标签页时，按系统提示允许自动化权限。无法完成跳转时，应用会显示错误并复制会话工作目录。

### 卸载

在 **设置… → 集成** 中卸载相应 hook。

卸载 hook 会保留其他工具的配置与备份。移除应用前，先关闭开机启动、卸载 hook、退出应用，再删除 `SessionMonitor.app`。

## 编译与打包说明

### 编译环境

- macOS 14 或以上版本。
- Xcode，包含 Swift 6、macOS SDK 和资源编译工具 `actool`。

以下命令均在项目根目录执行。

### 本地编译

```bash
scripts/build-app.sh
open build/SessionMonitor.app
```

产物为 `build/SessionMonitor.app`，包含应用和 `sm-hook`，默认使用 ad-hoc 签名。

同时构建 Apple Silicon 与 Intel 版本：

```bash
UNIVERSAL=1 scripts/build-app.sh
```

### 发布打包

准备 Developer ID Application 签名证书，并将公证凭据保存到钥匙串。将示例占位符替换为自己的 Apple ID 和 Team ID：

```bash
xcrun notarytool store-credentials sessionmonitor-notary \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID"
```

构建、签名、公证并生成 ZIP 和 DMG：

```bash
scripts/package-release.sh \
  --version 1.0.0 \
  --universal \
  --notary-profile sessionmonitor-notary
```

产物位于 `dist/`：

- `SessionMonitor.app`
- `SessionMonitor-1.0.0.zip`
- `SessionMonitor-1.0.0.dmg`

脚本默认选择钥匙串中唯一的 Developer ID Application 证书；有多个证书时，用 `--identity "签名身份名称"` 指定。`--build` 设置构建号，`--no-dmg` 仅生成 ZIP。省略 `--notary-profile` 时只签名，不提交公证。

### 发布到 GitHub

打包并公证后发布：

```bash
scripts/publish-release.sh 1.1.3
```

或者一步完成打包、公证和发布：

```bash
scripts/publish-release.sh 1.1.4 --build sessionmonitor-notary
```

脚本发布前会检查：工作区干净且已推送；`dist/` 里有对应版本的 DMG 和 zip；zip 里的 App 版本号正确；DMG 和 App 都已公证并能通过 Gatekeeper。任何一项不满足都会停止。检查通过后，给 HEAD 打 `v<版本>` 标签并推送，再创建 Release，上传 DMG 和 zip，附安装说明和 SHA-256。`--notes 文件` 用自定义说明，`--draft` 创建草稿。
