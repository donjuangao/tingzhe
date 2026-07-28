#!/bin/bash
# 构建 tingzhe.app —— 零依赖,只用 Xcode CLT 自带的 swiftc
set -euo pipefail
cd "$(dirname "$0")"

# ⛔ --dev:编译到**另一个路径**,绝不碰 tingzhe.app（2026-07-26 作者 抓）
#
# 病根:本脚本原来只有一个输出路径,于是"我要编译"被我当成了"我要覆盖 作者 正在用的那个 bundle"。
# **它们不是一件事。** 辅助功能授权绑 tingzhe.app 的 CDHash —— 只要不覆盖它,授权就不会掉。
# 而绝大多数自检(`--apply` / `--fix` / `--candidates` / `--selftest-canon` / `--selftest-boundary`
# / `--selftest-reload`)是**纯文本操作,零权限需求**,拿裸二进制跑就够。
# 只有 `--selftest-record`(要麦克风)与守护进程冒烟(要辅助功能)必须用真 app。
# → 迭代期一律 `./build.sh --dev`;只在代码定稿、作者 准备好重授的那一刻跑一次正式构建。
# ⛔ F2(2026-07-26 独立复核实测):原来只认 `$1 == --dev`,**任何别的参数都静默走破坏性路径** ——
# `./build.sh --help` 会把真 app 删掉重建(实测二进制 inode GONE)。参数必须校验。
DEV=0
# ⛔ C-7(独立复核实测):`./build.sh --dev --help` 打完用法就 **exit 0,什么都没构建** ——
# 而 check.sh 第 1 项判的正是 `./build.sh --dev` 的退出码 ⇒ 这个组合会让它**误判编译通过**。
# 「成功退出码」必须只属于「真做完了那件事」。--help 只在**单独使用**时合法。
# ⛔ 别写成 `printf … | grep -q`：本脚本开了 pipefail,grep -q 命中即关管道 → printf 吃 SIGPIPE
# 返非零 → 整条判假,guard 静默失效。**我写这个 guard 时当场又犯了一次同款**(本 repo 第四次)。
# 铁律:管道结果先落变量再判。这里干脆不用管道。
HAS_HELP=0
for a in "$@"; do case "$a" in -h|--help) HAS_HELP=1 ;; esac; done
if [ "$#" -gt 1 ] && [ "$HAS_HELP" = 1 ]; then
  echo "✗ --help 只能单独用（收到: $*）—— 它不构建任何东西,跟别的参数混用会让调用方误判成功" >&2
  exit 2
fi
for a in "$@"; do
  case "$a" in
    --dev) DEV=1 ;;
    -h|--help)
      echo "用法: ./build.sh [--dev]"
      echo "  --dev  编译到 build/dev/tingzhe —— 不打 bundle、不签名、**不碰 tingzhe.app**"
      echo "         (辅助功能授权绑 tingzhe.app 的 CDHash;迭代期一律用这条)"
      echo "   无参   正式构建 tingzhe.app —— ⛔ 会打掉辅助功能授权,需 作者 重授一次"
      exit 0 ;;
    *) echo "✗ 不认识的参数: ${a}（想看用法: ./build.sh --help）" >&2; exit 2 ;;
  esac
done

