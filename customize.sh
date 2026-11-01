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

# MODPATH 由管理器注入，正常情况下指向 /data/adb/modules(_update)/<id>。
# 万一为空或是根目录，下面的 cp / sed -i 会直接改到系统分区上的真实文件，必须先拦住。
case "$MODPATH" in
    /data/*) ;;
    *) abort "MODPATH 异常（$MODPATH），已中止" ;;
esac

found=false
copy_failed=0
seen=
pfsd_ready=false

# post-fs-data.sh 的头部：定义 inject()，把「要不要自己挂载」推迟到运行时判断。
# 这样在 KernelSU magic mount / NoMount / meta-overlayfs 这些后端已经把文件注入好的机器上，
# 不会再额外产生一条指向模块目录的 bind mount —— 那种挂载项会被检测工具判定为异常。
pfsd_write_header() {
    if $pfsd_ready; then
        return 0
    fi
    pfsd_ready=true
    {
        printf '%s\n' '#!/system/bin/sh'
        cat <<'EOS'
# 由 customize.sh 生成，请勿手改。
#
# 副本分两种存放位置，判「要不要自己 bind」的逻辑也不同：
#
#  A. system 树（system/<分区>/…）：NoMount、Hybrid Mount、Magic Mount-rs、mountify
#     都读得到，而且都在本脚本之后才 mount（KernelSU 是 metamount，APatch 是 post-mount，
#     mountify 是它自己的 post-fs-data，按模块 id 排在本模块之后）。所以「读目标文件、
#     比内容」在这里必然读到原厂内容 → 只能按「有没有启用的元模块」判断，有就整体交给它。
#     不这么做的话，那条 bind 全局可见，隐藏效果比元模块差一个量级，还会和它的挂载计划抢目标。
#
#  B. 模块根的分区目录（my_product/… 这类私有分区）：各家扫描面不同，必须按 id 分辨：
#       nomount        metamount 直接扫 `<模块>/<分区>`，认
#       hybrid_mount   只扫 system/ + config.toml 的 extra_mount，配了才认
#       magic_mount_rs 只扫 system/ + extra_mount，且安装时会把 system/<分区> mv 到模块根
#       mountify       只扫 system/
#       其它 / 没有     不认，交回自己 bind（本来也没有别的注入手段）

# 模块目录从 $0 推出来（可能是绝对路径，也可能被先 cd 进模块目录后用相对路径调用）
MODDIR=${0%/*}
if [ ! -d "$MODDIR/system" ] && [ ! -d "$MODDIR/bind" ]; then
    MODDIR=/data/adb/modules/com.fei_ke.unlockcngms
fi

# 启用中的元模块 id（空 = 没有）。
# 判据与 KernelSU 的 is_metamodule 一致：module.prop 里 metamodule=1|true，
# 且没有 disable/remove 标记。不绑死任何一家的目录名，出现新元模块不用改脚本。
meta_active_id() {
    for prop in /data/adb/modules/*/module.prop; do
        [ -f "$prop" ] || continue
        case "$prop" in
            "$MODDIR"/*) continue ;;
        esac
        dir=${prop%/module.prop}
        [ -f "$dir/disable" ] && continue
        [ -f "$dir/remove" ] && continue
        grep -Eqi '^metamodule=(1|true)' "$prop" 2>/dev/null || continue
        echo "${dir##*/}"
        return 0
    done
    return 0
}

# 元模块的配置里 extra_mount 有没有列出这个分区（TOML，可能是多行数组）。
# 用 shell 的 case 做字面量比较，不把分区名拼进正则：分区名来自注入清单，
# 含 `.` `+` 这类字符时正则会误判（虽然只会导致少挂一次，但没必要留这个口子）。
extra_mount_has() {
    [ -f "$2" ] || return 1
    _list=$(awk '/^[[:space:]]*extra_mount[[:space:]]*=/ { f = 1 } f { print } f && /\]/ { exit }' "$2" 2>/dev/null)
    case "$_list" in
        *"\"$1\""*) return 0 ;;
        *"'$1'"*) return 0 ;;
    esac
    return 1
}

# 模块根的分区目录，这个元模块认不认
meta_reads_partition() {
    # 只接受真实分区目录名：bind/ 是 3.9.3 及更早版本的旧布局（元模块都不扫它），
    # 出现别的字符也一律当作不认识。
    case "$1" in
        ''|bind|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    case "$META_ID" in
        nomount) return 0 ;;
        hybrid_mount) extra_mount_has "$1" /data/adb/hybrid-mount/config.toml ;;
        magic_mount_rs) extra_mount_has "$1" /data/adb/magic_mount/config.toml ;;
        *) return 1 ;;
    esac
}

