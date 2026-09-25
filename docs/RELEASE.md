# 发布与应用更新

## 新版本发布

1. 更新 pubspec.yaml 中的版本，例如从 0.1.2+4 改为 0.1.3+5。+ 前的部分用于版本名称，+ 后面的整数是 Android versionCode，每次 Android 更新必须递增。
2. 将 lib/app_version.dart、src-tauri/Cargo.toml 和 src-tauri/tauri.conf.json 改为相同的完整版本，例如 0.1.3+5，并更新 Cargo.lock 与 iOS 构建号。
3. 将 PATCH_NOTES.md 中的待发布内容归入新版本，并补上本次问题与修复。
4. 提交变更、推送，并创建匹配版本的 Git 标签，例如 v0.1.3；同一版本的补充构建使用 v0.1.2-build.5，保留已发布标签及其安装包。
5. GitHub Actions 检查 Android 包身份和签名，构建 Windows setup.exe、Android APK 与 Windows .sig，然后根据实际文件生成 latest.json。正式发布后 latest/download/latest.json 自动指向新构建。

设置页“关于 ProjectTabi → 应用更新”提供自动检查、更新说明、下载进度、取消、重试和安装；“手动下载”保留 GitHub Releases 入口。应用打开时每天最多自动检查一次；自动下载默认关闭，开启后仅 Wi-Fi 下载。Windows 在应用打开期间下载，关闭后需要重新下载；Android 下载由系统管理，可在后台继续并恢复进度。下载完成不会自行终止拍摄或同步。

Android 安装前校验 SHA-256、文件大小、包名、版本号和签名，首次需要允许 ProjectTabi 安装应用，返回后再次点击安装。Windows 用 Tauri 更新公钥校验下载内容，点击安装后退出应用并由安装程序重启。记录写入或同步期间会提示稍后安装。

Windows 发布需配置 TAURI_SIGNING_PRIVATE_KEY 与 TAURI_SIGNING_PRIVATE_KEY_PASSWORD 两个 Secrets。本机备份在 .signing/，已被 Git 忽略。公钥固定在 tauri.conf.json；不要替换长期签名密钥。未来同版本构建必须递增 + 后的数字，更新器会同时比较版本名和构建号。

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
