# 发布与应用更新

## 新版本发布

1. 更新 pubspec.yaml 中的版本，例如从 0.1.0+1 改为 0.1.1+2。点号前的部分用于版本名称，+ 后面的整数是 Android versionCode，每次 Android 更新必须递增。
2. 将 src-tauri/Cargo.toml 和 src-tauri/tauri.conf.json 的版本改为相同的版本名称，例如 0.1.1。
3. 将 PATCH_NOTES.md 中的待发布内容归入新版本，并补上本次问题与修复。
4. 提交变更、推送，并创建匹配版本的 Git 标签，例如 v0.1.1。
5. GitHub Actions 检查 Android 包 ID、签名和版本号，然后构建并发布 ProjectTabi Windows setup.exe 与 Android APK。

设置页“关于 ProjectTabi → 下载更新包”会打开 GitHub Releases。Windows 用户运行新版安装包更新；Android 用户安装新版 APK。Android 只有在应用 ID 不变、签名密钥相同且 versionCode 递增时，才能覆盖安装。

## 首次配置 Android 签名

ProjectTabi 使用新的 Android 应用 ID 和自己的发布密钥，不继承 MiriaGo WebSync 的签名。首次发布前需要创建并备份一个长期使用的密钥：

    keytool -genkeypair -v -keystore projecttabi-release.jks -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias projecttabi

命令会提示设置 keystore 密码、key 密码和证书信息。密钥创建后，在 GitHub 仓库的 Settings → Secrets and variables → Actions 添加以下 secrets：

- ANDROID_KEYSTORE_BASE64：keystore 文件的 Base64 内容。PowerShell 可用 [Convert]::ToBase64String([IO.File]::ReadAllBytes('projecttabi-release.jks')) 生成。
- ANDROID_KEYSTORE_PASSWORD：keystore 密码。
- ANDROID_KEY_ALIAS：上面的别名，示例为 projecttabi。
- ANDROID_KEY_PASSWORD：该别名的 key 密码。

不要将密钥文件或密码提交到仓库。请在离线安全位置保留 keystore 文件、两种密码和 alias 的副本。签名密钥丢失后，Android 不允许用新密钥覆盖已安装的 ProjectTabi。

首次成功发布后，工作流会将当前 Android 包与上一版 Release 比较，确保使用同一签名和递增的 versionCode。初始发布没有上一版时，只检查新包的签名和应用 ID。
