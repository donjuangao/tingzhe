#!/bin/bash
# 装/卸 LaunchAgent：开机自启 + 崩溃自动拉起
# ⛔ 未经 作者 拍板不要跑。用法：./install-agent.sh install|uninstall|status
set -euo pipefail
cd "$(dirname "$0")"

LABEL="local.mossconnect.ptt"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$PWD/moss-ptt.app/Contents/MacOS/moss-ptt"
# ⛔ 日志必须写 ~/Library/Logs —— 2026-07-22 踩过的坑：launchd 自己在 exec 之前打开
# StandardOut/ErrorPath，而它对 ~/Downloads 无权限 → 配置阶段退 78、程序压根没启动、
# stderr 恒空、KeepAlive 累计重拉 28,062 次。（这条是在另一个项目上先踩到的）
# ⛔ F15(2026-07-26 独立复核实测):二进制不存在时本脚本照样报「已装」,并把
# `-  78  local.mossconnect.ptt`(自己注释里点名的死亡签名:配置阶段退 78 + KeepAlive 无限重拉)
# 当状态原样展示却从不解析。「构建失败 → install-agent install」这条最自然的补救序列,
# 产出的是一个对着空路径无限重拉的 job,而报告是「已装」。故先查存在性。
LOGDIR="$HOME/Library/Logs/moss-ptt"

case "${1:-}" in
install)
    # F15 存在性检查 —— 不许对着不存在的二进制报「已装」
    if [ ! -x "$BIN" ]; then
      echo "✗ 找不到可执行的 $BIN"
      # ⛔ C-6(独立复核抓):这里原来写 `./build.sh` —— 而正式构建 2026-07-26 起需要
      # MOSS_REAL_BUILD=1,裸跑会退 3。**一条教人跑必然失败的命令的提示,比没有提示更坏。**
      echo "  先跑：MOSS_REAL_BUILD=1 ./build.sh"
      echo "  （⛔ 会打掉辅助功能授权，需你重授一次；只想编译自检用 ./build.sh --dev）"
      exit 1
    fi
  mkdir -p "$LOGDIR"
mkdir -p "$HOME/Library/LaunchAgents"   # F16:新账号上默认不存在,不建会以一句裸重定向错误失败
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <!-- 2026-07-25 实测定论：TCC 授权条目是**二进制** Contents/MacOS/moss-ptt
       （系统弹窗自动加的那条，图标为通用可执行文件、名称 moss-ptt）。
       一度改走 open -W -a 想让 TCC 认 app 身份（⛔ 此注释在 heredoc 内，不可用反引号：会被 shell 当命令执行），反而使 responsible process
       变成 /usr/bin/open、对不上已授权的条目 → 权限永远拿不到。故改回直接指向二进制。 -->
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOGDIR/out.log</string>
  <key>StandardErrorPath</key><string>$LOGDIR/err.log</string>
  <key>EnvironmentVariables</key><dict>
    <key>MOSS_CONNECT_DIR</key><string>$PWD</string>
  </dict>
</dict></plist>
PLISTEOF
  # ⛔⛔ 2026-07-27 实测两件事,合起来定了下面这个分支:
  # ① **`unload`+`load`（= bootout+bootstrap）会打掉辅助功能授权**,而 `kickstart -k` 不会。
  #    当天实证:21:16 的常驻还是「按住 右 ⌥（单键）」,我 bootout+bootstrap 之后立刻退化成
  #    「⌃⌥Space」,再跑一次 install 也救不回来 —— 只能 作者 去系统设置重授。
  # ② **build.sh 已经会 kickstart 一次**;它和这里的 load 背靠背跑会撞出一个
  #    「进程在跑但没拿到单实例锁」的状态(实测 PID 稳定 15s+ 恒不握锁,第二个实例不被拒 =
  #    按一次录两次),而且 `kickstart -k` 修不好,只有整套 bootout+bootstrap 能。
  # ⇒ **job 已经装着就只 kickstart(保住授权),没装才 load。**
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "  job 已注册 → 只重启它（⛔ 不 unload/load：那会打掉辅助功能授权）"
    pkill -f "moss-ptt.app/Contents/MacOS" 2>/dev/null || true
    sleep 1
    launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true
    sleep 2
    echo "已装。状态："
    launchctl list | grep "$LABEL" || echo "  ⚠ 没在 list 里，检查 $LOGDIR/err.log"
    exit 0
  fi
  # ⛔ 必须显式杀掉 app 进程本身。plist 走 `open -W -a`（为了让 TCC 认 app 身份），
  # 而 launchctl unload 只杀得掉 open 那个壳 —— app 是 LaunchServices 起的独立进程，
  # 不受 launchd 管，会活下来；重新 load 时 open 发现它还在就直接返回，进程根本没换。
  # 后果：改了权限/配置后重装 agent 看似成功，实际跑的还是老进程（2026-07-25 踩到，
  # 作者 已勾上辅助功能开关，却因进程没换而一直显示无权限）。
  pkill -f "moss-ptt.app/Contents/MacOS" 2>/dev/null || true
  sleep 1
  launchctl load "$PLIST"
  sleep 2
  echo "已装。状态："
  launchctl list | grep "$LABEL" || echo "  ⚠ 没在 list 里，检查 $LOGDIR/err.log"
  echo "日志：$LOGDIR/"
  ;;
uninstall)
  launchctl unload "$PLIST" 2>/dev/null || true
  pkill -f "moss-ptt.app/Contents/MacOS" 2>/dev/null || true
  rm -f "$PLIST"
  echo "已卸。日志目录 $LOGDIR 保留，要清自己删。"
  ;;
status)
  launchctl list | grep "$LABEL" || echo "未安装或未运行"
  echo "--- 最近日志 ---"
  tail -5 "$LOGDIR/err.log" 2>/dev/null || echo "(无)"
  ;;
*)
  echo "用法: $0 install|uninstall|status"; exit 2 ;;
esac
