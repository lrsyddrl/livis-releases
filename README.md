# Livis

**Livis** — 在手机上盯着自己主机上跑的编码 agent。Android 远程终端，自托管，无中心服务器。

官网：<https://livis.fastaibest.xyz>

## 下载

APK 见本仓库 [Releases](https://github.com/lrsyddrl/livis-releases/releases) 页面，下载 `livis-v*.apk` 直接安装。

- 支持 Android 10+（arm64）
- 主机侧守护进程 `openhook`（Linux/macOS，amd64/arm64）随 Release 附带，配合 `install.sh` 使用
- APK 由 GitHub Actions 用固定的正式密钥签名，可直接覆盖升级；装过其它签名的版本需先卸载

## 授权

Livis 为付费软件，启动后需输入授权码激活。套餐与购买方式见[官网](https://livis.fastaibest.xyz/#pricing)。

## 许可

自 v1.3.0 起，Livis 为**专有软件**，本仓库仅用于分发官方构建。

- 历史版本（≤ v1.2.x）曾以 GPLv3 发布，已获取这些版本的用户的权利不受影响。
- APK 中打包的 `mosh-client`（GPLv3）以独立进程运行，属于聚合分发；其对应源码与构建配方见 [`mosh-build/`](mosh-build/)。
- 第三方组件的许可声明见随 APK 提供的应用内「开源许可」页，包含 Terminal Emulator for Android（Apache 2.0）等。

## 商标

**Livis 名称与图标不授予任何第三方使用**。任何基于历史 GPLv3 版本的 fork 不得使用 Livis 名称、图标或与官方构建混淆的标识发布。

## 问题反馈

Bug 与功能建议请开 [Issue](https://github.com/lrsyddrl/livis-releases/issues)。