# ⛔⛔ 正式构建需要显式确认（2026-07-26 · 作者 第三次抓「你又把快捷键修坏了」）
#
# 病根不是我忘了,是**这件事没有闸**。我在同一个小时里写下「只在代码定稿、且 作者 准备好重授的
# 那一刻才跑一次正式构建」这条铁律,然后自己违反了它 —— 一条只写在注释里的规矩,
# 跟"警告没有东西依赖它"是同一个病。
# ⚠ 这段话原来写的是「每一次正式构建都会作废 作者 的辅助功能授权(ad-hoc 签名绑 CDHash,无法避免)」
#   —— **2026-07-28 已被推翻**:本机自签身份 `tingzhe-local` 的 designated 认「identifier+证书」,
#   跟二进制无关,授权跨构建存活(实测 CDHash 变而授权不掉)。留着那句话 = 仓库里两份真相,
#   下一个 session 读到它又会去让 作者 重授一次。
# 闸仍然保留,但理由换了、也说实话:正式构建会**覆盖 作者 正在用的那个 bundle** 并重启常驻,
# 中途他按住说话会没反应。这是打扰,不是灾难 —— 所以是确认,不是禁止。
# ⛔⛔ 2026-07-28 开源前审计抓出:这道闸对**刚 clone 的人**是一堵没有理由的墙。
# README 写着 `./build.sh`,而它退出 3 什么都不建,还说「会覆盖你正在用的 app 并重启常驻」——
# 新用户既没有正在用的 app,也没有常驻。**我为保护作者加的闸,变成了别人的第一道墙。**
# ⇒ 判据换成「**有没有东西会被打扰**」:已有 app bundle,或已注册 LaunchAgent。
#   两者都没有 = 首次构建,直接建。
# ⚠ 判据必须是「**这个目录**里的东西会被打扰」,不是「这台机器上有没有装过」——
#   第一版只查 `launchctl list` 有没有这个 label,于是在一个全新的临时 clone 里也判「有」
#   (作者机器上确实注册着,但它指向的是**另一个目录**)。
DISTURBS=0
[ -d "tingzhe.app" ] && DISTURBS=1
PLIST="$HOME/Library/LaunchAgents/local.tingzhe.ptt.plist"
if [ -f "${PLIST}" ] && grep -q "$(pwd)/" "${PLIST}" 2>/dev/null; then DISTURBS=1; fi
if [ "$DEV" != "1" ] && [ "$DISTURBS" = "1" ] && [ "${TINGZHE_REAL_BUILD:-0}" != "1" ]; then
  echo "⚠ 正式构建会覆盖 作者 正在用的 tingzhe.app 并重启常驻（期间热键短暂失灵）。"
  echo "  授权**不会**掉：已用本机自签身份签名，designated 认证书不认二进制（2026-07-28 实测）。"
  echo
  echo "   迭代请用：./build.sh --dev      （完全不碰 tingzhe.app）"
  echo "   确实要正式构建："
  echo "     TINGZHE_REAL_BUILD=1 ./build.sh"
  echo
  echo "   ⚠ 跑它之前先确认现在没人在用。"
  exit 3
fi

# ⛔ F14:并发构建会各自 rm -rf 同一个 bundle、写同一个 .last-designated,
# 产出"二进制来自 A、签名来自 B"或直接死在 codesign。加锁。
# ⛔ 别用 flock —— **macOS 没有它**(util-linux 专属)。2026-07-26 实测:`command not found`
# 让 `if ! flock` 成真 → 报「已有一个构建在跑」→ **正式构建整条路被堵死**。
# 而这把锁从没被执行过一次(正式构建刚被关到 TINGZHE_REAL_BUILD=1 后面),
# 又是「加了机制却没跑过它」—— 本项目当天第四次。
# 改用 POSIX 到处都有的 mkdir 原子锁 + 死锁接管。
LOCKD=".build.lock.d"
take_lock() { mkdir "$LOCKD" 2>/dev/null && echo $$ > "$LOCKD/pid"; }
if [ "$DEV" != "1" ]; then
  if ! take_lock; then
    OTHER=$(cat "$LOCKD/pid" 2>/dev/null || true)
    if [ -n "${OTHER:-}" ] && kill -0 "$OTHER" 2>/dev/null; then
      echo "✗ 已有一个构建在跑（PID ${OTHER}）"; exit 1
    fi
    echo "  （接管陈旧构建锁：持有者 PID ${OTHER:-未知} 已不在）"
    rm -rf "$LOCKD"; take_lock || { echo "✗ 拿不到构建锁"; exit 1; }
  fi
  trap 'rm -rf "$LOCKD" ".build-stage"' EXIT
fi

