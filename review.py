#!/usr/bin/env python3
"""从转写记录生成一张本地网页，让 作者 点选「哪个词错了」，而不是去 terminal 打命令。

为什么长这样（作者 2026-07-26 原话：「你这个交互简直就是扯淡」）：
  · 作者 用这个工具的全部理由是**不想打字** —— 让他去 terminal `echo '句子' >> negatives.txt` 是自相矛盾的
  · 转写正文是禁区（含客户名/配方/薪资）→ **不能做成 Artifact、不能进对话**
    ⇒ 只生成 `file://` 本地页面，正文不出这台机器
  · 复制回聊天的内容**只含词对与条目编号，不含任何句子**
    ⇒ 句子留在本地；我按编号在本地脚本里取，直接写进 negatives.txt（见 apply_review.py）

用法：
  ./review.py            # 生成并打开（默认看最近 30 条）
  ./review.py 100        # 看最近 100 条
  ./review.py all
"""
import html
import json
import os
import subprocess
import sys
import difflib

REPO = os.path.dirname(os.path.abspath(__file__))
LOG = os.environ.get("TINGZHE_REVIEW_LOG",
                     os.path.expanduser("~/Library/Logs/tingzhe/transcripts.jsonl"))
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "review.html")


def load(n):
    if not os.path.exists(LOG):
        return []
    rows = [json.loads(l) for l in open(LOG, encoding="utf-8") if l.strip()]
    return rows if n == "all" else rows[-int(n):]


def load_rules():
    """真实词表 —— 报「哪条规则命中了」比猜 diff 准。"""
    out = []
    try:
        out += [(a, b) for a, b in json.load(open(os.path.join(REPO, "dict.json"), encoding="utf-8"))]
    except Exception:
        pass
    try:
        out += [(t, t) for t in json.load(open(os.path.join(REPO, "canon.json"), encoding="utf-8"))]
    except Exception:
        pass
    return out


RULES = None


def spans(raw, fixed):
    """词表改过的地方 → [(错, 对)]，只回词对，不回句子。

    ⛔ 不用字符级 diff。2026-07-26 实测：`乙项目→乙项目` 被 SequenceMatcher
    切成 `ete→EAT `，作者 看不懂 —— 而这页面的全部价值就是让人**一眼能判**，
    显示成看不懂的碎片等于让判断失效（甚至会把正确修正显示得像错的）。
    改为**直接查哪条规则命中了**：规则表是现成的、精确的，不需要猜。
    """
    global RULES
    if RULES is None:
        RULES = load_rules()
    if raw == fixed:
        return []
    hit = [(a, b) for a, b in RULES if a and a in raw and a != b]
    if hit:
        # 长的排前面：短模式常是长模式的子串，先报长的读起来才对
        hit.sort(key=lambda p: -len(p[0]))
        seen, out = set(), []
        for a, b in hit:
            if any(a in s for s in seen):      # 已被更长的规则覆盖，不重复报
                continue
            seen.add(a)
            out.append((a, b))
        return out
    # 兜底：文本变了但没有字面规则命中（拼音层等）→ 退回 diff，并标明是推断的
    out = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, raw, fixed).get_opcodes():
        if tag != "equal":
            out.append((raw[i1:i2] or "∅", fixed[j1:j2] or "∅"))
    return out


