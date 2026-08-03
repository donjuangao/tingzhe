#!/bin/bash
# 判卷闸 L1 · 每次收尾必须全绿才算完成
# 十项全是机械可判的:能跑出退出码,不靠人主观说"看起来没问题"
set -uo pipefail
cd "$(dirname "$0")"

# ⛔ F5(独立复核实测):二进制的 projectDir 硬编码 ~/Downloads/tingzhe（或 TINGZHE_DIR），
# **与 cwd 无关**。于是在任何 clone / git worktree 里跑闸：第 3/4 项验你改的表，
# 第 8/9/10 项和 --apply 验的是生产那张表，两半互不知情却都打绿；
# 更糟的是第 10 项 --selftest-reload 会**写**生产 dict.json。项目自己的派工规范用 worktree。
# → 把引擎的项目目录钉到本 checkout。
export TINGZHE_DIR="$PWD"

FAIL=0
BIN0="tingzhe.app/Contents/MacOS/tingzhe"
DEVBIN="build/dev/tingzhe"
pass() { printf "  ✅ %s\n" "$1"; }
fail() { printf "  ❌ %s\n" "$1"; FAIL=1; }
warn() { printf "  ⚠️  %s\n" "$1"; }

# ⛔ F-8:本脚本第一行就宣称「闸不许有破坏性副作用」,而独立复核实测它会写 dict.json 的 mtime、
# 往生产日志目录追加自检记录。会写东西的自检一律赶进沙箱 —— 让那句宣称成为真的。
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/moss-check.XXXXXX")
mkdir -p "$SANDBOX/logs"
for f in dict.json canon.json protect.json config.json .env.local; do
  [ -f "$f" ] && cp "$f" "$SANDBOX/" 2>/dev/null || true
done
trap 'rm -rf "$SANDBOX"' EXIT

# ⛔ 刚 clone 下来的状态:没有 tingzhe.app,于是第 6/7/8/10/12 项全红,
# 而红的原因跟他的代码毫无关系 —— 满屏「踩过的坑 #1 的形状」是最劝退的第一印象。
# ⇒ 一条能照做的话,而不是八条吓人的红。⚠ 仍然 exit 非零:**没测就是没测**,不假装通过。
if [ ! -x "tingzhe.app/Contents/MacOS/tingzhe" ]; then
  echo "⚪ 还没构建过 —— 有 5 项要拿真的 app 才能测（启动/主路径/热重载/语音开关…）"
  echo
  echo "   先跑：./build.sh"
  echo "   然后：./check.sh"
  echo
  echo "   （./build.sh --dev 只编译到 build/dev/，不打 bundle，那 5 项仍然测不了）"
  exit 2
fi

echo "[1/12] 编译（--dev · ⛔ 闸不许有破坏性副作用）"
# ⛔ F3(2026-07-26 独立复核实测):原来这里跑的是**非 --dev** 的 build.sh ——
# 于是每一次收尾跑闸都覆盖真 tingzhe.app 一次,把刚加的 `--dev` 安全路径整个绕掉了。
# 本项目要求「收尾必跑 ./check.sh」⇒ 闸自己成了掉权限的主要来源。
# **闸的职责是判定,不是改变被判对象。** 编译检查用 --dev 就够。
# 真 app 是否落后于源码,单独报（见下方 ⓪），由 作者 决定何时正式构建。
if ./build.sh --dev >/tmp/moss-build.log 2>&1; then
  if grep -q "error:" /tmp/moss-build.log; then fail "swiftc 报 error(见 /tmp/moss-build.log)"; else
    W=$(grep -c "warning:" /tmp/moss-build.log || true)
    [ "$W" -gt 0 ] && warn "$W 条 warning" || pass "编译干净"
    [ "$W" -gt 0 ] && pass "编译通过"
  fi
else
  fail "build.sh 退出码非 0"
fi

# ⓪ 真 app 是否落后于**源码** —— 只报,不动它
# ⛔ 别拿 `cmp` 比真 app 与 dev 二进制:两者是**不同时刻**的两次编译,dev 只要没跟着重编就字节不等
# → 刚正式构建完也会亮警告 = 恒亮 = 等于没有警告(2026-07-26 实测,我上一条差点把它挂成待办)。
# 该问的是「真 app 比源码新吗」,所以比 mtime,和 dev 无关。
if [ -x "$BIN0" ]; then
  NEWER=$(find src config.json -newer "$BIN0" -type f 2>/dev/null | head -3 || true)
  if [ -z "$NEWER" ]; then
    pass "真 app 不比源码旧"
  else
    warn "真 app 落后于源码 → 想生效跑 TINGZHE_REAL_BUILD=1 ./build.sh（⛔ 会打掉辅助功能授权）"
    printf '     比它新的: %s\n' $NEWER
  fi
fi

echo "[2/12] 配置文件合法性"
python3 - <<'EOF'
import json, os, sys
# 用户文件读不到就退回 .example —— 跟程序 readableProjectFile 同一个口径。
# ⛔ 没有这条，刚 clone 的人跑闸会看到「config.json 解析失败」，而那跟他毫无关系。
def _uf(n): return n if os.path.exists(n) else n.replace(".json", ".example.json")
ok = True
try:
    c = json.load(open(_uf('config.json')))
    # ⛔ 合法值从**产品**取（--list-ptt-keys），不在这里抄第二份。
    #   抄的那份 2026-07-28 落后了:pttChoices 扩到 9 个,闸还是 5 个,
    #   作者 从面板选 leftOption 就判红 —— 而产品是对的。
    import subprocess as _sp
    _eng = os.environ.get("TINGZHE_ENGINE", "build/dev/tingzhe")
    _r = _sp.run([_eng, "--list-ptt-keys"], capture_output=True, text=True)
    allowed = {x.strip().lower() for x in _r.stdout.split() if x.strip()}
    # ⛔ F9(2026-07-26 独立复核实测):原允许集里带着 rightCommand —— 而 config.json 与
    # src/main.swift 开头都写着右⌘ 是 ⌘C/⌘V/⌘Tab 的修饰键,⌘Tab 切窗口会误录环境音并粘出去
    # (2026-07-25 判官 #4 抓出)。一个名叫「配置文件合法性」的检查把已知会造成误录+误粘的值算作合法。
    # ⚠ 2026-07-28 作者 拍「不要给人家设这么多限制…他愿意误触是他的事情」:
    #   右⌘ 从**判红**降为**提醒** —— 产品已经允许它了,闸比产品严就是第三份真相。
    risky = {"rightcommand": "右⌘ 是 ⌘C/⌘V/⌘Tab 的修饰键，⌘Tab 切窗口会误录并粘出去"}
    hk = c.get("hotkey")
    hkl = str(hk).lower()          # ⛔ allowed 来自产品输出且已小写,这里不对齐就永远判红
    if hkl in risky:
        print(f"  ⚠ config.json hotkey={hk!r}：{risky[hkl]}（你选的就是它，只是提醒）")
    if hkl not in allowed:
        print(f"  ❌ config.json hotkey={hk!r} 不在允许集 {sorted(allowed)}"); ok = False
    else:
        print(f"  ✅ config.json hotkey={hk}（合法值取自产品 --list-ptt-keys，不是抄的第二份）")
except Exception as e:
    print(f"  ❌ config.json 解析失败: {e}"); ok = False
sys.exit(0 if ok else 1)
EOF
RC=$?; [ "$RC" -ne 0 ] && FAIL=1

echo "[3/12] 词表结构（顺序/空值/自替换/重复）"
python3 - <<'EOF'
import json, os, sys
def _uf(n): return n if os.path.exists(n) else n.replace(".json", ".example.json")
ok = True
try:
    rules = json.load(open(_uf('dict.json')))
except Exception as e:
    print(f"  ❌ dict.json 解析失败: {e}"); sys.exit(1)
srcs = []
for i, r in enumerate(rules):
    if not isinstance(r, list) or len(r) != 2:
        print(f"  ❌ 第 {i} 条不是 [错,对] 二元组: {r!r}"); ok = False; continue
    a, b = r
    if not a: print(f"  ❌ 第 {i} 条替换源为空"); ok = False
    if a == b: print(f"  ❌ 第 {i} 条自替换无意义: {a!r}"); ok = False
    if a in srcs: print(f"  ❌ 第 {i} 条替换源重复: {a!r}"); ok = False
    srcs.append(a)
# 顺序铁律:若 A 是 B 的子串,A 必须排在 B 之后,否则 A 先咬掉一段导致 B 永不命中
for i, a in enumerate(srcs):
    for j, b in enumerate(srcs):
        if i < j and a and b and a in b:
            print(f"  ❌ 顺序错: 第 {i} 条 {a!r} 是第 {j} 条 {b!r} 的子串,短模式必须排后面")
            ok = False
