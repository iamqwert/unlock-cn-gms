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
| `/proc/mounts` 中的覆盖 | — | 两个目标文件均为只读 bind mount，源位于 `/data` 下的模块目录 |

启用后系统特征总数为 124 条，其中不含任何国行 GMS 特征。

验证命令：

```shell
adb shell pm list features | grep -E 'cn\.google|services_updater'   # 无输出即已清除
adb shell cat /proc/mounts | grep -E 'cn.google|bds_preference'      # 应有两条 bind mount
```

Play 商店 53.7.23（测试时为最新版）中判断国行标签的入口是 `hasSystemFeature("cn.google.services") && hasSystemFeature("com.google.android.feature.services_updater")`，上述特征清零后该判断恒为 `false`，与在商店进程里 Hook 得到的结果一致。测试时商店已是最新版，因此“检查更新”界面无法体现差异，需等 Google 发布新版本后自然验证。

## 注意事项

部分设备上可能同时存在多个配置文件（如小米 8e5 同时在 `/odm` 和 `/product` 分区下各有一个），本模块会扫描所有分区的 `etc/permissions`、`etc/sysconfig` 目录并处理全部匹配文件，不再依赖写死的文件名。所有被处理的文件都会在 `post-fs-data.sh` 中以只读 bind mount 方式覆盖，因此在 Magisk、KernelSU（无需 meta-overlayfs 等元模块）、APatch 以及 `/my_*` 这类独立挂载分区上都能生效。

由于 Play 商店正是通过 `hasSystemFeature("cn.google.services")` 与 `hasSystemFeature("com.google.android.feature.services_updater")` 判断设备是否带国行 GMS 标签（带标签则永远提示“已是最新版本”、不检查本体更新），所以用本模块在系统层去掉这两个特征后，Play 商店本体更新也随之解锁，无需再借助 Xposed 模块去 Hook Play 商店或 Google Play 服务。

为了开启 `Google Location History` 服务，你可能还需要配合其他模块，例如
Magisk 模块: ~~[Riru - Location Report Enabler](https://github.com/RikkaApps/Riru-LocationReportEnabler)~~
或者 Xposed 模块 [LocationReportEnabler](https://github.com/GhostFlying/LocationReportEnabler)。

## 说明

本模块的代码与文档在 AI 辅助下完成，并在真机上完成验证。

## 致谢

感谢以下上游项目：

- [fei-ke/unlock-cn-gms](https://github.com/fei-ke/unlock-cn-gms)：提供解除国行 GMS 的限制方法。
- [EX3124/UnlockCNGMS](https://github.com/EX3124/UnlockCNGMS)：提供解除国行 ROM Play 商店的限制方法。
