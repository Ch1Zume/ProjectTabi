# ProjectTabi

<img src="assets/projecttabi_icon.png" width="128" alt="ProjectTabi 图标">

ProjectTabi 是一款面向 Windows 和 Android 的圣地巡礼规划与记录应用，提供作品与点位管理、地图探索、现场拍摄参考、巡礼记录和 WebDAV 多端同步。

- [下载更新包（GitHub Releases）](https://github.com/Ch1Zume/ProjectTabi/releases)
- [使用指南](docs/USAGE.md)
- [WebDAV 同步说明](docs/WEBDAV_SYNC.md)
- [参考图拍摄与画质](docs/CAMERA_QUALITY.md)
- [补丁记录](PATCH_NOTES.md)
- [反馈问题](https://github.com/Ch1Zume/ProjectTabi/issues)

## 平台与更新

Android 提供参考图拍摄，详细画质选项集中在“设置 → 拍摄设置”。Windows 提供计划、地图、记录查看和同步，不显示相机入口或拍摄设置。

每个 Release 提供 Windows 安装包和 Android APK。Windows 安装包支持覆盖更新；Android APK 使用固定的应用 ID 和发布签名，通过递增版本号安装更新。

从 0.1.1 构建 3 起，应用打开时会自动检查更新，也可进入“设置 → 关于 ProjectTabi → 应用更新”查看说明并下载。支持可选的仅 Wi-Fi 自动下载，安装前仍由用户确认。更早版本需先手动覆盖安装一次。

## 导入已有记录

如果记录已保存在 WebDAV 上，在 ProjectTabi 中连接相同的服务器、账号和文件夹，然后选择“云端 → 本地”导入记录。也可以导入 `.sjhplan` 计划包。首次导入前建议保留原始数据备份。

支持 WebDAV 计划清单、JSON 计划文件和 `.sjhplan` 计划包。导入和同步会保留计划、点位与巡礼记录的对应关系。

## 同步

同步页只保留 WebDAV 连接设置。每次同步前，应用会显示本地和云端更新时间、计划数与记录数，并要求选择：

- **本地 → 云端**：以本地全部计划和记录覆盖云端。
- **云端 → 本地**：以云端全部计划和记录覆盖本地。

同步历史按 WebDAV 账号保存开始时间、完成时间、方向、结果和简要数量。失败时会显示停止阶段、具体原因、建议操作、两端数据状态及错误代码，可复制反馈。

参考图和记录图片按 SHA-256 内容去重。重复同步会核对已有文件，不会仅因参考图缓存路径而反复上传。

## 构建与发布

需要 Flutter、Android SDK/JDK、Node.js 和 Rust。获取依赖：

```bash
flutter pub get
npm ci
```

Windows 桌面安装包：

```bash
npm run desktop:build
```

Android APK：

```bash
flutter build apk --release --no-pub
```

正式 Android 发布需要在 GitHub Actions Secrets 配置持久签名：

```text
ANDROID_KEYSTORE_BASE64
ANDROID_KEYSTORE_PASSWORD
ANDROID_KEY_ALIAS
ANDROID_KEY_PASSWORD
```

签名文件不能提交到仓库；请离线备份同一份私钥。Android 更新要求应用 ID 不变、签名相同且 versionCode 递增。通过发布 `vX.Y.Z` 标签构建 Release；工作流会检查 Android 包身份和签名，并发布 Windows 安装包与 Android APK。每次修复和更新应补记到 [PATCH_NOTES.md](PATCH_NOTES.md)。

## 致谢与许可

ProjectTabi 在 [MiriaGo](https://github.com/BilyHurington/MiriaGo) 项目的 MIT 许可代码基础上独立开发，并保留原作者版权声明。详见 [LICENSE](LICENSE)。