if [ "$DEV" = "1" ]; then
  mkdir -p build/dev
  swiftc -swift-version 5 -O \
    -framework AVFoundation -framework AppKit -framework Carbon \
    -o build/dev/tingzhe src/main.swift
  echo "✓ dev 构建完成 → $(pwd)/build/dev/tingzhe"
  echo "  （未打 bundle · 未签名 · 未碰 tingzhe.app → 辅助功能授权不受影响）"
  echo "  纯文本自检可直接跑，例：build/dev/tingzhe --selftest-boundary"
  exit 0
fi

# ⛔ F4(独立复核实测):原来 `rm -rf "$APP"` 排在 swiftc **前面** —— 编译一错就把 作者 正在用的
# 二进制删干净且不可回滚,而 LaunchAgent 的 KeepAlive 正指着那个空路径
# (= 2026-07-22 那 28,062 次无限重拉的同型现场)。
# 改为:构到临时 bundle → 成功了才原子换上。编译失败时现有 app 一根手指都不碰。
APP="tingzhe.app"
STAGE=".build-stage/tingzhe.app"
rm -rf ".build-stage" && mkdir -p "$STAGE/Contents/MacOS"
# ⚠ 别在这里再 `trap ... EXIT` —— 会**覆盖掉**上面那把锁的 trap,锁就永远不释放了。
# 上面的 trap 已同时清 $LOCKD 与 .build-stage;DEV 分支根本走不到这里。

# 必须打成 .app —— 裸可执行文件拿不到麦克风权限(TCC 要读 Info.plist 里的用途说明)
cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>tingzhe</string>
  <key>CFBundleIdentifier</key><string>local.tingzhe.ptt</string>
  <key>CFBundleName</key><string>tingzhe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>按住热键时录制你的语音，发送给 MOSS 转写成文字。</string>
</dict></plist>
PLIST

swiftc -swift-version 5 -O \
  -framework AVFoundation -framework AppKit -framework Carbon \
  -o "$STAGE/Contents/MacOS/tingzhe" src/main.swift

# ⛔ 2026-07-26 更正:原注释写「TCC 用签名标识记住授权,不签的话每次重建都要重授」——**这句是错的**。
# 实测:`codesign --sign -` 是 **ad-hoc** 签名(`Signature=adhoc` · `TeamIdentifier=not set`),
# 它的指定要求逐字是 `designated => cdhash H"..."` —— **TCC 认的就是精确 CDHash 本身**。
# 所以签了也一样:**任何一次源码改动都会让辅助功能授权失效**,签名只是让 bundle 有个稳定的
# identifier 供 `tccutil reset` 精确定位,并不保住授权。
# 想让授权跨构建存活,需要**稳定签名身份**(Developer ID 的指定要求认 team+bundle id 而非 cdhash);
# 本机 `security find-identity -v -p codesigning` = **0 valid identities**,现在没有这条路。
# ⛔⛔ 2026-07-28:改用**本机自签身份**,不再用 ad-hoc。
# ad-hoc(`--sign -`)的指定要求就是 cdhash 本身 ⇒ 改一个字节授权就失效,
# 作者 今天为此重授了**八次**。自签身份的指定要求是
#   `identifier "local.tingzhe.ptt" and certificate leaf = H"..."`
# —— 认的是「这个 app + 这张证书」,**跟二进制内容无关**。
# 实证:两个完全不同的二进制签出来的 designated 字符串**逐字相同**。
# ⚠ 证书没有"受信任"状态(那要改安全设置,不该由脚本代劳),但**签名不需要它**。
# 身份不在时自动退回 ad-hoc,不阻断构建。
SIGN_ID="tingzhe-local"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  if codesign --force --sign "$SIGN_ID" --identifier local.tingzhe.ptt --timestamp=none "$STAGE" 2>/dev/null; then
    echo "  ✓ 用本机自签身份签名 → 授权跨构建存活（不再需要每次重授）"
  else
    echo "  ⚠ 自签身份签名失败 → 退回 ad-hoc（这次仍会掉授权）"
    codesign --force --sign - --identifier local.tingzhe.ptt "$STAGE" 2>/dev/null || true
  fi