# ⛔ F10(独立复核实测):原来只查「规则源之间」的子串序,不查**级联** ——
# `甲→乙丙` + `乙丙→丁` 会让第一条永远产不出 `乙丙`(实测 「这是测试甲的例子」→「这是丁的例子」),
# 而第 3/4/8/9/10 项全绿。`--fix` 已拒绝这种插入,但手工编辑绕过 --fix 就没人管了 → 闸比工具还宽。
# ⛔ C-1(独立复核实测):上面这版**不看先后**,于是把两种**相反**的情况判成同一条错误诊断 ——
# `[["乙丙","XX"],["甲","乙丙"]]` 引擎跑出来是 `甲 → 乙丙`(**完全正确**,因为 乙丙→XX 排在前面、
# 轮到它时还没有 乙丙),照样判红;而 `[["甲","乙丙"],["乙丙","XX"]]` 才是真级联(`甲 → XX`)。
# 一条对正确与错误给同一句话的诊断,读的人无法据此行动 —— 这正是第 9 项刚犯过的病。
# ⭐ 判据只差一个字:`applyDict` 按顺序逐条全文替换 ⇒ **只有排在后面(j > i)的规则才吃得到第 i 条的输出。**
pairs = [(r[0], r[1]) for r in rules if isinstance(r, list) and len(r) == 2]
for i, (a, b) in enumerate(pairs):
    for j, (c, d) in enumerate(pairs):
        if j > i and c and c in b:
            print(f"  ❌ 级联: 第 {i} 条 {a!r}→{b!r} 的**结果**含第 {j} 条的模式 {c!r},"
                  f"而第 {j} 条排在它后面 → 会被继续替换成 {d!r},第 {i} 条永远产不出正确结果")
            ok = False
if ok: print(f"  ✅ 词表 {len(rules)} 条结构合法、顺序正确、无级联")
# 误伤风险提示(不判失败,只提醒人看)
risky = [a for a in srcs if len(a) <= 2 and all('一' <= ch <= '鿿' for ch in a)]
if risky: print(f"  ⚠️  高误伤风险规则(≤2 个汉字,会无条件全文替换): {risky}")
sys.exit(0 if ok else 1)
EOF
RC=$?; [ "$RC" -ne 0 ] && FAIL=1

echo "[4/12] 词表回归（拿真实错例断言修复效果 · ⛔ 走真引擎）"
# ⛔ F1(2026-07-26 独立复核实测 · 本闸最深的一个洞):这一项原来在 Python 里**重写了一遍 applyDict**,
# 于是它的绿灯与产品行为完全无关。实证:同一句输入 ——
#   Python oracle → "Let me edit 的 propsd content"   （它自己还带着第 9 项存在的理由那个 bug）
#   真实产品      → "Let me edit the proposed content"（词边界护栏生效）
# 独立复核把 applyDict 改成「第一条命中就停」,产品 3 处只修 1 处,而**整条十项闸全绿**。
# ⚠ 更难看的是:第 8 项的注释里我自己写着「重写就是重写一个不同的东西(第 4 项曾犯过这个错)」——
#    写了这句话,却没修第 4 项。现在改由 `--apply` 走真引擎。
# ⛔ 2026-07-26 第三次现身:**闸编译 A 却拷问 B**。
# 原写法优先 ${BIN0}（app bundle），可 `--dev` 迭代纪律**故意不更新 app bundle** ——
# 于是第 1 项刚把当前源码编进 build/dev/，第 4/9 项转头去问一个更旧的二进制。
# 实证（改这行的那一刻）：main.swift 22:31 · dev 22:36 · app **22:13**，且 cmp 不同
# —— app 里那个二进制是由一份**已经不存在的源码**编出来的，而十项照样能全绿。
# → 改为**优先刚编出来的 $DEVBIN**，并且**把用了哪个二进制打出来**：
#   静默选二进制正是这个坑能藏三次的原因（第 4 项测 Python 副本 / 第 7 项测录音副本 / 本条）。
ENGINE=""
[ -x "$DEVBIN" ] && ENGINE="$DEVBIN"
[ -z "$ENGINE" ] && [ -x "$BIN0" ] && ENGINE="$BIN0"
export TINGZHE_ENGINE="$ENGINE"
if [ -z "$ENGINE" ]; then
  fail "找不到可用引擎（build/dev/tingzhe 或 tingzhe.app）"
else
  printf "  引擎 = %s\n" "$ENGINE"
  python3 - "$ENGINE" <<'EOF'
import subprocess, sys, unicodedata
engine = sys.argv[1]
def norm(s):
    # ⛔ C-2(独立复核实测):原来这里连**空白**一起删 —— 而 `front matter→frontmatter`、
    # `work tree→worktree` 这两条缺陷**就是空格**。删掉空白后,断言在**输入**上就已经成立:
    # norm("…front matter…") 里就含 "frontmatter" → 这两条对**任何**引擎恒真,包括什么都不做的引擎。
    # 一条恒真的断言不是宽松,是**这一项在这两个词上从来没有判别力**。
    # 现在只做 NFKC + 小写 + 去标点,**保留空白**。
    s = unicodedata.normalize("NFKC", s).lower()
    return "".join(c for c in s if not (unicodedata.category(c)[0] == "P"))
# ⛔ 2026-07-28 开源化:用例原来是**写死的作者本人句子**(含三个私有项目名)。
# 换成从**当前实际生效的那份词表**自动构造 —— 取前几条规则,把「错的写法」拼进一句话,
# 断言真引擎把它们全改对。这比写死更强:它对**任何人的词表**都成立,
# 而写死的用例只证明"作者那三条规则还在"。
# ⚠ 读的是 dict.json,没有就退回 dict.example.json —— 跟程序自己那条退回路径同一个口径。
import json, os
proj = os.environ.get("TINGZHE_DIR") or os.path.dirname(os.path.abspath(__file__))
rules = []
for n in ("dict.json", "dict.example.json"):
    p = os.path.join(proj, n)
    if os.path.exists(p):
        rules = json.load(open(p)); break
if not rules:
    print("  ⚪ 词表为空（dict.json 与 dict.example.json 都没有）→ 本项不适用")
    sys.exit(0)
# 一次最多验 5 条,拼成一句话走一次真引擎(每条单独调一次太慢)
picked = rules[:5]
cases = [("。".join(w for w, _ in picked) + "。", [r for _, r in picked])]
ok = True
for src, musts in cases:
    r = subprocess.run([engine, "--apply", src], capture_output=True, text=True)
    out = norm(r.stdout.strip())
    miss = [m for m in musts if norm(m) not in out]   # ⛔ musts 也要 norm:norm() 小写化,
                                                     #   带大写的期望值(TypeScript)否则永远找不到
    if miss:
        print(f"  ❌ 回归失败,未修复: {miss}")
        print(f"     输入: {src}")
        print(f"     真引擎输出: {r.stdout.strip()}")
        ok = False
if ok: print(f"  ✅ 词表前 {len(picked)} 条规则走真引擎全部命中（{engine}）")
sys.exit(0 if ok else 1)
EOF
  RC=$?; [ "$RC" -ne 0 ] && FAIL=1
fi

echo "[5/12] 密钥未入库"
if [ -d .git ]; then
  if git ls-files --error-unmatch .env.local >/dev/null 2>&1; then
    fail ".env.local 已被 git 追踪 —— 密钥有泄漏风险!"
  else
    pass ".env.local 未入库"
  fi
  # 匹配真实密钥形态(sk- 后接 ≥20 位),而不是裸 "sk-" ——
  # 否则 README 里的占位符 sk-... 会误报(2026-07-25 首次跑闸即踩)
  # ⛔ F7(2026-07-26 独立复核实测):原来只 `git grep` —— 它**只扫 tracked 文件**。
  # 而泄漏风险最高的时刻恰好是「刚粘进一个新文件、还没 commit」;git 历史里的也扫不到,
  # 而本项目装了 pre-push:闸绿就放行,一个已进历史的密钥可以直接推出去。
  KEYPAT="sk-[A-Za-z0-9_-]{20,}"
  RED='s/sk-[A-Za-z0-9_-]*/sk-<REDACTED>/g'
  # ① 工作区全部文件（含未跟踪），排掉 .git / 二进制 / gitignore 掉的语音文件
  WT=$(grep -rIlE "$KEYPAT" . \
        --exclude-dir=.git --exclude-dir=build --exclude-dir=tingzhe.app \
        --exclude-dir=__pycache__ --exclude=check.sh --exclude=.env.local 2>/dev/null || true)
  # ② git 历史
  # ⛔ 用**真实密钥形态**(sk- 后接 ≥20 位),不是裸 "sk-" ——
  # 裸 sk- 会命中 README 占位符与 check.sh 自己的正则。
  # ⚠ 这个坑早期修过一次（当时的结论是:
  #   匹配真实密钥形态而非裸 sk-），我在新加的历史扫描里又犯了一遍，当场被自己的闸抓出。
  HIST=$(git log --all -S"$KEYPAT" --oneline --pickaxe-regex 2>/dev/null | head -3 || true)
  if [ -n "$WT" ]; then
    fail "工作区里出现疑似真实密钥（含未跟踪文件）"
    printf '     %s\n' $WT
  elif [ -n "$HIST" ]; then
    fail "git 历史里出现疑似密钥 —— 工作区干净不代表推出去是安全的"
    sed "$RED" <<<"$HIST" | sed 's/^/     /'
  else
    pass ".env.local 之外无密钥字面量（工作区含未跟踪 + git 历史都扫过）"
  fi
