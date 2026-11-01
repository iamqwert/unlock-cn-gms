# Unlock CN GMS

The GMS is restricted in China on some devices, because of configuration files that declare `cn.google.services` feature.
By this restriction, you can not enable `Google Location History` and the `Google Map Timeline` function can not use either.

This module removes the restriction by replacing these configuration files. It scans `etc/permissions` and `etc/sysconfig` on `/system`, `/system_ext`, `/product`, `/vendor`, `/odm` and vendor-specific `/my_*` partitions, and patches every file that declares the features above.

部分国行手机，或者本地化后的 ROM 中有内置 GMS ，但是某些功能无法使用，比如无法开启 `Google Location History` 服务，无法使用 `Google Map Timeline`，设备无法在 Web 版 Google play 中显示等等。

该模块通过查找并替换所有声明了 `cn.google.services` 的权限配置文件, 具体为删除如下配置行：

```xml
<feature name="cn.google.services" />
<feature name="com.google.android.feature.services_updater" />
```

以此来实现去除国行 GMS 的限制。

## 实测记录

测试设备：Redmi K90 Pro Max（25102RKBEC），HyperOS 4 / Android 17，KernelSU。

| 项目 | 禁用模块（原始 ROM） | 启用 v3.9 并重启后 |
| --- | --- | --- |
| `cn.google.services` | 存在 | 无 |
| `com.google.android.feature.services_updater` | 存在 | 无 |
| `cn.google` | 无 | 无 |
| `/product/etc/permissions/cn.google.services.xml` | 含两条 `<feature name="…" />` | 合法的空 `<permissions></permissions>` |
| `/odm/etc/permissions/com.gnss.bds_preference.xml` | 含 `<feature name="cn.google.services" />` | 合法的空 `<permissions></permissions>` |
| `/proc/mounts` 中的覆盖 | — | 后端未注入时才出现只读 bind mount（源在模块目录）；元模块或管理器已注入时不产生挂载项 |

启用后系统特征总数为 124 条，其中不含任何国行 GMS 特征。

验证命令：

```shell
adb shell pm list features | grep -E 'cn\.google|services_updater'   # 无输出即已清除
# 关键看 mountinfo 的 root 字段：bind mount 会把 /data/adb/modules/<id>/… 印在这里
adb shell "cat /proc/self/mountinfo | grep -E 'unlockcngms'"         # 装元模块时应为空
adb shell cat /proc/mounts | grep -E 'cn.google|bds_preference'      # 同上；没装元模块时才是两条
```

Play 商店 53.7.23（测试时为最新版）中判断国行标签的入口是 `hasSystemFeature("cn.google.services") && hasSystemFeature("com.google.android.feature.services_updater")`，上述特征清零后该判断恒为 `false`，与在商店进程里 Hook 得到的结果一致。测试时商店已是最新版，因此“检查更新”界面无法体现差异，需等 Google 发布新版本后自然验证。

## 注意事项

部分设备上可能同时存在多个配置文件（如小米 8e5 同时在 `/odm` 和 `/product` 分区下各有一个），本模块会扫描所有分区的 `etc/permissions`、`etc/sysconfig` 目录并处理全部匹配文件，不再依赖写死的文件名。

被处理的文件会复制到模块内，由 root 方案或元模块注入到系统路径。副本位置分两类：

- **`system/<分区>/…`**（`/system`、`/product`、`/vendor`、`/odm`、`/system_ext`）：所有后端都读得到；
- **模块根的 `<分区>/…`**（`/my_*` 这类私有分区，如 `my_product/`）：NoMount 直接扫模块根，Hybrid Mount / Magic Mount-rs 需要配置 `extra_mount` 才读，mountify 只扫 `system/`。**不放进 `system/` 是有意的**——Hybrid Mount 与 mountify 会把 `system/my_product/…` 挂到 `/system/my_product`（幻影目录），而不是 `/my_product`。

`post-fs-data.sh` 只在**确实没有别的注入手段**时才补一次只读 bind mount：

