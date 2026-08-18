# mosh-client 构建配方（GPL 对应源码说明）

Livis APK 打包的 `libmoshclient.so` 是未经源码修改的 [mosh](https://github.com/mobile-shell/mosh)（GPLv3）
mosh-client，以独立进程方式由 App exec 运行。按 GPLv3 要求，此处提供其对应源码获取方式与完整构建配方。

## 源码

- 上游：https://github.com/mobile-shell/mosh （mosh 1.4.0，未修改）
- 构建环境：[termux-packages](https://github.com/termux/termux-packages) 的 `mosh` 包构建脚本

## 构建步骤

1. 使用 termux-packages 构建 Android arm64 版 mosh：

   ```sh
   git clone https://github.com/termux/termux-packages
   cd termux-packages
   ./build-package.sh -a aarch64 mosh
   ```

2. 提取 `mosh-client` 及其依赖库（openssl、ncursesw、zlib、abseil、protobuf、
   libandroid-support、libc++_shared、libutf8_validity）。

3. 用 patchelf 将带版本号的依赖名改写为无版本名，并将全部文件重命名为
   `lib*.so`（Android 10+ 仅 `nativeLibraryDir` 允许 exec，且只有 `lib*.so`
   会被解压到该目录）。需同时改写 NEEDED、VERNEED、SONAME 三处：

   ```sh
   patchelf --replace-needed libssl.so.3 libssl.so ...
   patchelf --set-soname libmoshclient.so mosh-client
   ```

对二进制逐字节复现有疑问、或需要构建脚本原件，请开 Issue 索取。
