## 改动说明

<!-- 这个 PR 做了什么、为什么 -->

## 验证

- [ ] 已在真机上刷入并重启
- [ ] `adb shell pm list features | grep -E 'cn\.google|services_updater'` 无输出
- [ ] `/product/etc/permissions`、`/odm/etc/permissions` 等声明文件中已无相关 `feature` 行，且 XML 结构合法
- [ ] 未影响其它 `etc/permissions`、`etc/sysconfig` 配置

## 受影响设备

<!-- 验证过的机型 / ROM / Android 版本 / Root 方案，例如：Redmi K90 Pro Max，HyperOS 3，Android 17，KernelSU -->

## 备注

<!-- 已知限制、需要上游同步的内容等 -->