else
  echo "  ⚠ 没有 $SIGN_ID 身份 → ad-hoc 签名（每次构建都会掉授权）"
  codesign --force --sign - --identifier local.tingzhe.ptt "$STAGE" 2>/dev/null \
    || echo "  ⚠ 签名失败"
fi

# ⛔ F13:CDHash 必须在**换上之前**取,且不能用 `codesign | grep` 直接接管道 ——
# 未签名时 grep 找不到、pipefail 把整条判非零、set -e 立刻杀脚本(那时 app 已被换掉、
# 授权已死,却没有 marker、没有恢复提示)。先落变量,容忍失败。
# ⛔⛔ 2026-07-28:判据从 **CDHash** 换成 **designated requirement**。
# 病根:CDHash 是 ad-hoc 签名时代 TCC 认的东西。换成本机自签身份之后,
# TCC 认的是 `designated => identifier "…" and certificate leaf = H"…"` —— **跟二进制无关**。
# 而这里还在比 CDHash ⇒ 每次构建都判「授权掉了」,弹一个大框叫 作者 去重授。
# **作者 今天已经因为我的错误结论重授了八次,而这个框还在催第九次。**
# ⚠ 我在文件顶部那个确认框里已经改对了,却漏了这里 —— **同一份真相两处存放,我只改了一份。**
NEWSIG=$(codesign -d --requirements - "$STAGE" 2>&1 || true)
NEWSIG=$(printf '%s\n' "$NEWSIG" | grep '^designated' | head -1 || true)
[ -n "$NEWSIG" ] || NEWSIG="designated=UNSIGNED-$(date -u +%s)"

# 原子换上：先搬走旧的，再移入新的，失败可回滚
if [ -d "$APP" ]; then rm -rf ".build-old" && mv "$APP" ".build-old"; fi
if ! mv "$STAGE" "$APP"; then
  echo "✗ 换上新 bundle 失败" >&2
  [ -d ".build-old" ] && mv ".build-old" "$APP" && echo "  已回滚到构建前的 app" >&2
  exit 1
fi
rm -rf ".build-old"

