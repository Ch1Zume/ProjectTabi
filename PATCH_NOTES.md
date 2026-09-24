# ProjectTabi 补丁记录

## 0.1.0 — 初始独立版本

- 从 MiriaGo WebSync 拆分为独立的 ProjectTabi，确立新的 Android 与 Windows 应用身份。
- 添加 Windows NSIS 安装包和 Android APK 的 Release 流程，后续版本通过安装包更新。
- 简化 WebDAV 页面，只提供云端连接设置；每次同步前选择“本地 → 云端”或“云端 → 本地”，并显示两端更新时间。
- 记录每次同步的起止时间、方向、结果和图片传输摘要；失败信息包含阶段、原因、处理建议和错误代码。
- 保留 MiriaGo 的 `miriago-webdav` v1 云端清单、`MiriaGoSync` 默认目录、JSON 计划文件及 `.sjhplan` v2 数据包，便于迁移既有记录。
- 延续 WebSync 中的 Android 图片路径读取修复；参考图按内容哈希识别和去重，避免缓存路径导致重复传输。

后续每次 Release 在本文件新增版本条目，记录遇到的问题及对应修复。