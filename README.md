# ProjectTabi

ProjectTabi 是一款面向 Windows 和 Android 的圣地巡礼计划与记录应用，支持作品点位、地图、拍摄参考、巡礼记录和 WebDAV 多端同步。

- [下载更新包（GitHub Releases）](https://github.com/Ch1Zume/ProjectTabi/releases)
- [使用指南](docs/USAGE.md)
- [WebDAV 同步说明](docs/WEBDAV_SYNC.md)
- [参考图拍摄与画质](docs/CAMERA_QUALITY.md)
- [补丁记录](PATCH_NOTES.md)
- [反馈问题](https://github.com/Ch1Zume/ProjectTabi/issues)

## 平台与更新

每个 Release 提供 Windows NSIS 安装包（`*-windows-setup.exe`）和 Android APK。Windows 安装包用于安装和后续覆盖更新；Android APK 使用固定的应用 ID 和发布签名，未来版本以递增版本号安装更新。

从 0.1.1 构建 3 起，打开应用会自动检查更新，也可进入“设置 → 关于 ProjectTabi → 应用更新”查看更新说明、下载安装包。支持可选的仅 Wi-Fi 自动下载，安装前仍由用户确认。已安装更早构建的用户需先手动覆盖安装一次。

ProjectTabi 是独立的新应用，第一次安装时不会覆盖 MiriaGo。Android 使用新的应用 ID，因此需要单独安装；Windows 也使用 ProjectTabi 的新数据目录。后续 ProjectTabi 更新沿用自己的安装身份和签名。

## 从 MiriaGo 迁移数据

ProjectTabi 保留 MiriaGo 的计划包和 WebDAV 数据格式：

1. 在 MiriaGo WebSync 中确认数据已成功上传到 WebDAV 的默认文件夹 `MiriaGoSync`。
2. 安装 ProjectTabi，填写相同的 WebDAV 地址、账号、应用密码和同步文件夹。
3. 查看本地与云端更新时间后，选择“云端 → 本地”导入现有记录。

云端同步会用选定的一侧完整覆盖另一侧。刚安装的 ProjectTabi 通常应选择“云端 → 本地”。也可以导入旧版 `.sjhplan` 计划包。导入前请保留一份原始备份。

兼容格式包括 `miriago-webdav` v1 云端清单、MiriaGo JSON 计划文件及 `.sjhplan` v2 计划包；既有云端目录和文件名保持不变。

## 同步

同步页只保留 WebDAV 连接设置。每次同步前，应用会显示本地和云端更新时间、计划数与记录数，并要求选择：

- **本地 → 云端**：以本地全部计划和记录覆盖云端。
- **云端 → 本地**：以云端全部计划和记录覆盖本地。

同步历史按 WebDAV 账号保存开始时间、完成时间、方向、结果和简要数量。失败时会显示停止阶段、具体原因、建议操作、两端数据状态及错误代码，可复制反馈。

参考图和记录图片按 SHA-256 内容去重。图片使用内容哈希文件名；重复同步会核对已有对象，不会仅因参考图缓存路径而反复上传。

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

## 项目来源与许可

本项目以 [BilyHurington/MiriaGo](https://github.com/BilyHurington/MiriaGo) 的 MIT 许可代码为基础独立开发。保留原 MIT 许可及版权声明，详见 [LICENSE](LICENSE)。
