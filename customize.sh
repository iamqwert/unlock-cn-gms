#!/system/bin/sh

# 国行 GMS 标记：
#   cn.google.services / com.google.android.feature.services_updater
#       —— Play 商店据此认为设备使用国行 GMS（自带服务更新器），
#          从而永远提示“已是最新版本”、不检查本体更新；GMS 也会因此关闭快速分享等功能。
#   cn.google
#       —— Play 商店中的另一处国行判断（Finsky 里 hasSystemFeature("cn.google")）。
MARKERS='name="cn\.google|services_updater'

# 所有可能声明上述标记的目录（各分区 + 厂商 /my_* 分区）。
# 不再写死文件名：不同 ROM 的声明文件位置和文件名都不一样，逐目录扫描更可靠。
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

found=false
need_bind_mount=false
seen=

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

for dir in $DIRS; do
    [ -d "$dir" ] || continue
    for origin in "$dir"/*.xml; do
        [ -f "$origin" ] || continue
        grep -Eq "$MARKERS" "$origin" 2>/dev/null || continue

        # /system/product、/system_ext 等在很多 ROM 上是指向独立分区的符号链接，
        # 用真实路径去重，避免同一个文件被处理多次。
        real=$(readlink -f "$origin" 2>/dev/null)
        [ -n "$real" ] || real=$origin
        case "$seen" in *"|$real|"*) continue ;; esac
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
        cp -f "$real" "$target"
        clean_file "$target"

        # 无论 root 方案是 Magisk、KernelSU 还是 APatch，都额外做一次只读 bind mount。
        # KernelSU/APatch 在没有 meta-overlayfs 之类元模块时不会挂载 $MODPATH/system，
        # 只靠文件覆盖会静默失效（Play 商店因此保持国行标签）。
        echo "mount -o ro,bind \${0%/*}/$rel $real" >> "$MODPATH/post-fs-data.sh"
        need_bind_mount=true
        ui_print "modify $real"
    done
done

if $need_bind_mount; then
    sed -i '1i#!/system/bin/sh' "$MODPATH/post-fs-data.sh"
fi

$found || abort "No suitable permission file found!"