- 系统里只要有一个**启用的元模块**（[NoMount](https://github.com/maxsteeel/nomount)、[Hybrid Mount](https://github.com/Hybrid-Mount/meta-hybrid_mount)、[Magic Mount-rs](https://github.com/Tools-cx-app/meta-magic_mount-rs)、[mountify](https://github.com/backslashxx/mountify)），模块里的 `system/` 树**整体交给它**，自己不产生任何挂载。判据是 `/data/adb/modules/*/module.prop` 里的 `metamodule=1` / `metamodule=true`（与 KernelSU 的 `is_metamodule` 一致）且没有 `disable`/`remove` 标记，不绑死任何一家的模块目录名。这里不能用「读目标文件比内容」判断——元模块都在各模块的 `post-fs-data` **之后**才 mount（KernelSU 在 `metamount`，APatch 在 `post-mount`），按内容比较必然误判成「没注入」，把文件全挂上去；
- 模块根的分区目录按元模块的扫描面逐个判断（见下表），认得的交给它，认不得的交回本模块 bind；
- 应急开关：模块目录下存在 `.force-bind` 时恢复「全部自己挂」的老行为，用于元模块把本模块设成 `ignore`（如 Hybrid Mount 的 `[rules] default_mode = "ignore"`）或元模块自身故障时排查。

与各元模块的兼容性（已按各家源码核对）：

| 布局 | NoMount | Hybrid Mount | Magic Mount-rs | mountify | 管理器自带 magic mount |
| --- | --- | --- | --- | --- | --- |
| `system/<分区>/…` | 识别（`TARGET_PARTITIONS` + `rule-paths.sh` 映射） | 识别（`system` 走查 + 按分区根映射） | 识别 | 识别（overlay `system/*`） | 识别 |
| 模块根 `<分区>/…`（`/my_*`） | 识别（`metamount.sh` 扫模块根全部分区） | 仅当 `config.toml` 的 `extra_mount` 列出该分区 | 仅当 `extra_mount` 列出 | 能挂（`$targets` + `controlled_depth`），但本模块仍保守 bind——它可能是手动模式，只挂 `modules.txt` 里列出的模块 | 不识别 |
| 安装时是否移动副本 | 否 | 否（只在模块根建 `<分区> -> ./system/<分区>` 别名软链，扫描器会跳过这种软链） | **会**：把 `system/{vendor,product,system_ext}` `mv` 到模块根 | 否 | KernelSU 自身也会把 `system/<分区>` 提到模块根 |

因此在对 `Magic Mount-rs` 的机器上，本模块的副本可能被它移到模块根、而它自己又不扫模块根 —— `post-fs-data.sh` 会在原路径找不到副本时回退到同名分区目录并自己 bind，保证文件照样生效（代价是这一条留下一个挂载项）。


之所以不无条件挂载：多出来的那条 bind mount 源路径直接写着模块目录，会被 Momo 这类工具判定为“系统挂载项异常”，也会绕过 NoMount 的 UID 隔离（被排除的 App 本该看到原厂文件）。

由于 Play 商店正是通过 `hasSystemFeature("cn.google.services")` 与 `hasSystemFeature("com.google.android.feature.services_updater")` 判断设备是否带国行 GMS 标签（带标签则永远提示“已是最新版本”、不检查本体更新），所以用本模块在系统层去掉这两个特征后，Play 商店本体更新也随之解锁，无需再借助 Xposed 模块去 Hook Play 商店或 Google Play 服务。

为了开启 `Google Location History` 服务，你可能还需要配合其他模块，例如
Magisk 模块: ~~[Riru - Location Report Enabler](https://github.com/RikkaApps/Riru-LocationReportEnabler)~~
或者 Xposed 模块 [LocationReportEnabler](https://github.com/GhostFlying/LocationReportEnabler)。

## 更新

模块内建了更新检查：`module.prop` 里的 `updateJson` 指向仓库根目录的 [`update.json`](update.json)，KernelSU / APatch / Magisk 的模块页会据此显示「有更新」并可直接下载刷入。

- 发版流程：改 `module.prop` 的 `version` / `versionCode` → 打同名 tag（如 `v3.9.4`）→ 推送。CI 会构建 zip、发 Release，并把 `update.json` 回写到 `master`（版本号与 tag 不一致会直接失败，避免拉错包）；
- 预发布（tag 带 `-`，如 `v3.9.4-rc1`）只发 Pre-release，**不写** `update.json`，不会推给普通用户；
- 更新日志取自 [`CHANGELOG.md`](CHANGELOG.md)，发版时手动补一条；
- 管理器比对的是**已安装模块**里的 `updateJson`。所以在加入这行之前装过的版本看不到更新提示，需要手动刷一次新版本后才进入自动更新通道。

## 说明

本模块的代码与文档在 AI 辅助下完成，并在真机上完成验证。

发布包（Release 中的 zip）只包含刷入所需的 `META-INF/`、`customize.sh` 与 `module.prop`；README、`update.json`、`CHANGELOG.md` 仅随仓库提供，不放进压缩包，避免刷入时带入无关文件。

## 致谢

感谢以下上游项目：

- [fei-ke/unlock-cn-gms](https://github.com/fei-ke/unlock-cn-gms)：提供解除国行 GMS 的限制方法。
- [EX3124/UnlockCNGMS](https://github.com/EX3124/UnlockCNGMS)：提供解除国行 ROM Play 商店的限制方法。
