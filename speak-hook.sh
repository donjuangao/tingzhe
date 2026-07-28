#!/bin/bash
# Stop 钩子 —— ⛔ 2026-07-28 起它**不再念任何东西**。
#
# 病:它和 speak-watch.py(边写边念)靠「对方在不在跑」的 pgrep 互斥,
#    而那是**瞬时判断**。speak-watch 在每次开关语音模式时都会退出,
#    只有下次 UserPromptSubmit 才被拉起 —— 中间那个窗口里本钩子一看"没人在跑",
#    就把**整段**念了;几秒后 watcher 回来又念它那份。
#    实测 2026-07-28 10:58:19 兜底念了 1670 字,10:58:24 watcher 起来接着念 → **两个声音同时响**。
#    作者 原话:「你到底在我的机器里运行了几套语音程序，我现在都不知道了」。
#
# ⇒ 不是再加一层互斥(两个进程各自的守卫都会"通过",因为它们看的是不同时刻),
#   是**把第二条路删掉**。speak-watch 在每一轮 UserPromptSubmit 都会被拉起,
#   作者 发起的每一轮它都在;兜底覆盖的只是"watcher 中途死了"这种少见情况,
#   而代价是整段一次念 + 撞车。**一条路胜过两条各自正确的路。**
#
# 现在它只做一件事:确保 watcher 活着。念由 watcher 一家负责。
DIR="${TINGZHE_DIR:-$HOME/Downloads/tingzhe}"
STATE="$HOME/Library/Caches/tingzhe"
LOG="$HOME/Library/Logs/tingzhe/speak.log"
mkdir -p "$(dirname "$LOG")"

[ -f "$STATE/voice-on" ] || exit 0          # 语音模式没开 → 什么都不做

if ! pgrep -f "speak-watch.py" >/dev/null 2>&1; then
  ( "$DIR/speak-watch.py" >/dev/null 2>&1 & )
  echo "$(date -u +%FT%TZ) 拉起边写边念（本钩子只负责这个，不再自己念）" >>"$LOG"
fi
exit 0