def protect_candidates(raw, changed):
    """「哪个词被改坏了」的候选。

    ⛔ 只当**候选**给 作者 点，绝不自动采用 —— 2026-07-26 实测两条启发式都不成立：
    扩到连续汉字边界 → 中文整句常是一整串，只保护那一句、泛化不了；
    左右各扩 1-2 字 → 会把「星规那」也保护上，把真正该改的那条规则废掉。
    所以：算候选（省 作者 打字），但**由 作者 点定**（保证精确）。
    """
    out, chars = [], list(raw)
    for wrong, _ in changed:
        if not wrong or not all("\u4e00" <= c <= "\u9fff" for c in wrong):
            continue
        # ⛔ 只给 ≤2 汉字的规则算候选。≥3 字规则被更长真词包住的风险极低,
        # 给它建议「甲项目等」这种非词反而**误导**(保护它是错的) ——
        # 噪音候选比没有候选更坏。2026-07-26 真实规模走查抓出。
        if len(wrong) > 2:
            continue
        w = list(wrong)
        i = 0
        while i + len(w) <= len(chars):
            if chars[i:i + len(w)] == w:
                for L in (0, 1, 2):          # ⛔ L 必须能取 0 ——
                    for R in (0, 1, 2):      # 原来从 1 起，「只往右扩」的真词一个都算不出来
                                             # (甲项目 前面是逗号 → L∈{1,2} 全被否掉，2026-07-26 走查抓出)
                        if L == 0 and R == 0:
                            continue
                        lo, hi = i - L, i + len(w) + R
                        if lo < 0 or hi > len(chars):
                            continue
                        seg = chars[lo:hi]
                        if all("\u4e00" <= c <= "\u9fff" for c in seg):
                            cand = "".join(seg)
                            if cand not in out and cand != wrong:
                                out.append(cand)
            i += 1
    return out[:6]


def render(rows):
    items = []
    for idx, r in enumerate(rows):
        raw, fixed = r.get("raw", ""), r.get("fixed", "")
        if not raw.strip():
            continue
        items.append({
            "id": idx,
            "ts": r.get("ts", "")[:16].replace("T", " "),
            "text": fixed,                      # 展示用（本地，不外传）
            "raw": raw,
            "changed": spans(raw, fixed),
            "n": r.get("fixes", 0),
        })
    return items


