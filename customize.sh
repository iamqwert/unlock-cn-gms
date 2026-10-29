#!/system/bin/sh

# 国行 GMS 标记：
#   cn.google.services / com.google.android.feature.services_updater
#       —— Play 商店据此认为设备使用国行 GMS（自带服务更新器），
#          从而永远提示“已是最新版本”、不检查本体更新；GMS 也会因此关闭快速分享等功能。
#   cn.google
#       —— Play 商店中的另一处国行判断（Finsky 里 hasSystemFeature("cn.google")）。
MARKERS='name="cn\.google|services_updater'

# 各分区常见的权限 / 配置目录（首轮扫描）。
DIRS="
/system/etc/permissions
/system/etc/sysconfig
/system_ext/etc/permissions
/system_ext/etc/sysconfig
/product/etc/permissions
/product/etc/sysconfig
/vendor/etc/permissions
/vendor/etc/sysconfig
/odm/etc/permissions
/odm/etc/sysconfig
"

for dir in /my_*/etc/permissions /my_*/etc/sysconfig; do
    [ -d "$dir" ] && DIRS="$DIRS $dir"
done

# 兜底扫描范围：各分区的 etc 根目录。部分 ROM 会把声明文件放进自定义子目录，
# 首轮 *.xml 扫不到时，再往下沉两层找一遍。
# 注意：这里只能用 find（默认不跟随符号链接），绝不能用 grep -r ——
# busybox 的 -r 等同 -R，会跟随符号链接，一旦链到 /data、/proc 就会长时间卡死。
FALLBACK_DIRS="
/system/etc
/system_ext/etc
/product/etc
/vendor/etc
/odm/etc
"

for dir in /my_*/etc; do
    [ -d "$dir" ] && FALLBACK_DIRS="$FALLBACK_DIRS $dir"
done

found=false
need_bind_mount=false
seen=

# 只认领“可读、体积小、确实是 XML 且真的含标记”的文件，
# 避免把二进制或无关配置误当作声明文件复制进模块。
is_marker_file() {
    [ -f "$1" ] || return 1
    [ -r "$1" ] || return 1

    size=$(wc -c < "$1" 2>/dev/null | tr -d ' \t')
    [ -n "$size" ] && [ "$size" -le 65536 ] || return 1

    grep -Eq '<(feature|permissions|config)[[:space:]>]' "$1" 2>/dev/null || return 1
    grep -Eq "$MARKERS" "$1" 2>/dev/null
}

# 删除标记行；如果整个文件被删空，补回合法的最小 XML 结构，
# 否则 SystemConfig 解析失败会连带丢掉同文件里的其它配置。
clean_file() {
    sed -i '/name="cn\.google/d' "$1"
    sed -i '/services_updater/d' "$1"

    if grep -Eq '<(permissions|config)([[:space:]>])' "$1"; then
        return
    fi

    if echo "$1" | grep -q '/sysconfig/'; then
        printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' '<config>' '</config>' > "$1"
    else
        printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' '<permissions>' '</permissions>' > "$1"
    fi
}