# 若 LaunchAgent 已装：构建会 rm -rf 掉正在运行的 app bundle，老进程虽仍持旧 inode
# 能跑，但跑的是旧二进制、且构建期间状态不稳（2026-07-25 check.sh 第 6 项因此偶发假红）。
# 构建后重启它，让常驻实例真正用上新二进制 —— 这本来就是构建后该有的行为。
# ⛔ 2026-07-26 修:这段**从写下起就没执行过一次**。
# 原写法 `if launchctl list 2>/dev/null | grep -q ...` —— `grep -q` 命中后立刻关管道,
# `launchctl` 吃 SIGPIPE 返回非零,而本脚本开了 `set -o pipefail` → **整条管道判假,分支永远跳过**。
# 后果:build.sh 一直声称"重启它以载入新二进制",实际常驻只在 `install-agent.sh install` 时才换二进制。
# ⚠ 这是**同一个 pipefail 坑的第二次现身** —— check.sh 第 6 项的注释里逐字记着它
#   (「别写成 $BIN | grep -q —— 本脚本开了 pipefail」),而这里同样的写法没人看见。
# 教训:管道结果先落变量再判,别在 `if` 里直接接 `| grep -q`。
LL=$(launchctl list 2>/dev/null || true)
if grep -q local.tingzhe.ptt <<<"$LL"; then
  echo "检测到 LaunchAgent 已装 → 重启它以载入新二进制"
  OLDPID=$(pgrep -f "$PWD/tingzhe.app/Contents/MacOS" | head -1 || true)
  # ⛔ 重启**之前**打时间戳 —— 底下的就绪判定要用它把「旧日志」和「新实例写的」分开。
  MARKTS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # ⛔⛔ 这里原来有个 `|| { launchctl unload …; launchctl load …; }` 兜底 —— 已删。
  # `unload`(=bootout)**必掉辅助功能授权**,而只有 作者 本人能恢复(TCC 不接受程序代授);
  # 本项目的硬性禁区是「永远不要对常驻跑 bootout/unload」。
  # 把它放在 `|| ` 后面 = 平时看不见,kickstart 一旦失败就**自动执行禁区命令**,
  # 而那一刻没人在看。2026-07-27 作者 就是这样同一天第三次被赶去系统设置。
  # ⇒ 宁可重启失败并如实报出来(底下的 NEWPID 判定会判红),也不许自己"修好"。
  if ! launchctl kickstart -k "gui/$(id -u)/local.tingzhe.ptt" 2>/dev/null; then
    echo "  ⚠ kickstart 失败 —— **不**自动 unload/load(那会打掉你的辅助功能授权)。"
    echo "    要重启请自己跑: launchctl kickstart -k \"gui/\$(id -u)/local.tingzhe.ptt\""
  fi
  # ⛔ 等的必须是「**新**进程起来了」,不是「有进程在跑」——
  # 原来的 `pgrep >/dev/null && break` 在旧进程还活着时第一轮就 break,
  # 于是即便重启失败也报成功(自己给自己发了通行证)。
  NEWPID="$OLDPID"
  for _ in $(seq 1 24); do
    sleep 0.5
    NEWPID=$(pgrep -f "$PWD/tingzhe.app/Contents/MacOS" | head -1 || true)
    [ -n "$NEWPID" ] && [ "$NEWPID" != "$OLDPID" ] && break
  done
  if [ -n "$NEWPID" ] && [ "$NEWPID" != "$OLDPID" ]; then
    # ⛔ 换了 PID ≠ 已就绪。新实例还要几百毫秒才写完启动日志,而 check.sh 第 6 项读的正是那段 ——
    # 只等 PID 会让它读到空窗,然后报「读不到常驻日志」的 WARN(2026-07-26 实测踩到)。
    # 等的必须是**就绪信号本身**。
    # ⛔ F5(独立复核实测):原来这个循环的**结果被丢弃**,底下那句 ✓ 无条件打印 ——
    # 空日志 / 旧进程的日志段 / 明写"未授权" 三种状态输出同一行 ✓。
    # 这是「自己给自己发通行证」第三次现身。现在结果落变量、✓ 有条件。
    # ⛔ F8:别写 `awk ... | grep -q` —— 段落超过管道缓冲时 grep -q 提前关管道,
    # awk 吃 SIGPIPE 返 141,pipefail 把整条判假(命中了也判没命中)。先落变量再判。
    # ⛔⛔ 2026-07-26 独立复核实测:原来这里**只查「段里有没有就绪」,不比时间戳** ——
    # 守护进程只要**曾经**就绪过一次,这个条件在第 0 轮循环就成立。独立复核喂一份 2020 年的、
    # 且明写「未授辅助功能权限」的旧日志,0.666 秒就拿到 `✓ 常驻实例已换新进程并写出就绪`。
    # check.sh 第 6 项为同一件事做了 SEGTS > MTS 比对,这里没有 —— 同一个判据两处实现不一致,
    # 而弱的那处正好在「重启是否成功」这个最需要它的位置上。
    AXLOG="${TINGZHE_LOG_DIR:-$HOME/Library/Logs/tingzhe}/app.log"
    READY=0
    for _ in $(seq 1 24); do
      if [ -s "$AXLOG" ]; then
        SEG=$(awk '/\] 热键: /{b=""} {b=b $0 "\n"} END{printf "%s", b}' "$AXLOG" 2>/dev/null || true)
        if grep -q "就绪" <<<"$SEG"; then
          # 段首那行的 ISO8601 时间戳必须**晚于**我们重启前打的标记,否则这就是旧日志
          SEGTS=$(grep -o '^[0-9-]\{10\}T[0-9:]\{8\}Z' <<<"$SEG" | tail -1 || true)
          if [ -n "$SEGTS" ] && [[ "$SEGTS" > "$MARKTS" ]]; then READY=1; break; fi
        fi
      fi
      sleep 0.5
    done
    if [ "$READY" = "1" ]; then
      echo "  ✓ 常驻实例已换新进程并写出就绪（PID $OLDPID → ${NEWPID}）"
    else
      echo "  ⚠ 换了进程（PID $OLDPID → ${NEWPID}）但 12 秒内没等到就绪日志"
      echo "    → 它可能起不来。看 ${AXLOG}，或 ./install-agent.sh status"
    fi
  else
    echo "  ⚠ 常驻实例没换进程（PID 仍为 ${NEWPID:-无}）→ 它跑的还是旧二进制"
    echo "    用 ./install-agent.sh install 强制换"
  fi