PAGE = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>tingzhe · 哪个词错了</title>
<style>
  :root{--void:#14110d;--ink:#1d1810;--card:#241d14;--raised:#322819;--paper:#e8ddc8;
        --paper-hi:#f6efe0;--mute:#b3a589;--faint:#7d735f;--amber:#d9a441;--green:#7fae6a;--red:#c9705c}
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--void);color:var(--paper);font-family:-apple-system,BlinkMacSystemFont,
       "PingFang SC",sans-serif;line-height:1.7;padding:24px 18px 240px;max-width:860px;margin:0 auto;font-size:15px}
  h1{font-size:23px;color:var(--paper-hi);margin-bottom:4px}
  .sub{font-size:12.5px;color:var(--faint);border-left:2px solid var(--raised);padding-left:11px;margin:10px 0 22px}
  .row{background:var(--card);border:1px solid var(--raised);border-radius:11px;padding:13px 15px;margin:11px 0}
  .row.done{border-color:var(--green);background:#1e2416}
  .row.flag{border-color:var(--red);background:#2a1a16}
  .row.miss{border-color:var(--amber);background:#2a2414}
  .meta{font-size:11px;color:var(--faint);font-family:"SF Mono",monospace;margin-bottom:5px}
  .txt{font-size:15.5px;color:var(--paper-hi);margin-bottom:9px;word-break:break-word}
  mark{background:#3a2f16;color:var(--amber);padding:0 3px;border-radius:3px}
  .btns{display:flex;gap:7px;flex-wrap:wrap}
  .b{background:var(--ink);border:1.5px solid var(--raised);border-radius:7px;padding:6px 13px;
     font-size:13px;color:var(--paper);cursor:pointer;font-family:inherit;transition:all .1s}
  .b:hover{border-color:var(--amber)}
  .b.on-ok{border-color:var(--green);color:var(--green);background:#1c2416}
  .b.on-bad{border-color:var(--red);color:var(--red);background:#2a1a16}
  .b.on-miss{border-color:var(--amber);color:var(--amber);background:#2c2414}
  .b.chip{padding:5px 11px;font-size:12.5px;font-family:"SF Mono",monospace}
  .b.chip.on{border-color:var(--red);color:var(--red);background:#2a1a16}
  .b.off{opacity:.35;cursor:not-allowed}
  .b.off:hover{border-color:var(--raised)}
  .missbox{margin-top:9px;display:none;gap:7px;flex-wrap:wrap;align-items:center}
  .missbox.show{display:flex}
  .missbox input{background:var(--ink);border:1.5px solid var(--raised);border-radius:7px;
     padding:7px 10px;color:var(--paper-hi);font-family:inherit;font-size:14px;min-width:150px}
  .missbox input:focus{outline:none;border-color:var(--amber)}
  .missbox .lbl{font-size:12px;color:var(--faint)}
  .outwrap{position:fixed;bottom:0;left:0;right:0;background:rgba(20,17,13,.98);
     border-top:2px solid var(--amber);padding:12px 18px;backdrop-filter:blur(8px);z-index:20}
  .outwrap .inner{max-width:860px;margin:0 auto}
  .outwrap h3{font-size:13px;color:var(--amber);margin-bottom:5px;display:flex;justify-content:space-between}
  textarea{width:100%;min-height:76px;max-height:44vh;background:var(--ink);color:var(--paper-hi);border:1px solid var(--raised);
     border-radius:7px;padding:9px;font-family:"SF Mono",monospace;font-size:12px;resize:vertical}
  .barbtns{display:flex;gap:10px;margin-top:8px;align-items:center}
  button.go{background:var(--amber);color:#1a1408;border:none;border-radius:7px;padding:9px 20px;
     font-size:14px;font-weight:700;cursor:pointer;font-family:inherit}
  button.ghost{background:transparent;color:var(--mute);border:1px solid var(--raised);
     border-radius:7px;padding:9px 16px;font-size:13px;cursor:pointer;font-family:inherit}
  .cnt{font-size:12px;color:var(--faint);font-family:"SF Mono",monospace}
  .empty{background:var(--card);border:1px solid var(--raised);border-left:3px solid var(--amber);
     border-radius:11px;padding:15px 17px;font-size:13.5px;color:var(--mute)}
  code{font-family:"SF Mono",monospace;font-size:12px;background:var(--ink);padding:1px 5px;
     border-radius:4px;color:var(--amber)}
</style></head><body>

<h1>哪个词错了</h1>
<p class="sub">每条按一下就行 —— <b>没问题</b> / <b>改错了</b>（词表把对的改坏了）/ <b>有词没听对</b>。<br>
标了「改错了」会再问你<b>哪个词被改坏了</b> —— 候选已算好，点一下就行。<br>词表没动过手的行，「改错了」是灰的（谈不上改错）。<br>最后点「复制」，把那一小段贴回聊天给我。<b>复制出来的东西只含词，不含你说过的句子</b> —— 正文不出这台机器。<br>
⌨️ 「有词没听对」的输入框里<b>可以直接用这个工具口述</b>（按住右 ⌥ 说那个词）。</p>

__BODY__

<div class="outwrap"><div class="inner">
  <h3><span>📋 贴回聊天的内容（只含词，不含句子）</span><span class="cnt" id="cnt">0 条</span></h3>
  <textarea id="out" readonly></textarea>
  <div class="barbtns">
    <button class="go" id="cp" onclick="cp()">📋 复制</button>
    <button class="ghost" onclick="reset()">重置</button>
    <span class="cnt" id="hint"></span>
  </div>
</div></div>

<script>
var A = {};   // id -> {v:'ok'|'bad'|'miss', wrong:'', right:''}
var D = __DATA__;

function mark(id, v, el) {
  A[id] = A[id] || {};
  A[id].v = v;
  var row = document.getElementById('r' + id);
  row.className = 'row' + (v === 'ok' ? ' done' : v === 'bad' ? ' flag' : ' miss');
  // ⛔ 只重置这一行的三个判定键。别用 row.getElementsByClassName('b') ——
  // 保护词 chip 的 class 是 "b chip"，会被一起扫中、把 chip 类剥掉，
  // 于是 prot() 里按 .chip 查高亮就失效了（2026-07-26 活体测抓出）。
  var bs = row.querySelector('.btns').getElementsByClassName('b');
  for (var i = 0; i < bs.length; i++) bs[i].className = 'b';
  el.className = 'b on-' + v;
  var mb = document.getElementById('m' + id);
  if (mb) {
    if (v === 'miss') { mb.className = 'missbox show'; mb.querySelector('input').focus(); }
    else mb.className = 'missbox';
  }
  var pb = document.getElementById('p' + id);
  if (pb) pb.className = 'missbox' + (v === 'bad' ? ' show' : '');
  upd();
}
function prot(id, word, el) {
  A[id] = A[id] || {}; A[id].v = 'bad'; A[id].prot = (word || '').trim();
  // el 为 null = 走的是自由输入框（候选只对纯汉字规则算得出来，
  // 英文规则误伤时没有候选 —— 那时自由输入框是唯一入口，2026-07-26 走查抓出）
  if (el) {
    var cs = document.getElementById('p' + id).getElementsByClassName('chip');
    for (var i = 0; i < cs.length; i++) cs[i].className = 'b chip';
    el.className = 'b chip on';
  }
  upd();
}
function miss(id, which, val) { A[id] = A[id] || {v:'miss'}; A[id][which] = val; upd(); }
function reset() {
  A = {};
  var rs = document.getElementsByClassName('row');
  for (var i = 0; i < rs.length; i++) {
    rs[i].className = 'row';
    var bs = rs[i].querySelector('.btns').getElementsByClassName('b');
    for (var j = 0; j < bs.length; j++) bs[j].className = 'b';
    var cs = rs[i].getElementsByClassName('chip');
    for (var c = 0; c < cs.length; c++) cs[c].className = 'b chip';
    var mbs = rs[i].querySelectorAll('.missbox');
    for (var m = 0; m < mbs.length; m++) mbs[m].className = 'missbox';
    var ins = rs[i].querySelectorAll('input'); for (var k = 0; k < ins.length; k++) ins[k].value = '';
  }
  upd();
}
function upd() {
  var L = ['# tingzhe 词表回执 —— 只含词与条目号，不含句子'], n = 0;
  for (var id in A) {
    var a = A[id], d = D[id]; if (!a || !a.v) continue;
    n++;
    if (a.v === 'ok') {
      if (d.changed.length) L.push('OK   #' + id + '  ' + d.changed.map(function(c){return c[0]+'→'+c[1];}).join(' , '));
      else L.push('OK   #' + id + '  (词表未动手，这句本来就对)');
    } else if (a.v === 'bad') {
      L.push('BAD  #' + id + '  ' + (d.changed.map(function(c){return c[0]+'→'+c[1];}).join(' , ') || '(词表未动手却标了改错？)')
             + (a.prot ? '  保护「' + a.prot + '」' : '  ⚠未指定要保护哪个词'));
    } else {
      L.push('MISS #' + id + '  「' + (a.wrong || '?') + '」应为「' + (a.right || '?') + '」');
    }
  }
  var ta = document.getElementById('out');
  ta.value = n ? L.join('\\n') : '';
  // ⛔ 30 条全标时回执有 31 行,而框只有 76px —— **你复制的东西自己看不见**
  // (2026-07-26 真实规模走查实测:scrollHeight 11021 vs clientHeight 74)。随内容长高,上限 44vh。
  ta.rows = Math.min(Math.max(3, L.length), 18);
  document.getElementById('cnt').textContent = n + ' 条';
  document.getElementById('hint').textContent = n ? '贴回聊天即可，我照它改词表' : '还没标';
}
function cp() {
  var t = document.getElementById('out');
  if (!t.value) { document.getElementById('hint').textContent = '先标几条'; return; }
  t.focus(); t.select();
  var ok = false;
  try { ok = document.execCommand('copy'); } catch (e) {}
  if (navigator.clipboard) { try { navigator.clipboard.writeText(t.value); ok = true; } catch (e) {} }
  var b = document.getElementById('cp'), o = b.textContent;
  b.textContent = ok ? '✓ 已复制' : '⌘C 复制选中';
  setTimeout(function(){ b.textContent = o; }, 1600);
}
upd();
</script>
</body></html>
"""


def build(items):
    if not items:
        body = ('<div class="empty">还没有转写记录。先按住右 ⌥ 说几句，再回来。<br>'
                '（生成的页面在 <code>review.html</code>，随时重跑 <code>./review.py</code> 刷新）</div>')
    else:
        parts = []
        for it in items:
            t = html.escape(it["text"])
            for w, r in it["changed"]:
                if r:
                    t = t.replace(html.escape(r), "<mark>" + html.escape(r) + "</mark>", 1)
            cands = protect_candidates(it["raw"], it["changed"])
            chips = "".join(
                f'<button class="b chip" onclick="prot({it["id"]},\'{html.escape(c)}\',this)">{html.escape(c)}</button>'
                for c in cands) or ''
                # ⛔ 词表没动手的行,「改错了」无意义(回执会吐出「词表未动手却标了改错？」)——
            # 一个说不通的状态不该可达。2026-07-26 真实规模走查实测抓出。
            has_chg = bool(it["changed"])
            bad_dis = "" if has_chg else " off"
            bad_attr = "" if has_chg else ' title="这句词表没动过手，谈不上改错；要报模型听错了用右边那个" disabled'
            chg = ("词表改了 %d 处：" % it["n"] + " , ".join(
                "%s→%s" % (html.escape(a or "∅"), html.escape(b or "∅")) for a, b in it["changed"])
                ) if it["changed"] else "词表未动手"
            parts.append(f"""<div class="row" id="r{it['id']}">
  <div class="meta">#{it['id']} · {html.escape(it['ts'])} · {chg}</div>
  <div class="txt">{t}</div>
  <div class="btns">
    <button class="b" onclick="mark({it['id']},'ok',this)">✓ 没问题</button>
    <button class="b{bad_dis}" onclick="mark({it['id']},'bad',this)"{bad_attr}>✗ 词表改错了</button>
    <button class="b" onclick="mark({it['id']},'miss',this)">△ 有词没听对</button>
  </div>
  <div class="missbox" id="p{it['id']}">
    <span class="lbl">哪个词被改坏了？</span>{chips}
    <span class="lbl">或自己填</span>
    <input placeholder="克星规 / the proposed" oninput="prot({it['id']},this.value,null)">
  </div>
  <div class="missbox" id="m{it['id']}">
    <span class="lbl">听成了</span>
    <input placeholder="树权" oninput="miss({it['id']},'wrong',this.value)">
    <span class="lbl">应该是</span>
    <input placeholder="授权" oninput="miss({it['id']},'right',this.value)">
  </div>
</div>""")
        body = "\n".join(parts)
    data = json.dumps({str(i["id"]): {"changed": i["changed"]} for i in items}, ensure_ascii=False)
    return PAGE.replace("__BODY__", body).replace("__DATA__", data)


def main():
    n = sys.argv[1] if len(sys.argv) > 1 else "30"
    items = render(load(n))
    open(OUT, "w", encoding="utf-8").write(build(items))
    chg = sum(1 for i in items if i["changed"])
    print(f"生成 {OUT}")
    print(f"  {len(items)} 条转写 · 其中词表动过手的 {chg} 条")
    print("  ⛔ 这是本地文件，正文不出这台机器（不上传、不进对话）")
    if os.environ.get("TINGZHE_REVIEW_NO_OPEN") != "1":
        subprocess.run(["open", OUT])
        print("  已在浏览器打开 —— 点完点「复制」，把那一小段贴回聊天")


if __name__ == "__main__":
    main()