# 处理一个命中文件：按所在分区决定模块内路径，再挂一次只读 bind mount。
handle_file() {
    origin=$1

    # /system/product、/system_ext 等在很多 ROM 上是指向独立分区的符号链接，
    # 用真实路径去重，避免同一个文件被处理多次。
    real=$(readlink -f "$origin" 2>/dev/null)
    [ -n "$real" ] || real=$origin
    case "$seen" in *"|$real|"*) return ;; esac
    seen="$seen|$real|"
    found=true

    # 能被模块 overlay 直接覆盖的分区，按 $MODPATH/system/<分区>/... 存放；
    # 厂商私有分区（/my_* 等）无法放进 system 树，只做 bind mount。
    case "$real" in
        /system/*) rel=${real#/} ;;
        /system_ext/*|/product/*|/vendor/*|/odm/*) rel=system${real} ;;
        *) rel= ;;
    esac

    if [ -z "$rel" ]; then
        rel=bind/$(echo "$real" | sed 's#^/##; s#/#_#g')
    fi

    target=$MODPATH/$rel
    mkdir -p "$(dirname "$target")"
    cp -f "$real" "$target" || return
    clean_file "$target"

    # 无论 root 方案是 Magisk、KernelSU 还是 APatch，都额外做一次只读 bind mount。
    # KernelSU/APatch 在没有 meta-overlayfs 之类元模块时不会挂载 $MODPATH/system，
    # 只靠文件覆盖会静默失效（Play 商店因此保持国行标签）。
    echo "mount -o ro,bind \${0%/*}/$rel $real" >> "$MODPATH/post-fs-data.sh"
    need_bind_mount=true
    ui_print "modify $real"
}

# 首轮：各分区既定的 permissions / sysconfig 目录
ui_print "- 扫描各分区 permissions / sysconfig"
for dir in $DIRS; do
    [ -d "$dir" ] || continue
    for origin in "$dir"/*.xml; do
        [ -f "$origin" ] || continue
        is_marker_file "$origin" && handle_file "$origin"
    done
done

# 兜底：首轮没找到，就往下沉两层找子目录里的 *.xml。
# find 不带 -L 时不跟随符号链接，深度也固定，避免陷进 /data、/proc 这类无底洞。
if ! $found; then
    ui_print "- 首轮未命中，搜索子目录（不跟随符号链接）"
    for dir in $FALLBACK_DIRS; do
        [ -d "$dir" ] || continue
        # /xxx/etc 下最多下沉到 etc/<子目录>/<子目录>/*.xml，再深就不属于权限声明了
        for origin in $(find "$dir" -maxdepth 3 -type f -name '*.xml' 2>/dev/null); do
            is_marker_file "$origin" && handle_file "$origin"
        done
    done
fi

# 已经装过本模块时，模块自己的 overlay / bind mount 会把原始文件遮住，
# 扫描只能看到清理后的副本 —— 也就是“明明装过却找不到标记”。这时沿用上次的处理结果，
# 否则从 v3.9 起，任何升级或重装都会被误判成“不支持的机型”而直接失败。
PREV_MODULE=/data/adb/modules/com.fei_ke.unlockcngms

if ! $found && [ -f "$PREV_MODULE/post-fs-data.sh" ] && [ "$PREV_MODULE" != "$MODPATH" ]; then
    ui_print "- 检测到模块已生效，原文件被本模块的挂载遮挡"
    ui_print "- 沿用上次的处理结果，不重新扫描"

    for f in "$PREV_MODULE"/*; do
        [ -e "$f" ] || continue
        case "${f##*/}" in
            # 这几个是 root 方案的控制文件，跟着复制过去会把新装的模块禁用/删除
            module.prop|post-fs-data.sh|disable|remove|skip_mount|update) continue ;;
        esac
        cp -a "$f" "$MODPATH/" 2>/dev/null
    done
    cp -f "$PREV_MODULE/post-fs-data.sh" "$MODPATH/post-fs-data.sh"
    found=true
fi

if $need_bind_mount; then
    sed -i '1i#!/system/bin/sh' "$MODPATH/post-fs-data.sh"
fi

# 没找到就不要装作装好了：装上也不会生效，反而让人以为模块坏了。
# 同时把现场信息写进刷入日志，方便按机型排查。
if ! $found; then
    ui_print "! 未发现含国行 GMS 标记的权限文件"
    ui_print "! 设备: $(getprop ro.product.model 2>/dev/null)"
    ui_print "! ROM: $(getprop ro.build.display.id 2>/dev/null)"
    ui_print "! Android $(getprop ro.build.version.release 2>/dev/null) / SDK $(getprop ro.build.version.sdk 2>/dev/null)"
    for dir in $DIRS; do
        [ -d "$dir" ] || continue
        ui_print "! 存在 $dir（$(ls "$dir" 2>/dev/null | wc -l | tr -d ' ') 个文件）"
    done
    abort "本机没有需要移除的国行 GMS 标记（非国行 ROM，或已被其它方式移除），未安装"
fi