# 应急开关：元模块把本模块设成 ignore（Hybrid Mount 的 [rules] default_mode = "ignore"）
# 或它自己坏了时，建这个文件即可恢复「全部自己挂」的老行为。
if [ -f "$MODDIR/.force-bind" ]; then
    META_ID=
else
    META_ID=$(meta_active_id)
fi

inject() {
    src=$1
    dst=$2
    # 元模块的 metainstall 会把 system/<分区> 提到模块根（KernelSU 与 magic_mount_rs 都这么做），
    # 副本不在原处时按模块根的同名分区目录再找一次。只在有元模块时这样做 ——
    # 没元模块时提走的是管理器自己，它认得根分区目录，不需要我们补挂。
    if [ ! -f "$src" ] && [ -n "$META_ID" ]; then
        case "$src" in
            "$MODDIR/system/"*) src="$MODDIR/${src#"$MODDIR"/system/}" ;;
        esac
    fi
    [ -f "$src" ] || return 0
    [ -e "$dst" ] || return 0
    case "$src" in
        "$MODDIR/system/"*)
            # system 树：任意元模块都接管，自己一条都不挂
            [ -n "$META_ID" ] && return 0
            ;;
        "$MODDIR"/*)
            # 模块根的分区目录：只有认得的元模块才交给它
            rest=${src#"$MODDIR"/}
            meta_reads_partition "${rest%%/*}" && return 0
            ;;
    esac
    if command -v cmp >/dev/null 2>&1 && cmp -s "$src" "$dst" 2>/dev/null; then
        return 0
    fi
    mount -o ro,bind "$src" "$dst" 2>/dev/null
}
EOS
    } > "$MODPATH/post-fs-data.sh"
}

# 把一条注入关系写进 post-fs-data.sh
pfsd_add() {
    pfsd_write_header
    echo "inject \$MODDIR/$1 $2" >> "$MODPATH/post-fs-data.sh"
}

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

# 扫描结果会被原样写进 post-fs-data.sh，而那个脚本以 root 在每次开机时执行。
# 所以只接受「落在已知分区下、且不含空白与 shell 元字符」的路径：
# 名称里带 $ ; ` 空格 的文件一律跳过，避免被当成代码拼进去（也避免路径拆分）。
is_safe_path() {
    case "$1" in
        /system/*|/system_ext/*|/product/*|/vendor/*|/odm/*|/my_*/*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!A-Za-z0-9._/+@-]*) return 1 ;;
    esac
    return 0
}