else
  warn "尚未 git init,跳过密钥入库检查"
fi

echo "[6/12] 启动冒烟"
BIN="tingzhe.app/Contents/MacOS/tingzhe"
if [ ! -x "$BIN" ]; then
  # ⛔ C-6:fresh clone 里 tingzhe.app 是 gitignore 的 → 这条是**新克隆的默认状态**,
  # 只报「不存在」而不说下一步 = 让人自己猜。且正式构建需要 TINGZHE_REAL_BUILD=1(裸跑退 3)。
  fail "$BIN 不存在或不可执行 —— 新克隆的默认状态（app bundle 不入库）"
  printf "     要装常驻/走完整闸: TINGZHE_REAL_BUILD=1 ./build.sh && ./install-agent.sh install\n"
  printf "     只想跑纯文本自检: ./build.sh --dev（其余各项都会用它,不需要 app）\n"
elif pgrep -f "^$PWD/tingzhe.app/Contents/MacOS/tingzhe$" >/dev/null; then
  # 已有实例在跑（多半是常驻 LaunchAgent）→ 起不来是**正确行为**，不是故障。
  # 此时改验两件同样有效的事，避免闸因常驻而永远红（闸永远红 = 人开始忽略它 = 闸失效）。
  # ⛔ 别写成 `"$BIN" 2>&1 | grep -q ...` —— 本脚本开了 pipefail，而 $BIN 被锁拒时
  # 退出码是 1（这正是预期行为），会污染管道退出码，导致 grep 明明匹配到却判失败。
  # 2026-07-25 踩过：连红三次，锁一直是好的，错的是这里。先落变量再判。
  # ⛔ 2026-07-26 修两个病（本项间歇性假红，单独跑 3/3 全对，混在闸里就偶发失败）：
  # ① **竞态**：第 1 项的 build.sh 刚重启常驻，这里就测锁 → 撞上守护进程的空窗，
  #    锁没人持 → 第二个实例成功拿到锁 → 报「没被锁拒」。先等它稳住（同一 PID 连续两次）。
  # ② **能把闸挂死**：万一 $BIN 真拿到锁，它会一路走到 `app.run()` 永不返回，
  #    而 `$(...)` 会一直等 → 闸卡住不是红也不是绿。必须给它硬超时。
  for _ in 1 2 3 4 5 6; do
    A=$(pgrep -f "^$PWD/tingzhe.app/Contents/MacOS/tingzhe$" | head -1 || true)
    sleep 1
    B=$(pgrep -f "^$PWD/tingzhe.app/Contents/MacOS/tingzhe$" | head -1 || true)
    [ -n "$A" ] && [ "$A" = "$B" ] && break
  done
  LOCKOUT=""
  # ⛔⛔ 2026-07-30(指纹仪 P4 逮到):这次冒烟**无参启动** ⇒ 引擎判它不是一次性命令
  #   ⇒ 锁拒绝那行落进**生产** app.log。每跑一次闸追加 173 字节。
  #   这不是洁癖:ENGINEERING-NOTES.md 逐字记着「每跑一次 check.sh 就往 app.log 追加数行,
  #   把常驻实例的『就绪 / 未授辅助功能权限』挤出读取窗口 → **第 6 项的权限检测会被静默弄哑**」。
  #   ⇒ **闸自己在污染它下一步要读的那个文件。**
  #   当初修的是「一次性命令不写 app.log」那条腿(isOneShot),漏了「无参启动」这条 ——
  #   同一件事两条腿,只修了有名字的那条。
  # ⚠ 只能给**这一条命令**加前缀,不许 export:下面第 305 行的权限检测**必须**读生产 app.log,
  #   export 了它就会去读沙箱,闸自己把自己弄瞎。
  PRODLOG="${TINGZHE_LOG_DIR:-$HOME/Library/Logs/tingzhe}/app.log"
  SMOKE_BEFORE=$( [ -f "$PRODLOG" ] && wc -c < "$PRODLOG" || echo 0 )
  for _ in 1 2 3; do
    # 后台起 + 2 秒后杀 —— 拿到锁也不会把闸挂住（macOS 无 timeout(1)，用这个既有模式）
    LOCKOUT=$(TINGZHE_LOG_DIR="$SANDBOX/logs" "$BIN" 2>&1 & P=$!; sleep 2; kill "$P" 2>/dev/null; wait "$P" 2>/dev/null) || true
    grep -q "已有一个 tingzhe 在跑" <<<"$LOCKOUT" && break
    sleep 1
  done
  if grep -q "已有一个 tingzhe 在跑" <<<"$LOCKOUT"; then
    pass "已有实例在跑；单实例锁正确拒绝了第二个"
  else
    fail "已有实例在跑，但第二个没被锁拒 —— 会双注册热键（按一次录两次）"
    printf "     第二个实例的输出: %s\n" "$(head -2 <<<"${LOCKOUT:-（空）}")"
  fi
  # ⛔ 判据:冒烟不许把一个字写进生产日志。见红方式 = 删掉上面那个 TINGZHE_LOG_DIR 前缀,这条立刻红。
  SMOKE_AFTER=$( [ -f "$PRODLOG" ] && wc -c < "$PRODLOG" || echo 0 )
  if [ "$SMOKE_BEFORE" = "$SMOKE_AFTER" ]; then
    pass "启动冒烟没碰生产日志（$PRODLOG 字节数不变）"
  else
    fail "启动冒烟往**生产**日志追加了 $((SMOKE_AFTER - SMOKE_BEFORE)) 字节 —— 而第 6 项自己要读这个文件判权限"
    printf "     追加的是: %s\n" "$(tail -c $((SMOKE_AFTER - SMOKE_BEFORE)) "$PRODLOG" | head -1)"
  fi
  # 读程序自己写的 app.log —— launchd 的 err.log 在 open -a 时期会空/滞后，
  # 用它判断权限状态会给出过期结论（2026-07-25 踩到：权限已好而闸仍 WARN）
  # ⛔ F-6(独立复核实测):原来这里硬编 $HOME —— 而引擎认 TINGZHE_LOG_DIR,闸不认。
  # 后果:独立复核在 /private/tmp 的副本里跑闸、TINGZHE_LOG_DIR 指向自己的假目录,
  # 第 6 项却报出了**生产守护进程**的时间戳 → 判的是 A checkout,权限结论来自 B 的进程。
  LOG="${TINGZHE_LOG_DIR:-$HOME/Library/Logs/tingzhe}/app.log"
  # ⛔ 别用 `tail -N` 取"最后一次启动" —— N 靠猜，噪音一多就静默失准
  # （2026-07-26 实测：我新加的第 8/10 项往 app.log 塞了 6 行，就把权限那两行挤出了 tail -8，
  #   于是这一整块降级成「读不到常驻日志」的 WARN，我刚加的红闸一次都没响过）。
  # 改为按"最后一个 `热键:` 行到文件尾"精确切出**最后一次启动那一段**，与噪音量无关。
  SEG=$(awk '/\] 热键: /{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$LOG" 2>/dev/null)
  if [ -s "$LOG" ] && grep -q "就绪" <<<"$SEG"; then
    pass "常驻实例日志到过就绪"
    # 只看最后一次启动那一段，否则历史上无权限的旧行会永远触发
    # ⛔ 2026-07-26:从 warn 升为 fail。理由 = 本 session 踩过的坑:build.sh 第一次构建就打了
    # 「授权已失效」的警告，我读到了、又连构建五次，作者 整个 session 都在退化状态下用工具而不知道。
    # 一句 warn 没有任何东西依赖它 = 等于不存在。退化状态必须让闸变红,否则它是隐形的。
    # 真要接受退化：TINGZHE_ACCEPT_NO_AX=1 ./check.sh（显式认账，不是默认静默）
    if grep -q "未授辅助功能权限" <<<"$SEG"; then
      if [ "${TINGZHE_ACCEPT_NO_AX:-0}" = "1" ]; then
        warn "常驻实例无辅助功能权限（已由 TINGZHE_ACCEPT_NO_AX=1 显式接受）"
      else
        fail "常驻实例无辅助功能权限 → 热键退化为三键 ⌃⌥Space、自动粘贴退化为只进剪贴板"
        printf "     恢复: 系统设置 → 隐私与安全性 → 辅助功能 → 移除旧 tingzhe → 重加 %s/tingzhe.app → ./install-agent.sh install\n" "$(pwd)"
        [ -f .ax-regrant-needed ] && printf "     （授权是在 %s 的那次构建里被打掉的）\n" "$(cat .ax-regrant-needed)"
        printf "     接受退化状态: TINGZHE_ACCEPT_NO_AX=1 ./check.sh\n"
      fi
    else
      # ⛔ F12(独立复核实测):原来这里无条件 `rm -f .ax-regrant-needed`。
      # 而判据是「最后一次启动那段没有『未授』」—— 当 build.sh 的重启白干、agent 没装、
      # 或常驻是手动起的时候,日志停在**构建前**那一段 → 闸读到的是旧进程的授权状态
      # → 判绿 + 把几秒前刚写的 marker 抹掉。**最需要它响的时候它不响。**
      # 现在要求:这段启动日志的时间戳必须**晚于** marker,才算真的重授过了。
      if [ -f .ax-regrant-needed ]; then
        SEGTS=$(grep -o '^[0-9T:-]*Z' <<<"$SEG" | head -1)
        MTS=$(cat .ax-regrant-needed)
        if [ -n "$SEGTS" ] && [[ "$SEGTS" > "$MTS" ]]; then
          pass "常驻实例有辅助功能权限（单键热键 + 自动粘贴可用）"
          rm -f .ax-regrant-needed
        else
          fail "读到的是**构建前**那次启动的日志（$SEGTS ≤ 标记 ${MTS}）→ 无法确认权限已恢复"
          printf "     常驻可能没被重启（它跑的还是旧二进制）。跑 ./install-agent.sh install 再看\n"
        fi
      else
        pass "常驻实例有辅助功能权限（单键热键 + 自动粘贴可用）"
      fi
    fi
  else
    warn "读不到常驻日志 ${LOG}（若非 LaunchAgent 启动则属正常）"
  fi
else
  OUT=$("$BIN" 2>&1 &
        P=$!; sleep 3; kill $P 2>/dev/null; wait 2>/dev/null)
  if grep -q "就绪" <<<"$OUT"; then pass "启动到就绪"; else fail "启动未到就绪: $(head -3 <<<"$OUT")"; fi
  grep -q "热键:" <<<"$OUT" && pass "热键注册成功" || fail "热键未注册"
  # ⛔ F-7(独立复核抓出):AX 退化红闸原来整块只住在上面那个「已有实例在跑」分支里,
  # 这个 else 分支(手动跑、没装 LaunchAgent)**既不查「未授辅助功能权限」也不查 marker**
  # → 正式构建打掉授权后,不装 agent 的用法拿到的是 **绿灯 + 三键热键 + 只进剪贴板**,
  # 正是 build.sh 花了十几行注释要消灭的那个状态。红闸不能只覆盖一半用法。
  if grep -q "未授辅助功能权限" <<<"$OUT" || [ -f .ax-regrant-needed ]; then
    if [ "${TINGZHE_ACCEPT_NO_AX:-0}" = "1" ]; then
      warn "无辅助功能权限（已由 TINGZHE_ACCEPT_NO_AX=1 显式接受）"
    else
      fail "无辅助功能权限 → 热键退化为三键 ⌃⌥Space、自动粘贴退化为只进剪贴板"
      [ -f .ax-regrant-needed ] && printf "     （授权是在 %s 的那次构建里被打掉的）\n" "$(cat .ax-regrant-needed)"
      printf "     接受退化状态: TINGZHE_ACCEPT_NO_AX=1 ./check.sh\n"
    fi
  fi
fi

echo "[7/12] 主路径自检（⛔ 驱动生产路径，不是它的副本）"
# ⛔ F2(独立复核实测):原来只跑 `--selftest-record`,而那是主路径的**一份复制品**
# (两处独立的 `r.currentTime` 读取),踩过的坑 #1 只要重新犯在生产那一处该项照旧绿;
# 它在空项目目录里都能过 = 连 Controller 都没构造。
# 新增 `--selftest-mainpath`:真调 Controller.startRecording/stopAndTranscribe/词表/deliver,
# 只把 transcribe(不出网) 与 deliver(不粘字) 换成占位。双向注入验证过:
# 把 currentTime 挪到 stop() 之后 → 退出码 1;还原 → 0。而 --selftest-record 对同一注入仍绿。
# ⚠ 这一项用 **dev 二进制**:它总是与当前源码一致,测的就是"我刚写的代码主路径通不通"。
# 真 app 是否落后于源码由 ⓪ 单独报 —— 一个事实只在一处判,别让本项因"旧二进制没这个子命令"
# 而喊出"踩过的坑 #1 的形状"(2026-07-26 实测踩到:诊断错了比不报更坏)。
if [ -x "$DEVBIN" ]; then
  # ⛔ F-8:闸不许有破坏性副作用,而这一项每跑一次就往**生产**日志目录追加 transcripts-selftest.jsonl。
  # 走沙箱日志目录 —— 断言的内容一个字不变(它测的是代码路径,不是日志落在哪)。
  MP=$(TINGZHE_SELFTEST_MAINPATH=1 TINGZHE_LOG_DIR="$SANDBOX/logs" "$DEVBIN" --selftest-mainpath 2>&1 || true)
  if grep -q "✓ selftest-mainpath" <<<"$MP"; then
    pass "生产路径 startRecording → stopAndTranscribe → 词表 → deliver 全通"
  elif grep -qE "需要 TINGZHE_SELFTEST_MAINPATH|Unknown|unrecognized" <<<"$MP" || [ -z "$MP" ]; then
    fail "dev 二进制不支持 --selftest-mainpath（构建没跟上？跑 ./build.sh --dev）"
  else
    fail "生产路径不通（踩过的坑 #1 的形状：录音时长 guard 或转写链路断了）"
    grep -E "✗|太短" <<<"$MP" | sed 's/^/     /'
  fi
else
  fail "缺 $DEVBIN —— 跑 ./build.sh --dev"
fi

# 2026-07-25 踩过的坑:此前六项全绿,而主功能 100% 不通 ——
# stop() 之后读 currentTime 恒为 0,每次录音都被当"太短"丢弃。
# 「启动到就绪」这种冒烟对它完全无感。故加一项直接打主路径的断言。
if [ -x "$BIN" ]; then
  # ⚠ 这一项**合法**用 $BIN(真 app)：它要麦克风,裸二进制拿不到。
  # ⛔ 但别写成 `"$BIN" … | grep -q`：本脚本开了 pipefail,grep -q 命中即关管道 →
  # 上游吃 SIGPIPE 返非零 → 整条管道判假。同一个坑本 repo 已记过两次(212 行 / build.sh)。
  REC=$("$BIN" --selftest-record 2>&1 || true)
  if grep -q "✓ selftest-record" <<<"$REC"; then
    pass "录音时长可读、过 guard"
  else
    fail "录音主路径不通（$(tail -1 <<<"$REC")）"   # 不再第二次启麦克风
  fi
fi
# 端到端真调 API 会花积分,默认不跑;要跑:TINGZHE_CHECK_E2E=1 ./check.sh
if [ "${TINGZHE_CHECK_E2E:-0}" = "1" ] && [ -x "$BIN" ]; then
  R=$("$BIN" --selftest-transcribe "record baseline/t6.m4a" 2>&1 | tail -1)
  grep -q "运营" <<<"$R" && pass "端到端转写通（${R}）" || fail "端到端转写异常: $R"
fi

echo "[8/12] 拼音层机制 + 回退状态钉死（方案 B）"
# ⛔ C6(独立复核实测):canon.json 写成 {"terms":[...]} 会被 `as? [String]` 静默当空表 →
# 拼音层整层失效而本项报绿。dict.json 有结构校验,canon.json/protect.json 一直没有。
python3 - <<'EOF'
import json, sys
ok = True
for f, what in [("canon.json", "canon"), ("protect.json", "保护词")]:
    try:
        d = json.load(open(f, encoding="utf-8"))
    except FileNotFoundError:
        continue
    except Exception as e:
        print(f"  ❌ {f} 解析失败: {e}"); ok = False; continue
    if not isinstance(d, list) or not all(isinstance(x, str) for x in d):
        print(f"  ❌ {f} 必须是字符串数组（引擎用 as? [String]，写错形状会**静默当空表**）"
              f"，实际: {type(d).__name__}"); ok = False
    else:
        print(f"  ✅ {f} 结构合法（{len(d)} 条 {what}）")
sys.exit(0 if ok else 1)
EOF
RC=$?; [ "$RC" -ne 0 ] && FAIL=1
# ⛔ C-3(独立复核实测):上面报的是**文件里有几条**,而引擎有个 `kCanonMinHan` 门槛会**静默丢弃**
# 不足 3 汉字的条目 —— 于是同一屏能同时出现「✅ canon.json 结构合法（1 条 canon）」和
# 「✅ canon 出厂为空」两句互相矛盾的绿。人照着文件数做判断,而生效的是另一个数。
# ⭐ 不在这里用 Python 重算门槛(那是重写引擎语义,第 4 项栽过)——**问引擎它到底装了几条**。
if [ -n "$ENGINE" ] && [ -f canon.json ]; then
  FILEN=$(python3 -c 'import json,os;f="canon.json" if os.path.exists("canon.json") else "canon.example.json";print(len(json.load(open(f))) if os.path.exists(f) else 0)' 2>/dev/null || echo 0)
  # ⭐ 不算差值、不重算门槛 —— 引擎自己会把丢弃的逐条打出来,直接拿它的话
  DROPPED=$("$ENGINE" --apply "x" 2>&1 | grep "canon 跳过" || true)
  if [ -n "$DROPPED" ]; then
    NDROP=$(grep -c "canon 跳过" <<<"$DROPPED")
    warn "canon.json 里 $FILEN 条，但引擎**丢弃了 $NDROP 条**（kCanonMinHan 门槛）→ 生效的只有 $((FILEN-NDROP)) 条"
    sed 's/^\[tingzhe\] /       /' <<<"$DROPPED"
    printf "       ⚠ 上面那句「结构合法（%s 条）」说的是**文件里有几条**,不是生效几条 —— 判断请用这里的数\n" "$FILEN"
  fi
fi
# 走二进制而不是在这里用 Python 重写:拼音来自 macOS CFStringTransform,Python 拿不到,
# 重写就是重写一个**不同的东西**（第 4 项曾犯过这个错,见其注释）。
if [ -n "$ENGINE" ]; then
  # ⛔ 用 $ENGINE 不用 ${BIN}：这是**纯文本**自检,零权限需求,build.sh 自己的 --help
  # 也逐字写着「纯文本自检可直接跑,例：build/dev/tingzhe --selftest-boundary」。
  # 用 $BIN(app bundle) = 在 --dev 迭代纪律下永远替一个越来越旧的二进制背书。
  SC=$("$ENGINE" --selftest-canon 2>&1)
  if grep -q "✓ selftest-canon" <<<"$SC"; then
    pass "拼音层机制正确 · canon 出厂为空（否决条件已触发过的回退状态）"
    grep "⚠\|⛔" <<<"$SC" | sed 's/^/     /'
  else
    fail "拼音层自检不过"
    sed 's/^/     /' <<<"$SC" | head -8
  fi
fi

echo "[9/12] 词边界护栏 + 词表对真实语料的误伤扫描"
# 两半是同一件事:护栏(断言修好了) + 扫描(测量还有没有)。
# 护栏的正例来源 = 真实语料里实测的那 4 次误伤,不是自撰样本。
if [ -n "$ENGINE" ]; then
  # ⛔ 同上必须是 $ENGINE —— 本项后半（语料扫描）已经走 TINGZHE_ENGINE,
  # 前后半用不同二进制会打出**同屏自相矛盾**的输出（独立复核注入护栏失效实测:
  # 前半 ✅「护栏生效」紧挨着后半 ❌ 七条,一个人看了无法判断护栏到底在不在）。
  BD=$("$ENGINE" --selftest-boundary 2>&1)
  if grep -q "✓ selftest-boundary" <<<"$BD"; then
    pass "词边界护栏生效（嵌入真词不误伤 · 独立命中仍修）"
    grep "⚠\|中文没有词边界" <<<"$BD" | sed 's/^/     /'
  else
    fail "词边界护栏不过"
    sed 's/^/     /' <<<"$BD" | head -8
  fi
fi
# ⛔ 这道闸是 2026-07-26 对抗判卷逼出来的。第 3 项只查**表内**子串包含（规则 A ⊂ 规则 B），
# 从不查**规则 ⊂ 真实词**，所以「the propose」吃掉「the proposed」这个真误伤永远绿灯 ——
# 它在 海量符的真实语料里实开火 4 次，全是误伤，而闸一声不响。
# 设计档原写「没有负例语料所以测不了误伤」= 错的诊断:独立语料一直就有。
# ⛔ 2026-07-28 开源化:这里原来硬编码作者本人的 语料库 路径,而且**找不到就判红** ——
# 对刚 clone 下来的人,那是一条永远红的闸,而它红的原因跟他的代码毫无关系。
# ⇒ 分两种情况,判据是「**你配了没有**」而不是「文件在不在」:
#    · 配了(TINGZHE_CORPUS 有值)但路径不存在 → 判红,那是配错了
#    · 压根没配 → ⚪ 本项不适用。⛔ 不是"通过",是**没测** —— 说清楚它本来会测什么。
# ⚠ 踩过的坑仍然守着:原病是「语料库 改名/换机器 → 闸静默消失还报全绿」。
#   那属于"配了但没了"这一支,照旧判红。
CORPUS_SET=0
CORPUS="${TINGZHE_CORPUS:-}"
if [ -n "${CORPUS}" ]; then
  CORPUS_SET=1
else
  CORPUS="$HOME/Documents/notes"        # 作者本机的默认位置
  [ -d "${CORPUS}" ] && CORPUS_SET=1
fi
if [ "$CORPUS_SET" = "0" ]; then
  echo "  ⚪ 没配语料库 → 本项不适用（**没测**，不是通过）"
  echo "     它本来测什么：拿一大批真实中文文本跑一遍词表，看规则会不会误伤真词"
  echo "     （例：规则 \`the propose\` 会吃掉 \`the proposed\`）"
  echo "     配上就能测：TINGZHE_CORPUS=/一个装满你日常文字的目录 ./check.sh"
elif [ ! -d "${CORPUS}" ]; then
  # ⛔ 2026-07-26 两个独立复核各自实测:原来这里是 warn+跳过 → `TINGZHE_CORPUS=/nonexistent ./check.sh`
  # 直接 `✅ 全绿 · EXIT=0`,连 🟡 都不打(TINGZHE_CORPUS 当时不在 ESCAPES 里)。
  # 换机器 / 语料库 改名 / 别人 clone —— 这道闸**静默消失且报全绿**。
  # 这正是本项 MIN_CHARS 下限要防的那件事换了个分支复发:守住了「语料太小」,没守住「没有语料」。
  if [ "${TINGZHE_ALLOW_NO_CORPUS:-0}" = "1" ]; then
    warn "找不到语料库 ${CORPUS}，跳过误伤扫描（已由 TINGZHE_ALLOW_NO_CORPUS=1 显式接受）"
  else
    fail "找不到语料库 $CORPUS —— 本项无法测量,不是通过"
    printf "     指定语料库: TINGZHE_CORPUS=/path ./check.sh\n"
    printf "     确实要跳过: TINGZHE_ALLOW_NO_CORPUS=1 ./check.sh（会标 🟡 不算全绿）\n"
  fi
else
  python3 - "$CORPUS" <<'EOF'
import json, os, sys, collections
语料库 = sys.argv[1]
import os as _os
def _uf(n): return n if _os.path.exists(n) else n.replace(".json", ".example.json")
rules = [tuple(x) for x in json.load(open(_uf('dict.json')))]
# ⛔⛔ 2026-07-26 独立复核抓出 + 我自己复验:**基率数字已被本项目自己的文字 100% 污染**。
# 实测:`星规/林盾/星盾/临盾` 在整个 语料库 出现 43/6/22/6 次 —— **全部在 tingzhe
# 自己的文档与 log.md 里**(我们讨论这些规则时写下的),其余约 海量 **0 次**。
# 而当时正拿「在 真实写作语料里出现 0 次」当作「别再要求 作者 造负例句」的依据。
#
# ⛔ 解法**不是**把自家文档排除掉 —— 这道闸的第一版就是靠排除 raw/ 放过了它要抓的全部实例,
#    而且「哪些算自家的」本身会随时间漂(硬编 basename 追不上新 dump;log.md 是跨项目共享时间线,
#    排掉它等于对另外十个项目的语料全瞎)。
# ⭐ 解法是**拆开报**:一个数都不丢,但把「自指」与「独立」分开标,让读的人自己看见。
#    判据只看独立那一半;自指那一半仍要显示(它是我们写得多不是产品坏了)。
def is_self_doc(path):
    r = os.path.relpath(path, 语料库)
    return ("tingzhe" in r) or r == "notes/log.md"

# SKIP 只保留一个用途:整档就是错例清单的文件(评测集),它连"自指"都不算,是**答案**。
SKIP = {"_评测集-v1-2026-07-25.md"}
# ⛔ 必须包含 raw/ —— 2026-07-26 实测:`the propose` 吃掉 `the proposed` 的 4 次实例
# **全部在 raw/ 里**（Claude 官方文档快照）。第一版这道闸把 raw/ 排除了,于是它会放过
# 自己要抓的那个 bug —— 「闸只检查我以为会坏的地方」这条踩过的坑在修它的补丁里当场复发。
# raw/ 是只读投放区(禁改),但**读它做扫描完全合规**,而且它正是 作者 领域词汇最密的语料。
SKIP_DIRS = {".git", ".obsidian"}
hits, embedded, truncated = collections.Counter(), collections.Counter(), collections.Counter()
selfhits, indephits = collections.Counter(), collections.Counter()   # 自指 / 独立,拆开报
samples = collections.defaultdict(list)
chars = 0

def is_word_char(c):
    # ⛔ C1(独立复核实测):原来用 c.isalnum() —— 它对**汉字**返回 True,而引擎的 isASCIIWordChar
    # 只认 ASCII。二者对「什么叫嵌在词里」的定义不同 → 「的front matter」这种**产品修正完全正确**
    # 的情形会被判红,并给出错误诊断「会真的改坏更长的真词」。口径必须与引擎一致。
    return (c.isascii() and (c.isalnum() or c == "_"))

for root, ds, fs in os.walk(语料库):
    ds[:] = [d for d in ds if d not in SKIP_DIRS]
    for fn in fs:
        if os.path.splitext(fn)[1].lower() not in {".md", ".txt"} or fn in SKIP:
            continue
        fpath = os.path.join(root, fn)
        try:
            t = open(fpath, encoding="utf-8", errors="ignore").read()
        except Exception:
            continue
        chars += len(t)
        selfdoc = is_self_doc(fpath)
        for w, _ in rules:
            if w not in t:
                continue
            ascii_rule = w[0].isascii() and w[0].isalpha()
            # ⛔ 必须遍历**每一次**出现,不能只看第一次:第一次可能是合法命中而第 4 次是误伤
            #（第一版只存了 samples[w] 的首个实例并据此判定 —— 同样会漏）
            i = t.find(w)
            while i != -1:
                hits[w] += 1
                (selfhits if selfdoc else indephits)[w] += 1
                if ascii_rule:
                    lb = i > 0 and is_word_char(t[i - 1])
                    rb = i + len(w) < len(t) and is_word_char(t[i + len(w)])
                    if lb or rb:
                        embedded[w] += 1
                        # ⛔ 存**两个**东西(2026-07-26 双独立复核各自独立抓出同一 bug):
                        #  probe = 恰好复现护栏判定所需的最小上下文 = 模式 + 左右各一个字符。
                        #    护栏只看紧邻的一个字符(src/main.swift crossesWordBoundary),
                        #    所以这个窗口在语义上与原位等价,却**不含任何别的规则**。
                        #  ⚠ 边界:i==0 时左邻不存在(引擎的 lo>0 判据),必须让 probe 也从模式开头起,
                        #    否则会伪造出一个本不存在的左邻。右侧同理。
                        left  = t[i - 1] if i > 0 else ""
                        right = t[i + len(w)] if i + len(w) < len(t) else ""
                        probe = left + w + right
                        ctx   = t[max(0, i - 24):i + len(w) + 24].replace("\n", " ")
                        if len(samples[w]) < 200:
                            samples[w].append((probe, len(left), ctx))
                        else:
                            truncated[w] += 1
                i = t.find(w, i + 1)

# ⛔ F4(独立复核实测):原来 0 字符语料上也打 ✅ —— 扫描范围是一个无下限、无校验的环境变量,
# 默认路径还不属于本项目(语料库 改名/换机器/别人 clone = 这道闸静默消失且仍全绿)。
MIN_CHARS = 1_000_000
print(f"  语料 {chars:,} 字符（含 raw/）· 规则命中 {dict(hits) or '无'}")
if chars < MIN_CHARS:
    print(f"  ❌ 语料只有 {chars:,} 字符（< {MIN_CHARS:,} 下限）—— 这道闸在这种语料上没有判别力")
    print(f"     设 TINGZHE_CORPUS 指向真实语料库，或显式接受：TINGZHE_ALLOW_SMALL_CORPUS=1")
    if os.environ.get("TINGZHE_ALLOW_SMALL_CORPUS") != "1":
        sys.exit(1)
    print("     （已由 TINGZHE_ALLOW_SMALL_CORPUS=1 显式接受）")
# 判据（2026-07-26 Q8甲 装了词边界护栏后改口径）:
# 「规则嵌在更长真词里」**本身不再等于误伤** —— 护栏会拒绝那次替换。
# ⛔ 所以别在这里用 Python 判边界(那是重写一遍运行时逻辑,必分叉,第 4 项就栽过)——
#    **拿每一处实际上下文去问真实引擎**「你到底会不会改它」。命中只十几处,逐处一次调用足够快。
import subprocess
BIN = os.environ.get("TINGZHE_ENGINE") or ""
if not BIN:
    print("  ❌ 没有可用引擎（TINGZHE_ENGINE 为空）—— 先跑 ./build.sh --dev")
    sys.exit(1)

# ⛔⛔ 2026-07-26 · 两个独立独立复核各自抓出同一个致命缺陷,已实测复现后重写：
#   旧写法 `engine_changes(48字窗口)` 拿**整窗是否变化**判「护栏有没有失手」。
#   而真实窗口里经常同时有 ① 一个嵌入命中(护栏正确拦下) ② 一处独立命中(规则本来就该改)。
#   ②一改整窗就脏 → 判成「规则 X 会真的改坏更长的真词」。**归因错到了另一处出现头上。**
#   实测假红:`跑就出真误伤（`the propose` 吃 `the proposed` 4/4 次）`
#            → 变的是独立的 `the propose`,而 `the proposed` 引擎一根手指没碰。
#   ⚠ 这正是本项目反复栽的那一类:**oracle 回答不了它自己提的那个问题**。
#   现在改为问「**这一处**被替换了吗」:拿最小 probe 去问,再看模式是否仍在原位。
def occurrence_replaced(probe, off, w):
    r = subprocess.run([BIN, "--apply", probe], capture_output=True, text=True)
    out = r.stdout.rstrip("\n")
    # 模式仍原封不动地待在原偏移 = 这一处没被替换 = 护栏拦住了
    return out[off:off + len(w)] != w

live, blocked = [], []
for w in embedded:
    for probe, off, ctx in samples[w]:
        (live if occurrence_replaced(probe, off, w) else blocked).append((w, ctx))
# ⛔ 有截断必须说出来 —— 「静默截断」读起来跟「全查过了」一模一样
for w, k in truncated.items():
    print(f"  ⚠️  规则 {w!r} 的嵌入命中超过 200 处，另有 {k} 处未被逐一拷问")
if blocked:
    print(f"  ✅ 护栏在真实语料上实际拦住了 {len(blocked)} 处「嵌在更长真词里」的命中：")
    for w, ctx in blocked[:8]:
        print(f"       {w!r} … {ctx} …")
if live:
    bad = collections.Counter(w for w, _ in live)
    for w, ctx in live:
        # ⛔ 报**实际失手数**,不是 embedded 总数(旧版打的是后者:2 处真事故印成「7 处」)
        print(f"  ❌ 规则 {w!r} 真的改坏了更长的真词（本规则实测失手 {bad[w]} 处 / 嵌入命中 {embedded[w]} 处）")
        print(f"     实例: …{ctx}…")
    sys.exit(1)
if not embedded:
    print("  ✅ 无 ASCII 规则嵌在更长真词内")
# 中文规则没有词边界可机械判定 → 报基率给人看,不判失败。
# 这个数字本身有用:2026-07-26 实测 星规/星盾 类在独立语料里出现 0 次,
# 说明自撰负例得出的「4/8 = 50% 误伤」高估了三个数量级。
han = [w for w, _ in rules if hits[w] and not (w[0].isascii() and w[0].isalpha())]
indep = {w: indephits[w] for w in han if indephits[w]}
mine  = {w: selfhits[w] for w in han if selfhits[w]}
# ⛔ 「独立」这个词以前是假的:数字里混着我们自己讨论这些规则的文字,而标签写着「独立语料」。
#    现在两个数分开打,判断风险只看第一个。
print(f"  ℹ️  中文规则基率 · **独立语料**（不含本项目自己的文档）: {indep or '全部 0 次'}")
if mine:
    print(f"      ↑ 另有 {sum(mine.values())} 次出现在**本项目自己的文档**里({mine})——")
    print(f"        那是我们讨论这些规则时写下的,**不是 作者 的语言分布**,不进风险判断。")
EOF
  RC=$?; [ "$RC" -ne 0 ] && FAIL=1
fi

# 作者 记下的误伤实例 → 永久回归断言。
# ⛔ 这是 Q4甲「负例卷」的**真正落地形态**（2026-07-26 作者 抓）：
# 我原来催「给我 10 条句子」是问错了问题 —— 护栏装好后只剩 4 条 2 字中文规则裸着,
# 而它们在 真实写作语料里出现 0 次,凭空造句既费力又不代表真实分布。
# 正确形态 = 作者 正常用工具 → 发现改错的就记一行 → 本项永久守着。
# ⚠ 「怎么记这一行」的入口形态 2026-07-26 被 作者 改判(review.sh→review.py→改判),待拍 Q11；
#    在替代品上线前:作者 在聊天里说一句,我来写这个文件。
# 文件不存在 = 还没攒到,自动跳过(不是失败)。
if [ -f negatives.txt ]; then
  python3 - <<'EOF'
import subprocess, sys, os
BIN = os.environ["TINGZHE_ENGINE"]     # 同上：拷问刚编出来的那个，不是 app 里的旧的
lines = [l.rstrip("\n") for l in open("negatives.txt", encoding="utf-8")]
cases = [l for l in lines if l.strip() and not l.lstrip().startswith("#")]
bad = []
for s in cases:
    got = subprocess.run([BIN, "--apply", s], capture_output=True, text=True).stdout.strip()
    if got != s.strip():
        bad.append((s.strip(), got))
if bad:
    for s, g in bad:
        print(f"  ❌ 负例被词表改动了: 「{s}」→「{g}」")
    sys.exit(1)
print(f"  ✅ negatives.txt {len(cases)} 条负例全部未被改动")
EOF
  RC=$?; [ "$RC" -ne 0 ] && FAIL=1
else
  printf "  ⚪ negatives.txt 不存在（还没攒到误伤实例）→ 跳过。攒法: 看见词表改坏了就在聊天里说一句（入口形态待拍 Q11）\n"
fi

echo "[10/12] 词表热重载（判据 N4 · 改表不必重启）"
# ⛔ 这一项是"我发现自己验不了某个判据"逼出来的:热重载写在 startRecording() 里,
# 只有按下热键才触发 → 我没法验它。而**一个我验不了的判据 = 一个我以为会好的地方**,
# 正是上一轮"六项全绿而主功能 100% 不通"的同型盲区。故给它开一条可驱动的自检入口。
# ⚠ 本项只验机制(mtime 比对 + 重新载表);「按键会调用它」那一步需真按一次键才算端到端。
if [ -n "$ENGINE" ]; then
  # ⛔ 必须 ${ENGINE}：独立复核注入「reloadTablesIfChanged() → return false」（热重载彻底死掉,
  # 正是本项存在的理由）后,本项问旧 app bundle 照打 ✅、整闸 exit 0、pre-push 放行。
  # ⛔ F-8(独立复核实测「声称『闸无破坏性副作用』不成立」):这一项必须**改** dict.json 才能测热重载,
  # 原来改的是**生产**那一份 —— 内容还原了但 **mtime 变了**(每跑一次两遍写),
  # 而 mtime 正是常驻进程判断"要不要重载"的依据 → 闸在扰动它正在判的那个进程。
  # 更糟的是 `try? orig.write` 吞错误且 exit 路径不跑 defer:窗口内被 Ctrl-C 会把
  # `自检临时错例→自检临时正例` **永久留在生产词表里**。
  # → 整项挪进沙箱。实测:生产 dict.json 的 mtime 与 md5 **前后都不变**,而自检照常通过。
  RL=$(TINGZHE_DIR="$SANDBOX" TINGZHE_LOG_DIR="$SANDBOX/logs" "$ENGINE" --selftest-reload 2>&1)
  if grep -q "✓ selftest-reload" <<<"$RL"; then
    pass "改 dict.json 无需重启（$(grep -o '指纹 [^,]*' <<<"$RL")）"
  else
    fail "热重载不生效 —— 加词要重启进程，方案 A 会因此没人用"
    grep "✗" <<<"$RL" | sed 's/^/     /'
  fi
fi

echo "[11/12] 方案丙浮层（不抢焦点 · 否决只写候选不写词表）"
# ⛔ 作者 2026-07-26 拍 Q11丙。这一项存在的理由跟第 7/10 项一样:
# **我自己按不了那个键**,而「我验不了的东西 = 我以为会好的地方」——本 repo 三次踩过的坑的同一形状。
# ⚠ 浮层要起窗口 ⇒ 走沙箱项目目录与沙箱日志目录,不碰生产的任何东西。
if [ -n "$ENGINE" ]; then
  HUDOUT=$(TINGZHE_SELFTEST_HUD=1 TINGZHE_DIR="$SANDBOX" TINGZHE_LOG_DIR="$SANDBOX/logs" \
           "$ENGINE" --selftest-hud 2>&1 || true)
  if grep -q "✓ selftest-hud" <<<"$HUDOUT"; then
    pass "浮层不抢焦点 · 否决只落候选队列（dict.json / negatives.txt 未被碰）"
    grep "⚠" <<<"$HUDOUT" | sed 's/^/     /'
  else
    fail "浮层自检不过 —— 它会抢走 作者 正在打字的窗口,或者否决直接写了词表"
    grep "✗" <<<"$HUDOUT" | sed 's/^/     /'
  fi
fi

echo "[12/12] 语音对话模式开关（作者 2026-07-28：按一下开、再按一下关）"
# ⛔ 存在的理由:开关状态被**另一个进程**读(speak-hook.sh 是 Claude 每轮说完才被拉起的独立进程),
# 进程内的布尔值它看不见。"状态必须落文件"这件事没人断言就会在某次重构里悄悄丢掉。
# ⚠ 走沙箱:自检会真的建/删状态位,不许碰生产的那个(否则闸会把 作者 的语音模式关掉)。
if [ -n "$ENGINE" ]; then
  # ⛔ 2026-07-28 踩过的坑:原来这里靠 HOME="$SANDBOX" 隔离,而 macOS 的
  # homeDirectoryForCurrentUser **不认 HOME**(走 getpwuid)→ 自检删掉了 作者 生产的语音状态位,
  # 把 作者 卡在「麦开着、界面说关着、点开关也关不掉」。必须走专用的 TINGZHE_STATE_DIR。
  VOUT=$(TINGZHE_STATE_DIR="$SANDBOX" TINGZHE_DIR="$SANDBOX" TINGZHE_LOG_DIR="$SANDBOX/logs" \
         "$ENGINE" --selftest-voice 2>&1 || true)
  if grep -q "✓ selftest-voice" <<<"$VOUT"; then
    pass "语音模式开关：状态落文件 · 来回切换正确 · 未与既有手势冲突"
    grep "⚠" <<<"$VOUT" | sed 's/^/     /'
  else
    fail "语音模式开关自检不过"
    grep "✗" <<<"$VOUT" | sed 's/^/     /'
  fi
fi

# ⛔ 口播链:过滤器坏了 = 把代码和路径念出来。它是纯文本逻辑,没有不测的理由。
if [ -x speakify.py ]; then
  SPOUT=$(./speakify.py --selftest 2>&1 || true)
  if grep -q "^✓ speakify" <<<"$SPOUT"; then
    pass "$(grep '^✓ speakify' <<<"$SPOUT" | sed 's/^✓ speakify: //')"
  else
    fail "口播过滤器自检不过（会把代码/路径念出来）"
    grep "✗" <<<"$SPOUT" | sed 's/^/     /'
  fi
fi

# ⛔ 流式朗读(MOSS-TTS-v1.5-Flash)。三个参数少一个就退回非流式,而症状是"怎么还是慢"、不报错;
# 采样率/声道写错不报错,只会让你听见花栗鼠。都钉在闸里。
# ⛔ 2026-07-29 踩过的坑:这一行原来**没给 TINGZHE_DIR** —— 而我当天给 --selftest-speak 加了
#   「改 tts_gain 再验」的断言,于是它写的是 **作者 的生产 config.json**,把他的音量设置改回 1.0。
#   本脚本开篇就宣称「闸不许有破坏性副作用」,而破它的正是我新加的那一条。
#   ⇒ 凡是会读写 config 的自检,一律连 TINGZHE_DIR 一起进沙箱。
SPK=$(TINGZHE_STATE_DIR="$SANDBOX" TINGZHE_DIR="$SANDBOX" TINGZHE_LOG_DIR="$SANDBOX/logs" $ENGINE --selftest-speak 2>&1 || true)

# ⛔ 出生守卫(2026-07-29 作者 第二次报「关掉语音模式声音还在说」):
#   新起的 --speak 进程开机读一次令牌,之后只在令牌**再变**时才闭嘴 ——
#   关模式那一下的信号它出生太晚没赶上,于是照念不误。日志实证:07-28 关模式 35 次里 6 次如此。
#   ⇒ 出生就先问「现在还该念吗」。这一条只能行为验:状态位不在 ⇒ 必须拒跑(退出码 2)。
BORN=$(echo "念点什么" | TINGZHE_STATE_DIR="$SANDBOX/nostate" TINGZHE_LOG_DIR="$SANDBOX/logs" \
        TINGZHE_DIR="$SANDBOX" $ENGINE --speak >/dev/null 2>&1; echo $?)
if [ "$BORN" = "2" ]; then
  pass "语音模式关着时 --speak 拒绝出生（关掉之后不会再冒出新的一段）"
else
  fail "语音模式关着时 --speak 仍然开念（退出码 ${BORN}，应为 2）"
fi
if grep -q "^✓ selftest-speak" <<<"$SPK"; then
  pass "$(grep '^✓ selftest-speak' <<<"$SPK" | sed 's/^✓ selftest-speak: //')"
  grep "⚠ 未断言" <<<"$SPK" | sed 's/^/     /'
else
  fail "流式朗读自检不过"
  grep "✗" <<<"$SPK" | sed 's/^/     /'
fi

# ⛔⛔ 2026-07-28:构建完弹大框说「授权已被打掉，去重授」——**假的**。
# 实测:新常驻报的是「按住 右⌥（单键）」,而单键形态**必须**有辅助功能权限,
# 掉了会自动退化成三键 ⌃⌥Space。designated 也逐字未变。
# 病根:判据比的是 **CDHash**(ad-hoc 时代 TCC 认的东西),而换成本机自签身份后
# TCC 认的是 **designated requirement** —— 跟二进制内容无关。
# ⚠ 更该记的是:我在 build.sh 顶部那个确认框里已经改对了,**却漏了构建完这一处** ——
#   同一份真相在仓库里有两份,我只改了一份。**作者 已因我的错误结论重授八次,
#   而那个框还在催第九次。** ⇒ 这三条盯的就是"第二份还在不在"。
# ⚠ 只看**会执行的行**：注释里留着 `.last-cdhash` 是在记述历史（F11 那条），是资产不是残留。
CDLEFT=$(grep -n 'last-cdhash' build.sh 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true)
if grep -q 'last-designated' build.sh && [ -z "${CDLEFT}" ]; then
  pass "重授判据用的是 designated（TCC 真正认的那个），CDHash 那份已删干净"
else
  fail "重授判据还在比 CDHash —— 那会让每次构建都误报「授权掉了」"
  printf '%s\n' "${CDLEFT}" | sed 's/^/     /'
fi
if [ -f .last-designated ] && [ -d tingzhe.app ]; then
  NOWSIG=$(codesign -d --requirements - tingzhe.app 2>&1 | grep '^designated' | head -1 || true)
  if [ "$(cat .last-designated)" = "${NOWSIG}" ]; then
    pass "重授基线跟当前 app 的 designated 一致（不会凭空要求重授）"
  else
    fail "重授基线跟当前 app 对不上 —— 下次构建会误报要重授"
  fi
fi
# 活文件里不许再有**无条件**的"构建必掉授权"说法。
# ⚠ 两条不算：① `没有签名身份 → ad-hoc（每次构建都会掉授权）` 是**条件成立时的真话**，
#            ② 只扫 build.sh —— 扫 check.sh 会匹配到本段自己的模式串（第一版就这么自我判红了）。
STALE=$(grep -n '每一次正式构建都会作废\|无法避免' build.sh 2>/dev/null \
        | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v '已被推翻\|已作废\|原来写的是' || true)
if [ -n "$STALE" ]; then
  fail "脚本里还留着「构建必掉授权」的旧说法（两份真相 → 下个 session 又会让 作者 去重授）"
  printf '%s\n' "$STALE" | sed 's/^/     /'
else
  pass "脚本里没有「构建必掉授权」的旧说法残留"
fi

# ⛔⛔ 2026-07-28 正式构建当场炸:`./build.sh: line 236: NEWPID）: unbound variable`。
# 根因:`"$NEWPID）"` —— bash 在 UTF-8 下把**紧跟其后的中文字节吃进变量名**,
# 于是它找的是变量 `NEWPID）`,不存在,`set -u` 立刻退出。
# ⚠ 它为什么活了一整天:这一行只在**重启常驻**那条分支上,而那条分支只有正式构建才走 ——
#   今天几十次 `--dev` 一次都没碰到它。**只在少见分支上的语法坑，测不到就等于没写。**
# ⇒ 静态扫:任何 `$VAR` 后面紧跟非 ASCII 字符,一律判红。写 `${VAR}` 就好。
# ⚠ 用 python3 扫而不是 grep:macOS 的 grep 没有字节类(\x80-\xFF),
#   而"非 ASCII"正是判据本身。第一版用「不在允许 ASCII 列表里」代替,
#   于是 `<string>$LABEL</string>` 里的 `<` 也被判红 —— 可 `<` 是 ASCII,bash 在那儿本来就会停。
#   **判据写歪一点，闸就开始报无关的东西，而那比不报更快让人不信它。**
SHBAD=$(python3 - build.sh check.sh install-agent.sh <<'SCAN' || true
import re, sys
pat = re.compile(r'\$[A-Za-z_][A-Za-z0-9_]*(?=[^\x00-\x7f])')
for f in sys.argv[1:]:
    for i, line in enumerate(open(f, encoding="utf-8"), 1):
        if line.lstrip().startswith("#"):      # 注释不执行
            continue
        if pat.search(line):
            print(f"{f}:{i}:{line.rstrip()}")
SCAN
)
if [ -n "$SHBAD" ]; then
  fail "shell 里有 \$VAR 紧跟非 ASCII 字符（bash 会把它吃进变量名 → set -u 当场退出）"
  printf '%s\n' "$SHBAD" | sed 's/^/     /'
  echo "     → 改成 \${VAR} 即可"
else
  pass "shell 变量没有紧跟中文的（那会被 bash 当成变量名的一部分）"
fi

# ⛔ V1/BI-5(验收卷否决区)·「自检杀掉了一个不属于它的进程」
# 查实:这个能力**已经删掉了** —— 运行时那两句 pkill afplay/say 早删(main.swift 注释逐字记着),
# 仓里只剩 install-agent.sh 三处、打的是本项目自己的二进制路径,且那是显式安装动作不是自检。
# ⇒ 坏仪器合成不出来(要造就得真杀一个进程)。**那就守住它别复活。**
# ⚠ 第一版判据假阳性:它匹配到 check() **消息字符串里**的 "pkill" 三个字 ——
#   注释/字符串当代码匹配,正是本项目三病四律里那条。故只认**真的调用形态**:
#   Python 的 subprocess、Swift 的 Process/绝对路径、shell 里行首命令位。
# 见红:往 speak-watch.py 加 `subprocess.run(["pkill", ...])`,这条立刻响。
PK=$(grep -nE 'pkill' src/main.swift speak-watch.py review.py apply_review.py 2>/dev/null \
     | grep -E 'subprocess|Process\(|/usr/bin/|/bin/sh' || true)
if [ -z "$PK" ]; then
  pass "运行时/自检路径没有 pkill 调用（杀别人进程的能力已删，且没被加回来）"
else
  fail "运行时/自检路径出现了 pkill 调用 —— 它会掐掉不属于本程序的进程"
  printf '%s\n' "$PK" | head -3 | sed 's/^/     /'
fi

# ⛔⛔ 2026-07-28 作者:「两套语音在同时播放…我到底在我的机器里运行了几套」。
# 病:speak-hook.sh(整段念)与 speak-watch.py(边写边念)靠瞬时 pgrep 互斥,
#   而 watcher 会在每次开关语音模式时退出、下次 UserPromptSubmit 才回来 ——
#   那个窗口里两边的守卫**各自都通过**(它们看的是不同时刻)。
# ⇒ 删掉第二条发声路径。这一条盯住它别长回来。
if [ -f speak-hook.sh ]; then
  SNDPATH=$(grep -cE "curl|afplay|/usr/bin/say|audio/speech" speak-hook.sh || true)
  if [ "${SNDPATH}" = "0" ]; then
    pass "只有一条发声路径（speak-hook 不再自己念，念由 speak-watch 一家负责）"
  else
    fail "speak-hook.sh 又能自己发声了 —— 两条路会在 watcher 重启的窗口里撞车"
    grep -nE "curl|afplay|/usr/bin/say|audio/speech" speak-hook.sh | sed 's/^/     /'
  fi
fi

# ⛔ 边写边念的两条性质,人耳要好几轮才反应过来,而那时候已经烦了:
#   ① 段间不空等合成(不然一顿一顿的) ② 你一开口,本段剩下的全丢(不然打断了个寂寞)
# 都是纯时序逻辑,自检拿假的 synth/play 验,不联网不出声。
if [ -x speak-watch.py ]; then
  SWOUT=$(./speak-watch.py --selftest 2>&1 || true)
  if grep -q "^✓ speak-watch" <<<"$SWOUT"; then
    pass "$(grep '^✓ speak-watch' <<<"$SWOUT" | sed 's/^✓ speak-watch: //')"
    grep "⚠ 未断言" <<<"$SWOUT" | sed 's/^/     /'
  else
    fail "边写边念自检不过（段间空等 / 打断后还接着说）"
    grep "✗" <<<"$SWOUT" | sed 's/^/     /'
  fi
fi

echo
# ⛔ C10/C3:失败时也必须打结论行(原来第 2/3/4 项 `|| exit 1` 会让脚本静默终止);
# 且带了逃生口时不许说"全绿" —— 那正是「一句 warn 没有东西依赖它」的形状。
ESCAPES=""
[ "${TINGZHE_ACCEPT_NO_AX:-0}" = "1" ] && ESCAPES="$ESCAPES TINGZHE_ACCEPT_NO_AX"
[ "${TINGZHE_ALLOW_SMALL_CORPUS:-0}" = "1" ] && ESCAPES="$ESCAPES TINGZHE_ALLOW_SMALL_CORPUS"
[ "${TINGZHE_ALLOW_NO_CORPUS:-0}" = "1" ] && ESCAPES="$ESCAPES TINGZHE_ALLOW_NO_CORPUS"
if [ $FAIL -eq 0 ]; then
  if [ -n "$ESCAPES" ]; then
    # ⛔ F-4(独立复核实测):原来这里 `exit 0` —— 而 .githooks/pre-push 只看退出码,
    # 于是「🟡 不算全绿」这句话**没有任何东西依赖它**,push 照放。
    # 这跟本脚本反复记的那条踩过的坑是同一个形状:一句 warn 没人消费 = 等于不存在。
    # 现在 🟡 = exit 2(与"有未过项"的 1 区分)。
    # ⚠ 确实要在退化态推:`git push --no-verify`(一个 flag,而且它把"我在推未验证的代码"写进了操作本身)。
    echo "🟡 全项通过，但用了逃生口：$ESCAPES —— 不算全绿"
    echo "   （pre-push 会拦。确实要推：git push --no-verify）"
    exit 2
  fi
  echo "✅ 全绿"; exit 0
else
  echo "❌ 有未过项"; exit 1
fi