fi

# TCC 的辅助功能授权认的是**签名的 designated requirement**。
# 用本机自签身份签名时它是 `identifier "…" and certificate leaf = H"…"` ——
# 跟二进制内容无关,所以改源码重建**不会**掉授权(2026-07-28 实证:CDHash 变、单键热键照常)。
# 只有 designated 本身变了(换签名身份 / 退回 ad-hoc / 没签成)才真的要重授。
# ⛔ F11:原来 `[ -f .last-cdhash ] && [ ... != ... ]` 在文件缺失时 REGRANT=0 —— 而
# 新克隆/换机/清过工作区之后的**第一次**构建正是授权百分之百已失效的那一次,
# 却是唯一一个字都不说的构建。缺文件按「已变」处理(fail-safe)。
REGRANT=0
if [ ! -f .last-designated ]; then
  REGRANT=1
  echo "  （首次构建：没有 .last-designated 基线 → 按「授权已失效」处理）"
elif [ "$(cat .last-designated)" != "${NEWSIG}" ]; then
  REGRANT=1
fi
echo "${NEWSIG}" > .last-designated

echo "✓ 构建完成 → $(pwd)/$APP"

# ⛔ 警告必须打在**最后**。原来它打在 "✓ 构建完成" 之前 → 成功行是最后一屏，警告滚上去了。
# 更重要的是:原来它**只是一句 echo**,没有任何东西依赖它 —— 2026-07-26 实证:我在本 session
# 第一次构建就收到了这条警告、读到了、然后连着又构建了五次,直到 session 末尾才报给 作者,
# 期间 作者 一直在退化状态(三键热键 + 只进剪贴板)下用工具。
# 「警告写对了但没有东西依赖它」= 它等于不存在。故:写 marker,让 check.sh 第 6 项据此判**红**。
if [ "$REGRANT" = "1" ]; then
  date -u +%Y-%m-%dT%H:%M:%SZ > .ax-regrant-needed
  echo
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║ ⚠ 签名的 designated 变了 → 辅助功能授权需要重授一次          ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"
  echo "  只有换签名身份/退回 ad-hoc/没签成才会走到这里。普通改代码重建**不会**掉授权。
  现在的实际状态：热键退化为三键 ⌃⌥Space · 自动粘贴退化为只进剪贴板"
  echo "  恢复（只有你本人能做，TCC 不接受程序代授）："
  echo "    1. 系统设置 → 隐私与安全性 → 辅助功能 → 移除旧的 tingzhe"
  echo "    2. 重新加 $(pwd)/$APP"
  echo "    3. ./install-agent.sh install"
  echo "  ⚠ 在此之前 ./check.sh 第 6 项会判**红** —— 这是故意的：不让「工具在退化状态」变成隐形。"
  echo "     真要接受退化状态：TINGZHE_ACCEPT_NO_AX=1 ./check.sh"
fi
echo
echo "启动（前台跑，能看日志，Ctrl-C 退出）:"
echo "  ./$APP/Contents/MacOS/tingzhe"