# 处理一个命中文件：按所在分区决定模块内路径，再登记一条注入关系。
handle_file() {
    origin=$1

    # /system/product、/system_ext 等在很多 ROM 上是指向独立分区的符号链接，
    # 用真实路径去重，避免同一个文件被处理多次。
    real=$(readlink -f "$origin" 2>/dev/null)
    [ -n "$real" ] || real=$origin
    case "$seen" in *"|$real|"*) return ;; esac
    seen="$seen|$real|"

    if ! is_safe_path "$real"; then
        ui_print "! 跳过路径不符预期的文件: $real"
        return
    fi

    # 能被模块 overlay 直接覆盖的分区，按 $MODPATH/system/<分区>/... 存放。
    # 私有分区（/my_*）放模块根的同名目录：NoMount 的 metamount 直接扫 `<模块>/<分区>`，
    # 放 system/ 下反而会被它经 rule-paths.sh 再映射一次；而 Hybrid Mount / mountify
    # 只扫 system/ 树，会把 system/my_product/… 挂到 /system/my_product 去（幻影目录），
    # 所以这类一律落在模块根，能不能由元模块接管交给运行时判断。
    case "$real" in
        /system_ext/*|/product/*|/vendor/*|/odm/*) rel=system${real} ;;
        *) rel=${real#/} ;;
    esac

    target=$MODPATH/$rel
    mkdir -p "$(dirname "$target")"
    # 复制失败就不算这一步成功：没有副本，注入也无从谈起。
    # 复制后再确认一次是「真实文件」（-f 跟随符号链接，悬空链接判否）：
    # 目标父路径里若混进软链接，cp 会写到链接指向的地方，模块目录里反而看不到副本。
    # 少复制一个文件整体就没意义（PMS 只要还有一处声明，特征就还在），所以计失败数、后面直接中止。
    cp -f "$real" "$target" || { copy_failed=$((copy_failed + 1)); return; }
    [ -f "$target" ] || { copy_failed=$((copy_failed + 1)); return; }
    clean_file "$target"
    found=true

    # 只登记注入关系，是否真的挂载交给 post-fs-data.sh 运行时判断：
    # 后端已经注入（内容一致）就不挂，避免在 /proc/mounts 留下多余的挂载项。
    pfsd_add "$rel" "$real"
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

    # 旧版的 post-fs-data.sh 是无条件 mount 的写法，升级时改写成 inject 形式后重新生成，
    # 让升级上来的机器同样不再产生多余的挂载项。
    pfsd_write_header
    # 旧写法 mount -o ro,bind ${0%/*}/<rel> <real> → 新写法 inject $MODDIR/<rel> <real>；
    # 已经是新写法的原样保留，最后去重（两遍输出可能撞同一条）
    {
        sed -n 's|^mount -o ro,bind \${0%/\*}/|inject $MODDIR/|p' \
            "$PREV_MODULE/post-fs-data.sh" 2>/dev/null
        grep '^inject \$MODDIR/' "$PREV_MODULE/post-fs-data.sh" 2>/dev/null
    } | awk '!seen[$0]++' > "$MODPATH/.pfsd.new"

    if [ ! -s "$MODPATH/.pfsd.new" ]; then
        rm -f "$MODPATH/.pfsd.new"
        abort "旧模块的 post-fs-data.sh 解析不出注入清单，请在管理器里卸载本模块、重启后重新刷入"
    fi

    # 按注入清单逐条还原副本，而不是整目录复制 system/ ：
    #   1. 旧模块目录里若多出 service.sh / uninstall.sh 之类的脚本，整目录复制会被带过来以 root 执行；
    #   2. 更关键的是「payload 不在 system/ 里」的布局会整目录丢失 ——
    #      比如把分区目录放到模块根目录（product/、odm/ …）再在 system/ 下留软链接的做法，
    #      整目录复制只会把悬空软链接搬过来，装出一个看着装好、实际一条规则都注入不了的空壳。
    missing=0
    while IFS= read -r line; do
        case "$line" in
            'inject $MODDIR/'*) ;;
            *) continue ;;
        esac
        entry=${line#inject \$MODDIR/}
        rel=${entry%% *}
        target=${entry#* }
        # 这一行会被原样重写进以 root 每次开机执行的 post-fs-data.sh，
        # 而 rel / target 来自设备上既有的旧脚本（可能是十几版之前、没有 is_safe_path 的产物），
        # 所以两个字段都要按白名单复核：只接受「模块内相对路径」和「分区下的绝对路径」。
        case "$rel" in
            ''|/*|*..*|*[!A-Za-z0-9._/+@-]*)
                ui_print "! 跳过可疑条目: $line"
                missing=$((missing + 1))
                continue
                ;;
        esac
        case "$target" in
            /*) ;;
            *)
                ui_print "! 跳过目标不是绝对路径的条目: $line"
                missing=$((missing + 1))
                continue
                ;;
        esac
        case "$target" in
            *[!A-Za-z0-9._/+@-]*)
                ui_print "! 跳过目标含特殊字符的条目: $line"
                missing=$((missing + 1))
                continue
                ;;
        esac
        # 源路径必须解析后仍落在旧模块目录内、且是普通文件：
        # 挡住「软链指向模块外的任意文件 / FIFO / 设备节点」被当成副本拷进系统路径。
        src=$(readlink -f "$PREV_MODULE/$rel" 2>/dev/null)
        # 旧模块的副本可能被管理器提到模块根（KernelSU 与 magic_mount_rs 都会把
        # system/<分区> mv 到模块根），原处找不到就到同名分区目录再找一次。
        if [ ! -f "$src" ] && [ "${rel#system/}" != "$rel" ]; then
            src=$(readlink -f "$PREV_MODULE/${rel#system/}" 2>/dev/null)
        fi
        [ -n "$src" ] || src=$PREV_MODULE/$rel
        case "$src" in
            "$PREV_MODULE"/*) ;;
            *)
                ui_print "! 跳过指向模块目录外的条目: $rel"
                missing=$((missing + 1))
                continue
                ;;
        esac
        if [ ! -f "$src" ]; then
            ui_print "! 旧模块缺少副本: $rel"
            missing=$((missing + 1))
            continue
        fi
        # 旧布局把私有分区副本放在 bind/ 下；新布局直接放模块根的同名分区目录，
        # NoMount 这类扫模块根的元模块就能直接接管，不必再 bind。
        rel=${rel#bind/}
        dst=$MODPATH/$rel
        mkdir -p "$(dirname "$dst")" || { missing=$((missing + 1)); continue; }
        # 用 cp（跟随符号链接）而不是 cp -a：旧布局若把真实文件放在别处、
        # system/ 下只留软链接，cp -a 会把软链接原样复制成新的悬空链接。
        cp -f "$src" "$dst" 2>/dev/null
        if [ -f "$dst" ]; then
            echo "inject \$MODDIR/$rel $target" >> "$MODPATH/post-fs-data.sh"
        else
            ui_print "! 旧模块副本复制失败: $rel"
            missing=$((missing + 1))
        fi
    done < "$MODPATH/.pfsd.new"
    rm -f "$MODPATH/.pfsd.new"

    if [ "${missing:-0}" -gt 0 ]; then
        abort "旧模块的副本不完整（缺 $missing 项），请在管理器里卸载本模块、重启后重新刷入"
    fi
    found=true
fi

# 扫描阶段只要有一个命中文件没复制成功也整体中止：PMS 看的是「所有声明文件」，
# 少清理一处，特征照样生效，装出来同样是坏的。
if $found && [ "${copy_failed:-0}" -gt 0 ]; then
    abort "有 $copy_failed 个文件的副本写入失败，未安装（多为目标路径异常）"
fi

# 兜底自检：post-fs-data.sh 里登记的每个副本都必须真实存在（-f 跟随符号链接，
# 悬空链接判否）。少了任何一条，装出来的就是「看着装好、实际没注入」的空模块 ——
# 那正是 NoMount 这类元模块把它判成「未激活」、系统特征却纹丝不动的原因。
if $found; then
    [ -f "$MODPATH/post-fs-data.sh" ] || abort "没有生成 post-fs-data.sh，未安装"
    missing=
    priv=
    while IFS= read -r line; do
        case "$line" in
            'inject $MODDIR/'*) ;;
            *) continue ;;
        esac
        src=${line#inject \$MODDIR/}
        src=${src%% *}
        # 与 PREV 分支同一套白名单：本文件虽是自己生成的，但升级自旧版时可能带着旧格式的行
        case "$src" in
            ''|/*|*..*|*[!A-Za-z0-9._/+@-]*) missing="$missing ${src:-?}"; continue ;;
        esac
        [ -f "$MODPATH/$src" ] || missing="$missing $src"
        # 记下放在模块根分区目录里的副本（/my_* 这类），下面据此给元模块用户提个醒
        case "$src" in
            system/*) ;;
            */*) case " $priv " in *" ${src%%/*} "*) ;; *) priv="$priv ${src%%/*}" ;; esac ;;
        esac
    done < "$MODPATH/post-fs-data.sh"
    if [ -n "$missing" ]; then
        for m in $missing; do
            ui_print "! 缺少副本: $m"
        done
        abort "注入清单里的文件缺失，多在旧模块目录已损坏时出现；请在管理器里卸载本模块、重启后重新刷入"
    fi
