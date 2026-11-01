# 更新日志

## v3.9.4

### 修复：模块「未激活」

- **原因**：模块目录里的副本丢失，只剩 `module.prop`、`post-fs-data.sh` 和一个空的 `system/`。元模块扫不到文件就不生成注入规则，`post-fs-data.sh` 又因为源文件不存在而静默跳过。
- **处理**：重刷时改为按旧 `post-fs-data.sh` 的注入清单逐条还原副本（跟随软链取真实文件），缺任何一项直接中止并提示卸载重刷；同时修掉「沿用上次处理结果」分支只复制 `system/`、把模块根分区目录整块丢失的 bug，以及 `grep '^inject $MODDIR/'` 里 `$` 被当成行尾锚点、导致升级路径一直走错分支的问题。
- **兜底自检**：安装末尾校验注入清单里的每个副本都真实存在（悬空软链判否），否则中止。

### 兼容：四个主流元模块

- 支持 [NoMount](https://github.com/maxsteeel/nomount)、[Hybrid Mount](https://github.com/Hybrid-Mount/meta-hybrid_mount)、[Magic Mount-rs](https://github.com/Tools-cx-app/meta-magic_mount-rs)、[mountify](https://github.com/backslashxx/mountify)。
- 判定统一看 `module.prop` 里的 `metamodule=1` / `metamodule=true`（与 KernelSU 的 `is_metamodule` 一致）。
- 有启用的元模块时，`system/` 树整体交给它注入，本模块不再产生额外的 bind 挂载。此前版本即使元模块已接管仍会补挂，`/proc/self/mountinfo` 里能看到两条源路径带模块目录的挂载项，会被检测工具判为「系统挂载项异常」——本版已消除。
- `/my_*` 等私有分区的副本改放模块根的分区目录：NoMount 直接识别；Hybrid Mount / Magic Mount-rs 需要在各自 `config.toml` 的 `extra_mount` 里列出分区名，否则仍由本模块只读 bind。
- Magic Mount-rs 安装时会把 `system/<分区>` 移到模块根，脚本会自动回退到同名分区目录取副本，保证照样生效。
- 应急开关：模块目录下建 `.force-bind` 可强制回到「全部自己挂」的旧行为。
- [meta-overlayfs](https://github.com/KernelSU-Modules-Repo/meta-overlayfs) 仓库已归档只读，本版未针对它做适配，建议改用上面四个。

### 新增：模块更新检测

- `module.prop` 增加 `updateJson`，指向仓库里的 [update.json](update.json)。KernelSU / APatch / Magisk 的模块页会直接提示有更新并下载刷入。
- 注意：更新检查读的是**已安装模块**里的 `updateJson`。从更早版本升级上来的用户需要手动刷一次 v3.9.4，之后才会收到自动更新提示。

## v3.9.3 及更早

此前版本没有逐条更新记录，改动可查提交历史：<https://github.com/iamqwert/unlock-cn-gms/commits/master>。