fi

# 顺手报告注入后端，省得事后猜「为什么 mountinfo 里一条都没有」或「为什么特征还在」：
# 装了元模块时，system 树整个由它注入，本模块一条挂载都不产生。
if $found; then
    meta_id=
    for prop in /data/adb/modules/*/module.prop; do
        [ -f "$prop" ] || continue
        case "$prop" in "$MODPATH"/*) continue ;; esac
        dir=${prop%/module.prop}
        [ -f "$dir/disable" ] && continue
        [ -f "$dir/remove" ] && continue
        grep -Eqi '^metamodule=(1|true)' "$prop" 2>/dev/null || continue
        meta_id=${dir##*/}
        break
    done
    if [ -n "$meta_id" ]; then
        ui_print "- 检测到元模块 $meta_id：system 树交给它注入，本模块不产生挂载"
        # 这两家只扫 system/ 树，模块根的分区目录要它们读，得先进 extra_mount
        case "$meta_id" in
            hybrid_mount|magic_mount_rs)
                if [ -n "$priv" ]; then
                    ui_print "- 私有分区副本:$priv"
                    ui_print "  该元模块只扫 system/，要在它的 config.toml 里把上面这些分区"
                    ui_print "  加进 extra_mount 才能免掉本模块的 bind，否则照旧由本模块挂"
                fi
                ;;
        esac
    else
        ui_print "- 未检测到元模块：必要时由本模块补只读 bind"
    fi
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
