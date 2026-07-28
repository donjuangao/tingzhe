// tingzhe · 按住热键说话 → moss 转写 → 专名修正 → 粘贴到当前焦点框
// 最小可用版(作者 2026-07-25 拍 Q3甲)。零第三方依赖,只用系统框架。
//
// 热键: 默认右 ⌥ 单键按住(config.json 可改) —— 按住录音,松开转写
// ⛔ 别设 rightCommand:右⌘ 是 ⌘C/⌘V/⌘Tab 修饰键,⌘Tab 切窗口会误录并粘出去
// 配置: ~/Downloads/tingzhe/.env.local 的 TINGZHE_API_KEY
//       ~/Downloads/tingzhe/dict.json  专名修正词表
// 覆盖目录: 环境变量 TINGZHE_DIR

import Foundation
import AVFoundation
import AppKit
import Carbon.HIToolbox

// MARK: - 常量

/// 录音采样率。R3 评测用的是 48kHz 原始录音;这里降到 16kHz 是为了压缩上传体积、
/// 抢回一点延迟(ASR 模型通常本就在 16kHz 上训练)。⚠ 这是**相对 R3 引入的唯一变量**,
/// 若实测准确率明显低于 R3 的 6.8%,第一个该回退的就是它 → 改成 48000 重测。
let kSampleRate = 16000.0
// ⛔ 2026-07-28 作者 拍开源范围:「不要那么大 scope,让他们去写自己的 API」。
// MOSS 的接口本来就是 **OpenAI 那个形状**,所以只要把**地址和模型名**放进 config.json,
// 任何 OpenAI 兼容的服务都能直接填进来用 —— **这不是抽象层,就是两个字符串**。
/// ⛔ 这一句原来把路径写死成 `~/Downloads/tingzhe/config.json`,**不认 `TINGZHE_DIR`** ——
/// 别人把仓库克隆到任何别的地方,`api_base` 就永远读不到,只能用默认那个服务商。
/// 而"换服务商"正是开源版唯一要求用的人自己做的事(作者 拍:「让他们去写自己的 API」)。
/// ⚠ 不能用底下的 `projectDir`:它定义在后面,而这是顶层 `let`,求值更早。所以把同一段逻辑写在这。
let kConfigDir: String = {
    if let d = ProcessInfo.processInfo.environment["TINGZHE_DIR"], !d.isEmpty { return d }
    // ⚠ 跟 projectDir 同一条推断,但不能调它(那是后面的全局,求值更晚)。
    var u = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
    for _ in 0..<5 {
        u = u.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: u.appendingPathComponent("build.sh").path) {
            return u.path
        }
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/tingzhe").path
}()
let kAPIBase: String = {
    for n in ["config.json", "config.example.json"] {      // 没有自己的就用仓库带的那份
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: kConfigDir).appendingPathComponent(n)),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let v = j["api_base"] as? String, !v.isEmpty else { continue }
        return v
    }
    return "https://api.mosi.cn/v1"
}()
let kAPI = kAPIBase + "/audio/transcriptions"
let kModel = "moss-transcribe"
/// 自检模式:让主路径可被驱动而不真调 API、不真往焦点框粘字。
/// ⛔ F2(2026-07-26 独立复核实测) 的根因:`--selftest-record` 自己复制了一份录音代码
/// (两处独立的 `r.currentTime` 读取),于是**踩过的坑 #1 只要重新犯在生产那一处,该项照旧绿** ——
/// 而它正是专为踩过的坑 #1 加的那一项。它在空项目目录里都能过 = 连 Controller 都没构造。
/// 现在给主路径开一个可驱动入口:transcribe 返回占位、deliver 只记日志,其余**全走真代码**。
let kSelftest = ProcessInfo.processInfo.environment["TINGZHE_SELFTEST_MAINPATH"] == "1"

let kRetries = 2          // 实测空响应率 ≈6%,不重试约每 17 次按住会有一次哑火

// MARK: - 工具

/// 一次性子命令（`--fix` / `--apply` / `--candidates` / `--selftest-*`）**不写 app.log**。
/// ⛔ 理由（2026-07-26 实测的自伤）：这些命令经 `Controller` 会打「词表已加载」等行，
/// 每跑一次 `check.sh` 就往 app.log 追加约 6 行，把**常驻实例**的「就绪 / 未授辅助功能权限」
/// 挤出第 6 项读的那个窗口 → **第 6 项的权限检测被我自己新加的第 8/10 项弄哑了，而且是静默的**
/// （从 fail 降级成「读不到常驻日志」的 WARN）。
/// app.log 的职责是**常驻生命周期记录**；一次性命令只走 stderr。
/// 判据：常驻是无参数启动的，任何 `--` 开头的参数都意味着 CLI 一次性模式。
let isOneShot = CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }

/// ⛔ 不能只写 stderr —— 常驻改用 `open -a` 启动后（为了让 TCC 认出 app 身份、
/// 拿到辅助功能权限），进程不再继承 launchd 的 fd，stderr 重定向失效、日志全空。
/// 作者 2026-07-25 拍 Q2乙「日志全留」，故程序自己落盘，与启动方式解耦。
/// 转写日志所在目录。⛔ 必须可覆盖:2026-07-26 一天内**两个人**(独立复核 + 我自己)在测
/// `--candidates` 的防泄漏行为时误读了真实语音记录 —— 因为 `HOME=` 对
/// `homeDirectoryForCurrentUser` 无效(macOS 走 getpwuid,不看环境变量)。
/// 测隐私功能却只能拿真数据测,本身就是个设计缺陷。
let logDirURL: URL = {
    if let p = ProcessInfo.processInfo.environment["TINGZHE_LOG_DIR"] {
        return URL(fileURLWithPath: p)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/tingzhe")
}()

let appLogURL: URL = {
    try? FileManager.default.createDirectory(at: logDirURL, withIntermediateDirectories: true)
    return logDirURL.appendingPathComponent("app.log")
}()

func log(_ s: String) {
    let line = "[tingzhe] \(s)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    guard !isOneShot else { return }          // 见 isOneShot 的注释：别污染常驻日志
    let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)"
    if let h = try? FileHandle(forWritingTo: appLogURL) {
        h.seekToEndOfFile(); h.write(stamped.data(using: .utf8)!); try? h.close()
    } else {
        try? stamped.write(to: appLogURL, atomically: true, encoding: .utf8)
    }
}

/// ⛔⛔ 2026-07-28 作者:「你在改另外一个东西，为什么它还能干扰我正在用的语音输入？
///    弄得我这个插件一直在这儿响嘚嘚嘚的。」
/// 根因:`check.sh` 每跑一遍要开关语音模式 6 次、静音 2 次、切发送方式 1 次 ——
/// **每一次都 `NSSound.play()`**,而我这一轮跑了十几遍闸。
/// ⚠ 项目文档里写着「闸自己不许有副作用,现在这句是真的了」——
///   那句只覆盖了**文件**(dict.json 的 mtime、日志),没覆盖**声音**。
///   **又一条比听起来窄的保证。** 副作用不只是写盘,凡是用户能察觉的都算。
let kQuiet: Bool = ProcessInfo.processInfo.environment["TINGZHE_QUIET"] == "1"
    || CommandLine.arguments.contains(where: { $0.hasPrefix("--selftest") })

/// ⚠ 计数只在**真的播了**之后加 —— 闸靠它断言"整轮跑下来一声没响"。
/// 上一版断言写的是 `check(kQuiet, "beep 是哑的")`,那只验了开关变量,
/// **措辞超出了它实际检查的东西**:把 `if kQuiet { return }` 删掉,它照样绿。
var beepsPlayed = 0
func beep(_ name: String) {
    if kQuiet { return }
    beepsPlayed += 1
    NSSound(named: name)?.play()
}

/// ⛔⛔ 2026-07-28 开源前审计(视角③「文档承诺 vs 仓库现实」)抓出的**必死项**:
/// 这里原来硬编码 `~/Downloads/tingzhe` —— 那是**作者本机的位置**。
/// 别人把仓库 clone 到任何别的地方,把 key 放进自己那份 `.env.local`,
/// 程序仍然去 `~/Downloads/tingzhe/.env.local` 找,然后报「找不到 TINGZHE_API_KEY」,
/// 而报出来的路径**跟他被告知去 clone 的地方毫无关系**。**每一个新用户 100% 撞这堵墙。**
/// ⇒ 正确解法:从**可执行文件自己的位置**推。app bundle 里是
///    `<repo>/tingzhe.app/Contents/MacOS/tingzhe`(上溯 4 层),
///    裸二进制是 `<repo>/build/dev/tingzhe`(上溯 3 层)。
///    认不出来才退回旧默认值(作者本机仍然能用)。
/// ⚠ 顺序:环境变量 > 自身位置 > 旧默认值。
func resolveProjectDir(_ exePath: String, env: String?) -> URL {
    if let p = env, !p.isEmpty { return URL(fileURLWithPath: p) }
    var u = URL(fileURLWithPath: exePath).resolvingSymlinksInPath()
    var parents: [URL] = []
    for _ in 0..<5 { u = u.deletingLastPathComponent(); parents.append(u) }
    // 谁看起来像仓库根:带 src/main.swift 或 build.sh 的那一层
    for cand in parents {
        let hasSrc = FileManager.default.fileExists(
            atPath: cand.appendingPathComponent("src/main.swift").path)
        let hasBuild = FileManager.default.fileExists(
            atPath: cand.appendingPathComponent("build.sh").path)
        if hasSrc || hasBuild { return cand }
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/tingzhe")
}

let projectDir: URL = resolveProjectDir(
    CommandLine.arguments.first ?? "",
    env: ProcessInfo.processInfo.environment["TINGZHE_DIR"])


/// 方案丙浮层开关。⛔ CLI 一次性命令(含各种自检)一律不起窗口 —— 闸不许有可见副作用。
/// ⛔⛔ **必须放在 `isOneShot` 与 `projectDir` 之后** —— main.swift 的顶层全局是**按源码顺序**
/// 初始化的,不是惰性的。我第一版把它写在第 30 行(两个依赖都在它后面),编译器一声不吭,
/// 运行时 `--apply` 直接 **SIGSEGV(139)**。⚠ 而我第一次验它时把管道里 `tail` 的退出码
/// 当成了程序的退出码,于是看到 rc=0 —— **和这个 repo 记了三次的 pipefail 坑是同一个动作**。
let kHUD = ProcessInfo.processInfo.environment["TINGZHE_SELFTEST_HUD"] == "1"
    || (!isOneShot && loadHUDEnabled())
let kHUDSeconds = loadHUDSeconds()
let kHUDPosition = loadHUDPosition()

func loadAPIKey() -> String? {
    let f = projectDir.appendingPathComponent(".env.local")
    guard let text = try? String(contentsOf: f, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") {
        if line.hasPrefix("TINGZHE_API_KEY=") {
            let v = line.dropFirst("TINGZHE_API_KEY=".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
    }
    return nil
}

/// 用户数据文件的读取路径。⛔ 开源化(2026-07-28)带来的约束:
/// `dict.json` / `config.json` 是**用的人自己的东西**(专名、快捷键),不该进仓库 ——
/// 它们被 gitignore 了,于是**新克隆下来是没有这些文件的**。
/// ⇒ 读不到就退回同名的 `.example.json`(仓库里带的那份),让它开箱能跑。
/// ⚠ 只对**读**生效。写(`--fix` 往词表里加词)永远写真文件,
///   否则新用户加的第一个词会被写进示例文件,再被 git 当成改动 —— 那是两份真相的又一个入口。
func readableProjectFile(_ name: String) -> URL {
    let real = projectDir.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: real.path) { return real }
    let example = projectDir.appendingPathComponent(
        name.replacingOccurrences(of: ".json", with: ".example.json"))
    return FileManager.default.fileExists(atPath: example.path) ? example : real
}

/// 专名修正词表。JSON: [["错","对"], ...] —— 用数组而非对象,因为**顺序有意义**
/// (长模式必须先替换,否则短模式会先咬掉一段)。
func loadDict() -> [(String, String)] {
    let f = readableProjectFile("dict.json")
    guard let d = try? Data(contentsOf: f),
          let arr = try? JSONSerialization.jsonObject(with: d) as? [[String]] else { return [] }
    return arr.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
}

/// 结构化转写日志（每次一行 JSON）。给「向量化热词表」方向留原料 —— 作者 2026-07-25 拍 Q2乙。
/// ⚠ 明文,含说过的一切。路径与 launchd 日志同目录,便于统一管理与清理。
func appendJSONL(dur: TimeInterval, ms: Int, raw: String, fixed: String, fixes: Int, dictHash: String,
                 fixDict: Int = 0, fixCanon: Int = 0, file: String = "transcripts.jsonl") {
    // ⛔ 自检一律写侧车,绝不污染真实语料(2026-07-26 一次反查抓出)。
    // 病:`--selftest-mainpath` 走的是**生产** stopAndTranscribe → 落默认文件 →
    // 12 条占位文本混进 transcripts.jsonl,把「真实命中率」从 0/26 抬成假的 32%。
    // 而这个文件是 P4 held-out 评测的**唯一原料**(作者 07-25 拍 Q2乙 全留正是为了它)——
    // 污染它 = 污染这个项目唯一的真数据源。
    // ⚠ 与 app.log 那次是同一个病(一次性命令污染常驻日志),我修了 app.log **没想到这个文件**。
    let file = kSelftest ? "transcripts-selftest.jsonl" : file
    try? FileManager.default.createDirectory(at: logDirURL, withIntermediateDirectories: true)
    let f = logDirURL.appendingPathComponent(file)
    let obj: [String: Any] = [
        "ts": ISO8601DateFormatter().string(from: Date()),
        "audio_sec": (dur * 100).rounded() / 100,
        "latency_ms": ms,
        "raw": raw,            // 模型原始输出 —— 向量化迭代的关键字段
        "fixed": fixed,        // 词表修正后
        "fixes": fixes,
        // 分层记账 —— 哪一层修的,决定了下一步该加字面规则还是加 canon 词。
        // 只记总数的话,"拼音层到底有没有用"这个问题日后无法从日志回答。
        "fix_dict": fixDict,
        "fix_canon": fixCanon,
        "dict": dictHash,      // 词表版本,便于把效果归因到具体词表
        "sr": Int(kSampleRate),
    ]
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
          var line = String(data: d, encoding: .utf8) else { return }
    line += "\n"
    if let h = try? FileHandle(forWritingTo: f) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: f, atomically: true, encoding: .utf8)
    }
}

// MARK: - 词边界护栏（方案 C · 作者 2026-07-26 拍 Q8甲）
//
// 病例（语料库 3018 万字符真实语料里实测,4/4 次全是误伤）：
//   规则 `the propose → 的 props` 在 `the proposed` 内部命中
//   「Let me edit the proposed content」→「Let me edit 的 propsd content」
// 原 `applyDict` 是**无条件全文替换**,子串匹配没有边界。
//
// ⛔ 诚实的边界:**只有 ASCII 侧能机械判词边界**。中文没有词边界(没有分词就判不了),
// 所以中文模式仍是无条件替换 —— 这不是偷懒,是这个方法的上限。
// 缓解靠 `check.sh` 第 9 项:它把每条规则跑一遍真实语料,报出中文规则的出现基率
// (2026-07-26 实测:`星规/星盾/林盾/临盾` 在独立语料里 **0 次**),真出现了会看见。

func isASCIIWordChar(_ c: Character) -> Bool {
    guard let a = c.asciiValue else { return false }
    return (a >= 48 && a <= 57) || (a >= 65 && a <= 90) || (a >= 97 && a <= 122) || a == 95
}

/// 这次命中是否越过了词边界（= 该拒绝替换）。
/// 逐侧判,依据**模式自己那一侧的边缘字符**：
/// · 模式左边缘是 ASCII 词字符 → 左侧紧邻不得是 ASCII 词字符
/// · 模式右边缘是 ASCII 词字符 → 右侧紧邻不得是 ASCII 词字符
/// · 边缘是汉字 → 该侧不设约束（中文无词边界）
/// 例：`推 min`(右边缘 n) 不会在「推 mining」里开火；`grip一下`(右边缘 下) 右侧不设限。
func crossesWordBoundary(_ chars: [Character], _ lo: Int, _ hi: Int, _ pattern: [Character]) -> Bool {
    if let f = pattern.first, isASCIIWordChar(f), lo > 0, isASCIIWordChar(chars[lo - 1]) { return true }
    if let l = pattern.last, isASCIIWordChar(l), hi < chars.count, isASCIIWordChar(chars[hi]) { return true }
    return false
}

/// 保护名单（`protect.json`）：这些**词**出现在原文里时，落在它们里面的替换一律不做。
///
/// ⭐ 这是中文侧词边界的唯一可行解：**算不出来，也不要猜 —— 让人指。**
/// 中文没有分词，`克星规` 里的 `星规` 在机械上与真正该改的 `星规` 完全无法区分。
///
/// ⛔ 2026-07-26 实测否掉的两条启发式（别再试）：
/// ① 从负例整句里「向两侧扩到连续汉字边界」→ 中文一整句常就是一整串汉字，
///    提出来的是「克星规那本书我看过」，**只保护那一句，`克星规访华` 照样被改坏**。
/// ② 改成「左右各扩 1-2 字」→ 会把「星规那」也保护上，
///    于是「星规那边的状态记录」这句**真正该改的**反而不改了 —— 过度保护把规则本身废了。
/// ⇒ 两头都不成立 ⇒ **保护词由 作者 在 review.html 上点一下指定**（`review.py` 会把候选
///   预算成按钮，点一次就行），落进 `protect.json`。精确、可解释、不会误伤规则本身。
///
/// 为什么必须有它：`negatives.txt` 记的是「这句不该被改」，是**闸的断言**；
/// 但中文没有护栏可依，记一条 = 闸永久判红且无法修
/// —— 而 check.sh 自己的注释写着「闸永远红 = 人开始忽略它 = 闸失效」。
/// **一个记了就变砖的机制不能交给用户。** protect.json 就是让它可修的那一半。
func loadProtected() -> [String] {   // ⚠ 独立复核指出原来的 rules 参数已成死参数,删掉
    let f = readableProjectFile("protect.json")
    guard let d = try? Data(contentsOf: f),
          let arr = try? JSONSerialization.jsonObject(with: d) as? [String] else { return [] }
    return arr.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
}

/// 某次命中是否落在保护词内部。
func insideProtected(_ chars: [Character], _ lo: Int, _ hi: Int, _ protected: [String]) -> String? {
    for p in protected {
        let pa = Array(p), pl = pa.count
        guard pl > hi - lo else { continue }
        let from = max(0, hi - pl), to = min(chars.count, lo + pl)
        var s = from
        while s + pl <= to {
            if Array(chars[s..<(s + pl)]) == pa && s <= lo && s + pl >= hi { return p }
            s += 1
        }
    }
    return nil
}

func applyDict(_ text: String, _ rules: [(String, String)], _ protected: [String] = []) -> (String, Int) {
    var chars = Array(text)
    var n = 0
    for (wrong, right) in rules where !wrong.isEmpty {
        let pat = Array(wrong), rep = Array(right)
        let w = pat.count
        var i = 0
        while i + w <= chars.count {
            if Array(chars[i..<(i + w)]) == pat && !crossesWordBoundary(chars, i, i + w, pat)
                && insideProtected(chars, i, i + w, protected) == nil {
                chars.replaceSubrange(i..<(i + w), with: rep)
                n += 1
                i += rep.count          // 跳过刚写入的替换文本，避免自我重入
            } else {
                i += 1
            }
        }
    }
    return (String(chars), n)
}

// MARK: - 拼音层（方案 B · 作者 2026-07-26 拍 Q2甲）
//
// 为什么是拼音而不是向量:2026-07-26 逐条核对 dict.json 的 25 条规则,**100% 是音近/分词错误,
// 语义错误 0 条**。向量 embedding 抓的是语义相近(星轨↔盾牌),而我们的错全是语义无关、读音相同
// (星轨↔星规)。作者 据此拍 Q2甲:「向量化」是目标(自动泛化)不是手段 → 走拼音键。
// 一条 canon 自动覆盖该词的所有同音写法,包括**从没写过规则的写法**。
//
// ⚠ 拼音层不改善误伤。同一批正/负例实测:字面法与拼音法误伤**完全相同**(各 4/8,同样那 4 条)。
// 病根是 2 字模式没有边界(克星规→kexinggui 包含 星轨→xinggui),不是匹配不够聪明。
// 缩误伤要靠边界约束(方案 C),而 C 卡在「没有负例语料」的闸后面 → 见 kCanonMinHan。

/// 汉字 → 拼音(去声调)。用 macOS Foundation 的 `CFStringTransform`,**是 OS API 不是第三方依赖**,
/// 项目「零第三方依赖」这条工程事实不破。
/// ⚠ 去声调是刻意的:ASR 常错调(项目 xiàngmù / 项目 xiāngmù)。实测去调召回 9/9、带调只 7/9。
func pinyinOf(_ s: String) -> String {
    let m = NSMutableString(string: s) as CFMutableString
    CFStringTransform(m, nil, kCFStringTransformToLatin, false)
    CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
    return (m as String).replacingOccurrences(of: " ", with: "").lowercased()
}

func isHan(_ c: Character) -> Bool { c >= "\u{4E00}" && c <= "\u{9FFF}" }

/// canon 词只收 **≥3 个汉字**。
/// 依据:2026-07-26 实测的 4 条误伤(克星规/苏州星盾路/星规市/面星盾悟)**全部**来自 2 字模式
/// 「星轨」;≥4 字的「甲项目」家族零误伤。2 字词进拼音层只会把误伤面扩大(同音写法比字面写法多),
/// 而收窄它的手段(边界约束)还没解锁 → 本轮宁可少覆盖。
/// ⛔ 门槛由代码强制,不靠写文档提醒 —— 上一轮的踩过的坑就是"规则住在没人加载的文件里"。
let kCanonMinHan = 3

/// canon 词表:`["甲项目", ...]`,只要正确写法,不用穷举错法。
func loadCanon() -> [(term: String, key: String)] {
    let f = readableProjectFile("canon.json")
    guard let d = try? Data(contentsOf: f),
          let arr = try? JSONSerialization.jsonObject(with: d) as? [String] else { return [] }
    var out: [(String, String)] = []
    for t in arr {
        guard t.count >= kCanonMinHan, t.allSatisfy(isHan) else {
            log("canon 跳过 \(t):只收纯汉字且 ≥\(kCanonMinHan) 字（拼音层安全门槛,见 kCanonMinHan）")
            continue
        }
        out.append((t, pinyinOf(t)))
    }
    return out
}

/// 拼音层:定长窗口滑过原文,窗口拼音 == canon 拼音键则替换为正确写法。
/// ⛔ 不要整串转拼音再回映射字符位置 —— 那个对应关系脆弱且会静默错位。逐字取拼音后,
/// 窗口下标**天然就是字符下标**,替换不可能错位。
func applyCanon(_ text: String, _ canon: [(term: String, key: String)]) -> (String, Int) {
    guard !canon.isEmpty else { return (text, 0) }
    var chars = Array(text)
    var py = chars.map { pinyinOf(String($0)) }
    var n = 0
    for (term, key) in canon {
        let w = term.count
        guard w > 0, w <= chars.count else { continue }
        let termChars = Array(term)
        var i = 0
        while i + w <= chars.count {
            if py[i..<(i + w)].joined() == key && Array(chars[i..<(i + w)]) != termChars {
                chars.replaceSubrange(i..<(i + w), with: termChars)
                // 等长替换,py 同步换掉即可保持下标对齐
                py.replaceSubrange(i..<(i + w), with: termChars.map { pinyinOf(String($0)) })
                n += 1
                i += w
            } else {
                i += 1
            }
        }
    }
    return (String(chars), n)
}

/// 两层合起来:字面层(精确,优先)→ 拼音层(泛化)。
func correct(_ text: String, _ rules: [(String, String)], _ canon: [(term: String, key: String)],
             _ protected: [String] = []) -> (text: String, dictFixes: Int, canonFixes: Int) {
    let (a, d) = applyDict(text, rules, protected)
    let (b, c) = applyCanon(a, canon)
    return (b, d, c)
}

/// 自检用:等主路径真的走到 deliver
let mainPathDone = DispatchSemaphore(value: 0)
/// ⛔ 断言必须有东西**消费**它,否则跟一句没人读的 warn 一样等于不存在
/// (本 repo 记过三次的同一个形状)。deliver 里那条剪贴板断言的结果落在这里,
/// 由 `--selftest-mainpath` 的退出码消费。
var mainPathClipboardOK = false

// MARK: - 转写

func transcribe(_ fileURL: URL, key: String) -> String? {
    if kSelftest {                       // 自检:不出网,回一句含真实错例的占位
        log("SELFTEST: transcribe 被调用（未出网）")
        return "甲项目的资料库先不要动，乙项目那边等确认之后再说。"
    }
    guard let audio = try? Data(contentsOf: fileURL) else { log("读音频失败"); return nil }
    for attempt in 1...(kRetries + 1) {
        let boundary = "----mossptt\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        for (k, v) in [("model", kModel), ("response_format", "json")] {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; "
            + "filename=\"a.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        add("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: URL(string: kAPI)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let sem = DispatchSemaphore(value: 0)
        var result: String?
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err { log("网络错误: \(err.localizedDescription)"); return }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                let b = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                log("HTTP \(http.statusCode): \(b.prefix(200))")
                return
            }
            guard let data = data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = j["text"] as? String else { log("响应解析失败"); return }
            result = t
        }.resume()
        sem.wait()

        // 空字符串 = 已知的偶发失败(实测 ≈6%),重试即可;不是模型答不出来
        if let r = result, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return r
        }
        log("第 \(attempt) 次返回空,重试…")
    }
    return nil
}

// MARK: - 输出

/// 走剪贴板 + ⌘V 而非逐字符键入 —— CJK 用 CGEvent 逐字键入在不少 app 里会丢字。
/// 没有辅助功能权限时降级为「只放剪贴板」,并告诉用户自己按 ⌘V。
/// 目标 app 里没有焦点元素时,点一下它的输入框 —— 否则 ⌘V 没有落点。
/// ⚠ 会动一下鼠标,但**立刻放回原处**;只在语音模式且确实没焦点时才做。
func focusComposerIfNeeded(appName: String) {
    guard AXIsProcessTrusted() else { return }
    guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.localizedName == appName }) else { return }
    let ax = AXUIElementCreateApplication(app.processIdentifier)

    var focused: AnyObject?
    if AXUIElementCopyAttributeValue(ax, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
       focused != nil {
        return                                   // 已经有落点,别多事
    }
    // 找主窗口的位置与大小
    var winsV: AnyObject?
    guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &winsV) == .success,
          let wins = winsV as? [AXUIElement], let w = wins.first else { return }
    func point(_ attr: String) -> CGPoint? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(w, attr as CFString, &v) == .success, let v = v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }
    func size(_ attr: String) -> CGSize? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(w, attr as CFString, &v) == .success, let v = v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var sz = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &sz) ? sz : nil
    }
    guard let pos = point(kAXPositionAttribute), let sz = size(kAXSizeAttribute), sz.height > 200 else { return }

    // 输入框在窗口底部;留 55pt 余量避开最底下那条
    let target = CGPoint(x: pos.x + sz.width / 2, y: pos.y + sz.height - 55)
    let saved = CGEvent(source: nil)?.location
    guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: target, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: target, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.08)
    if let saved = saved {   // ⛔ 鼠标放回原处 —— 别把用户的光标留在别人窗口里
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: saved, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}

/// ⚠ 只给自检用:把投递引到内存,避免自检真往焦点框粘字
var deliverProbe: ((String) -> Void)?

func deliver(_ text: String) {
    if let p = deliverProbe { p(text); return }
    // ⛔⛔ 2026-07-28 作者 抓:「凭什么要我先把光标点进对话框？我就是不想进去看字」。
    // 上一版我按"你开口那一刻的焦点"投递 —— 那还是要求你先把光标放对地方,方向错了。
    // ⭐ 正确的:**自动把目标 app 切到前台、粘、回车,再把焦点还给你原来那个 app**。
    //    你全程不点任何东西,也不会被拽走。
    // ⚠ 已查实的边界:Claude 只有**一个窗口**,多个 session 在里面切 ——
    //    所以我从外面**送不到指定的那个 session**,字只会进 app 当前打开的那个。
    //    徽章里的选择只决定**谁念给你听**,决定不了字进哪儿。这条如实标,不假装能做到。
    var backTo: NSRunningApplication?
    if VoiceMode.isOn {
        let want = (hudConfig()["voice_target_app"] as? String) ?? "Claude"
        let cur = NSWorkspace.shared.frontmostApplication
        if cur?.localizedName != want,
           let target = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == want }) {
            backTo = cur
            target.activate(options: [])
            Thread.sleep(forTimeInterval: 0.25)     // 等它真的到前台再粘
        }
        // ⛔⛔ 2026-07-28 作者 实测:窗口拉回来了,**但字没进输入框**。
        // 查实:Claude 到了前台却「没有任何焦点元素」(AXFocusedUIElement = missing) ——
        // ⌘V 于是掉地上。**光激活 app 不够,还得给它一个落点。**
        // ⇒ 没有焦点元素时,点一下输入框(窗口底部中间),点完把鼠标放回原处。
        focusComposerIfNeeded(appName: (hudConfig()["voice_target_app"] as? String) ?? "Claude")
    }
    let pb = NSPasteboard.general
    // 用完还原剪贴板 —— 否则用户刚 ⌘C 复制的东西会在几秒后被转写文本顶掉,
    // 而他并不知道。(2026-07-25 判官 #4:剪贴板被无条件 clearContents 且从不恢复)
    let saved = pb.string(forType: .string)
    pb.clearContents()
    pb.setString(text, forType: .string)

    // ⛔⛔ F-2(2026-07-26 独立复核实测):这个短路点**原来在函数第一行** ——
    // 于是剪贴板保存 / setString / AX 判定 / ⌘V / 0.6s 还原**整段从未被任何一项闸断言过**,
    // 而第 7 项却声称「驱动生产 deliver」。独立复核把 setString 的内容换成一句固定垃圾,
    // 产品每次说话都粘出垃圾,而十项闸无一响。**那是转写结果到达焦点框的最后一公里。**
    // 现在短路点挪到 setString **之后**,并真的断言剪贴板里躺着的就是修正后的文本。
    // ⚠ 仍然断言不了的那半(如实标,不假装):`AXIsProcessTrusted()` 分支与 **CGEvent ⌘V 投递** ——
    //   自动化闸里 post 一次真 ⌘V 会把字粘进当时聚焦的任何窗口,**不能做**。那一段只能靠人按一次键。
    if kSelftest {
        let got = pb.string(forType: .string) ?? "(nil)"
        mainPathClipboardOK = (got == text)
        if mainPathClipboardOK {
            log("SELFTEST: deliver 剪贴板内容正确 → \(text)")
        } else {
            log("SELFTEST: ✗ deliver 剪贴板内容不对 —— 期望「\(text)」实得「\(got)」")
        }
        if let saved = saved { pb.clearContents(); pb.setString(saved, forType: .string) }
        mainPathDone.signal(); return
    }

    guard AXIsProcessTrusted() else {
        log("未授予辅助功能权限 → 已放进剪贴板,请自行 ⌘V")
        beep("Basso")
        return   // 这条路径不还原:用户还要自己粘,还原了就粘不到了
    }
    guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
    let v = CGKeyCode(kVK_ANSI_V)
    let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)

    // ⛔ 语音模式下补一个回车 —— 否则"我们俩在对话"每轮还要你伸手按 Enter,
    // 那就还是"一条一条发消息",正是 作者 要摆脱的东西。
    // ⚠ 只在语音模式开着时补:平时按住说话仍然只粘不发,免得说错了没机会改。
    if VoiceMode.isOn {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            defer {
                // ⛔ 发完把焦点还给你原来那个 app —— 否则你每说一句就被拽到 Claude 里
                if let b = backTo {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { b.activate(options: []) }
                }
            }
            if let d = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Return), keyDown: true),
               let u = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Return), keyDown: false) {
                d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap)
            }
        }
    }

    if let saved = saved {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pb.clearContents()
            pb.setString(saved, forType: .string)
        }
    }
}

// MARK: - 方案丙 · 转写后浮层一键否决（作者 2026-07-26 拍 Q11丙）
//
// 要解决的洞:唯一知道"说错了"的人是 作者,而他**在字被粘出来那一刻就知道**;
// 事后开网页(review.py)要求他重新回忆 —— 作者 改判:「为什么每次我都要到那个 HTML 里一句一句改」。
// ⛔ 而「按热键说出更正」原理上不成立:要更正的词恰恰是 ASR 听不出的那个
//    (说「是 MICA 不是 Mika」转出来是「是 Mika 不是 Mika」)。语音只能给指针,给不了拼写。
// → 所以浮层只负责**一键指出"这条不对"**,正确拼写留到我下次跟 作者 说话时问。
//
// ⛔ 不抢焦点是硬要求(作者 正在别的窗口打字)。已用独立探针实测:
//    显示前后 frontmost 不变 · canBecomeKey=false · isKeyWindow=false · 本进程未被激活。
final class HUD {
    static let shared = HUD()
    private var panel: NSPanel?
    private var hideAt: Date?
    private var last: (raw: String, fixed: String, fired: Bool)?

    /// 浮层活着 = 否决键有效。4 秒后自动失效。
    var isLive: Bool { hideAt.map { Date() < $0 } ?? false }

    func show(raw: String, fixed: String, fired: Bool) {
        guard kHUD else { return }
        last = (raw, fixed, fired)
        let text: String = fired
            // 词表开火了 → 这是**误伤**通道:给差异,作者 一眼看"改对了吗"
            ? "词表改了：\(diffFragment(raw, fixed))"
            // 没开火(真实语料里的常态) → **漏改**通道:给结果尾部,作者 看"听对了吗"
            : String(fixed.suffix(24))
        let p = panel ?? makePanel()
        panel = p
        // 那句话挪进悬停提示 —— 要看才看,不看就只是一个 26pt 的点
        p.contentView?.toolTip = "\(text)\n\n点这里 或 双击热键 = 这条不对"
        place(p)                      // ⛔ 每次都重新定位:焦点框换了地方,浮层要跟过去
        p.orderFrontRegardless()      // ⛔ 不是 makeKeyAndOrderFront —— 那会夺走键盘焦点
        hideAt = Date().addingTimeInterval(kHUDSeconds)
        scheduleHide()
    }

    /// 0.4s 轮询而不是一次性定时:为了**鼠标悬在浮层上就续命** ——
    /// 「我正看着它」是最直接的"别关"信号,不用再发明一个按键。
    private func scheduleHide() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self, let p = self.panel, let h = self.hideAt else { return }
            if p.frame.contains(NSEvent.mouseLocation) {
                self.hideAt = Date().addingTimeInterval(2)   // 移开后再给 2 秒
                self.scheduleHide(); return
            }
            if Date() >= h { p.orderOut(nil); self.hideAt = nil; return }
            self.scheduleHide()
        }
    }

    /// 作者 说这条不对 → ⛔ **绝不**直接写 dict.json / negatives.txt
    /// (§17.1 判据:任何自动写词表的路径 = 直接否)。只落候选队列,确认在聊天里发生。
    @objc func veto() {
        guard let l = last else { return }
        panel?.orderOut(nil); hideAt = nil; last = nil
        appendPending(raw: l.raw, fixed: l.fixed, fired: l.fired)
        beep("Submarine")
        log("已记否决 → pending-review.jsonl（\(l.fired ? "误伤" : "漏改")通道）")
    }

    /// ⛔ 2026-07-28 作者 第二次改判:「你没必要弄成那么大一个板在那儿,给我弄一个红色的按钮就好了」。
    /// **这不只是审美** —— 那块板在常态下显示的是 作者 **已经看得见**的东西:
    /// 词表没开火时它只是把刚粘出去那句话的尾巴又抄一遍,而那句话就在他眼前。
    /// 真正会丢失的信息只有词表**开火那一次**(原文被替换掉了,不显示就永远看不到),
    /// 而那在真实语料里是 **0/26**。⇒ 常态零信息量的东西不该占 380×64。
    /// 现在:一个 26pt 红点。那一句话挪进**悬停提示**(要看才看,不看不占地方)。
    static let kDot: CGFloat = 26
    private func makePanel() -> NSPanel {
        let d = HUD.kDot
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: d, height: d),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        let bg = NSView(frame: NSRect(x: 0, y: 0, width: d, height: d))
        bg.wantsLayer = true
        bg.layer?.cornerRadius = d / 2                       // 圆点
        bg.layer?.backgroundColor = NSColor.systemRed.cgColor
        bg.layer?.borderWidth = 1.5
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        bg.autoresizingMask = [.width, .height]
        // 点里放一个 ✕:红点单独出现时不知道点了会怎样,✕ 让"这条不对"一眼可懂
        let mark = NSTextField(labelWithString: "✕")
        mark.frame = NSRect(x: 0, y: (d - 16) / 2 - 1, width: d, height: 16)
        mark.alignment = .center
        mark.font = .systemFont(ofSize: 12, weight: .bold)
        mark.textColor = .white
        mark.isSelectable = false
        bg.addSubview(mark)
        // 鼠标路:点红点 = 否决(键盘手用双击,鼠标手不用记键)
        let click = NSClickGestureRecognizer(target: self, action: #selector(veto))
        bg.addGestureRecognizer(click)
        p.contentView = bg
        return p
    }

    /// ⛔ 2026-07-28 作者 改判:「浮窗出现的位置太偏了」——
    /// 原设计钉在屏幕右上角,理由是"跟着光标会在视线正中反复闪 = 打断"。
    /// **那个理由只优化了一个轴(不打断),漏了正交的另一个(看得见)。**
    /// 屏角离视线太远 ⇒ 要么错过、要么得专门扭头去找,反而更打断。
    /// 现在锚到**插入点正下方** —— 那就是眼睛所在的地方,而且它不遮挡你正在写的那一行。
    /// ⚠ 「跟光标」跟「跟插入点」是两件事:鼠标在打字时根本不在视线里,插入点才是。
    private func place(_ p: NSPanel) {
        let size = p.frame.size
        guard let scr = NSScreen.main else { return }
        let v = scr.visibleFrame

        func clamp(_ pt: NSPoint) -> NSPoint {
            NSPoint(x: min(max(pt.x, v.minX + 8), v.maxX - size.width - 8),
                    y: min(max(pt.y, v.minY + 8), v.maxY - size.height - 8))
        }

        switch kHUDPosition {
        case "topright":
            p.setFrameOrigin(clamp(NSPoint(x: v.maxX - size.width - 20, y: v.maxY - size.height - 20)))
        case "bottom":
            p.setFrameOrigin(clamp(NSPoint(x: v.midX - size.width / 2, y: v.minY + 60)))
        default:   // "caret"
            if let c = caretRectOnScreen(), c.width >= 0, c.height > 0 {
                // ⛔ 别放"插入点正下方居中"—— 那正是下一行字要去的地方,会挡住 作者 接着写的内容。
                // 改为**斜右下**:离眼睛仍然近,但躲开了正下方(下一行)和正右方(下一个字)两条文本流。
                var y = c.minY - size.height - 6
                if y < v.minY + 8 { y = c.maxY + 6 }        // 贴屏幕底就翻到上方
                p.setFrameOrigin(clamp(NSPoint(x: c.maxX + 8, y: y)))
            } else {
                // 拿不到插入点(app 不暴露 AX / 没授权)→ 底部居中,仍比屏角近得多
                p.setFrameOrigin(clamp(NSPoint(x: v.midX - size.width / 2, y: v.minY + 60)))
            }
        }
    }

    /// 问系统要**当前插入点**的屏幕矩形。三级降级,任何一级失败都不抛不崩。
    /// 坐标系:AX 用「主屏左上为原点、y 向下」,NSWindow 用「左下为原点、y 向上」—— 必须换算。
    private func caretRectOnScreen() -> NSRect? {
        guard AXIsProcessTrusted(), let main = NSScreen.screens.first else { return nil }
        let sys = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused else { return nil }
        let elem = f as! AXUIElement

        func flip(_ r: CGRect) -> NSRect {
            NSRect(x: r.origin.x, y: main.frame.maxY - r.origin.y - r.size.height,
                   width: r.size.width, height: r.size.height)
        }
        func rect(from v: AnyObject) -> CGRect? {
            var r = CGRect.zero
            guard CFGetTypeID(v) == AXValueGetTypeID(),
                  AXValueGetValue(v as! AXValue, .cgRect, &r) else { return nil }
            return r
        }

        // ① 插入点本身的矩形(最准)
        var rangeV: AnyObject?
        if AXUIElementCopyAttributeValue(elem, kAXSelectedTextRangeAttribute as CFString, &rangeV) == .success,
           let rv = rangeV {
            var boundsV: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                    elem, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &boundsV) == .success,
               let bv = boundsV, let r = rect(from: bv), r.height > 0 {
                return flip(r)
            }
        }
        // ② 退到焦点控件的框,贴它的底边
        var frameV: AnyObject?
        if AXUIElementCopyAttributeValue(elem, "AXFrame" as CFString, &frameV) == .success,
           let fv = frameV, let r = rect(from: fv), r.height > 0 {
            return flip(CGRect(x: r.midX, y: r.maxY, width: 0, height: 1))
        }
        return nil
    }

    /// 只给差异片段,不打整句 —— 浮层不是日志
    private func diffFragment(_ a: String, _ b: String) -> String {
        let ac = Array(a), bc = Array(b)
        var i = 0
        while i < ac.count && i < bc.count && ac[i] == bc[i] { i += 1 }
        var j = 0
        while j < ac.count - i && j < bc.count - i && ac[ac.count - 1 - j] == bc[bc.count - 1 - j] { j += 1 }
        let from = String(ac[i..<max(i, ac.count - j)])
        let to   = String(bc[i..<max(i, bc.count - j)])
        return from.isEmpty && to.isEmpty ? String(b.suffix(24)) : "\(from) → \(to)"
    }
}

/// ⛔ 含原文 ⇒ 与 `transcripts.jsonl` 同禁区:不入库、不分享、不整读进对话。
/// 我只读**词级差异与条目号**(沿用 `--candidates` 已验证过的隐私形状)。
func appendPending(raw: String, fixed: String, fired: Bool) {
    let rec: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()),
                              "raw": raw, "fixed": fixed, "fired": fired,
                              "channel": fired ? "误伤" : "漏改"]
    guard let d = try? JSONSerialization.data(withJSONObject: rec),
          var line = String(data: d, encoding: .utf8) else { return }
    line += "\n"
    let f = logDirURL.appendingPathComponent("pending-review.jsonl")
    try? FileManager.default.createDirectory(at: logDirURL, withIntermediateDirectories: true)
    if let h = try? FileHandle(forWritingTo: f) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: f, atomically: true, encoding: .utf8)
    }
}

// MARK: - 常开麦克风（作者 2026-07-28：「我们俩之间的麦都是一直处于那种开着的状态」）
//
// 作者 的取舍逻辑:云端 TTS 的 4-5 秒延迟改不了,但**麦一直开着能把"轮流等待"的感觉抹掉**,
// 用连续性补偿延迟。
//
// ⛔ 常开带出三个不解决就不能上线的问题(调研档 §6c):
// ① **回声/自听**:麦开着 + 我的声音从扬声器出来 ⇒ 它会把我自己的话录进去转写再发给我 = 死循环。
//    → `setVoiceProcessingEnabled(true)`(系统级回声消除)+ 播放期间收到的语音先当**打断**处理。
// ② **打断**:你一开口就掐掉正在播的 —— 这正是"像真对话"的那一半。
// ③ **边界**:只在语音模式开着时跑。⛔ 绝不全天候 —— 否则录进来的远超 transcripts.jsonl 现有禁区。
final class VoiceLoop {
    static let shared = VoiceLoop()
    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var speaking = false          // 当前是否在"一句话"里
    private var onsetFrames = 0           // 连续多少帧超过门槛(防瞬时噪音)
    private var lastVoiceAt = Date()
    private var running = false
    private var floorRMS: Float = 0.006   // 环境底噪,自适应

    /// ⛔ 阈值全部 config 驱动 —— 改一个数不该花掉一次重新构建+重授权(浮层那两个字段同款教训)
    private var startRMS: Float { Float((hudConfig()["voice_start_rms"] as? Double) ?? 0.02) }
    /// ⭐ 灵敏度用**倍数**而不是绝对值 —— 安静房间和开着空调的房间底噪差很多,
    /// 绝对阈值在一个环境里调好,换个环境就废。倍数是相对底噪的,自动跟着走。
    /// 作者 2026-07-28:「加一个交互来调收音的敏感程度」→ 三档,面板上点。
    var gateMult: Float { Float((hudConfig()["voice_gate_mult"] as? Double) ?? 4.5) }
    /// ⛔ 2026-07-28 作者:「在自己家卧室都嫌敏感，拿到咖啡馆就爆炸了」。
    /// 根因:原来**一帧超过门槛就开录**,而嘈杂环境里持续有人声,于是不停触发。
    /// ⇒ 要求**连续说够一段时间**才算你开口 —— 瞬时噪音(键盘/关门/邻桌一句话)撑不到。
    /// 这比单纯调高阈值好:调高阈值会让你小声说话也听不见,而"持续性"能区分噪音与说话。
    var onsetMs: Double { (hudConfig()["voice_onset_ms"] as? Double) ?? 260 }
    /// 门槛上限 —— 底噪再高,也不许把门槛顶到"正常说话根本进不来"。
    /// 没有它,嘈杂环境里门槛可以无上限地涨,而**涨到听不见你之后就再也降不回来**(没人说话=没帧证明它太高)。
    var gateCeiling: Float { Float((hudConfig()["voice_gate_ceiling"] as? Double) ?? 0.09) }

    /// ⛔⛔ 2026-07-28 咖啡馆第二次 —— 作者:「我话没说完就从收音状态切回听着了」,而且之后再也收不到。
    /// 根因是原来那一行 `if !speaking { floorRMS = floorRMS*0.995 + level*0.005 }`:
    /// **它把你自己的说话声也吸进了底噪**。一段被切断(speaking=false)之后,你还在说的那些帧
    /// 开始抬底噪 → 门槛跟着涨 → 你更进不来 → 更多帧被当底噪吸收。
    /// **这是个正反馈,越说越聋** —— 日志里的形状正是"一段之后 3.2 秒一片死寂"。
    /// ⇒ 升降不对称:
    ///   · **降**:比当前底噪还低的帧,快速跟下去(环境一安静立刻恢复灵敏)
    ///   · **升**:只有判定为「不是人声」的帧才允许抬,而且很慢
    /// ⚠ 判定必须用**更新前**的门槛,否则这一帧会参与抬高它自己要跨过的那道坎。
    static func updateFloor(_ floor: Float, level: Float, isVoice: Bool) -> Float {
        if level < floor { return floor * 0.90 + level * 0.10 }   // 降得快
        if isVoice { return floor }                                // ⛔ 人声一律不吸收
        return floor * 0.999 + level * 0.001                       // 抬得慢
    }
    /// 三档灵敏度。⛔ 提成常量是因为 2026-07-28 实测发现**这三个按钮在咖啡馆里一动没动过门槛**:
    /// 当时它们只改倍数,而咖啡馆底噪 0.0007–0.0060 ⇒ `底噪×倍数` 恒小于绝对下限 0.02
    /// ⇒ 门槛恒等于 0.02。一个不改变任何行为的控件比没有控件更糟 —— 你会以为"调到最钝了还是不行"。
    /// ⇒ 每档同时给 (倍数, 绝对下限):倍数管安静环境,下限管嘈杂环境。
    /// ⚠ 下限的含义 = 「多大的声音才算你在说话」。别人隔一两米说话约 0.02–0.05,
    ///   你对着电脑说话通常 0.1 以上(近讲比远讲响一个数量级)。
    static let presets: [(name: String, mult: Double, floor: Double)] = [
        ("灵敏", 2.5, 0.015), ("标准", 3.5, 0.035), ("迟钝", 5.0, 0.070),
    ]

    /// 纯函数,便于闸直接验上限行为(实例上的 floorRMS 是私有的)
    static func gateFrom(floor: Float, startRMS: Float, mult: Float, ceiling: Float) -> Float {
        max(startRMS, min(floor * mult, ceiling))
    }
    var threshold: Float {
        VoiceLoop.gateFrom(floor: floorRMS, startRMS: startRMS, mult: gateMult, ceiling: gateCeiling)
    }
    private var silenceEnd: TimeInterval { (hudConfig()["voice_silence_ms"] as? Double ?? 1400) / 1000 }
    /// 本段说话的最大音量 —— ⛔ 诊断用,而且是**校准门槛的唯一真数据**:
    /// 「别人的话进来了」和「我的话进不来」都要拿这个数跟门槛比才知道该往哪调,
    /// 否则又是拧一个不知道有没有用的旋钮(2026-07-28 实测:三档灵敏度在咖啡馆里门槛一动没动)。
    private var turnPeak: Float = 0
    /// 麦是不是正收着你说话 —— Composer 靠它判断「你真的停下来了没有」。
    /// ⚠ 写在音频线程、读在主线程,故意不加锁:读到旧值最坏就是多等一轮窗口,不会发半句。
    var isCapturing: Bool { speaking }
    private var minTurn: TimeInterval { (hudConfig()["voice_min_turn_s"] as? Double) ?? 0.5 }
    private var maxTurn: TimeInterval { (hudConfig()["voice_max_turn_s"] as? Double) ?? 30 }

    var isRunning: Bool { running }

    /// ⛔ 状态位是**跨进程**的真相,而它可能被别的东西改掉(闸、脚本、手动 rm)。
    /// 常驻必须定期对账 —— 否则会出现「文件说关、麦还开着且关不掉」,
    /// 2026-07-28 作者 就是这么被卡住的。**一个只在自己按开关时才更新的状态机是不够的。**
    func reconcile() {
        let want = VoiceMode.isOn && !VoiceMode.isMuted
        if want && !running { start() }
        if !want && running { stop() }
        StatusBar.shared.refresh()
    }

    /// 「按状态该不该开着麦」—— 纯判断,不碰设备,闸可以放心验。
    static func wantsRunning() -> Bool { VoiceMode.isOn && !VoiceMode.isMuted }

    func start() {
        guard !running else { return }
        // ⛔⛔ 2026-07-28:闸默认**不许开真麦**。
        // `--selftest-voice` 会 setOn(true) → 开麦;而 deliver 的自检短路只认
        // TINGZHE_SELFTEST_MAINPATH,这个自检没设它 ⇒ 那几秒里你要是正好在说话,
        // 转写会一路走到 **⌘V + 回车,粘进你当时的窗口**。
        // 闸能把字打进用户的聊天框,这不是副作用,是事故。
        // 要验真设备行为:TINGZHE_ALLOW_MIC=1（显式认账）。
        if kQuiet && ProcessInfo.processInfo.environment["TINGZHE_ALLOW_MIC"] != "1" {
            log("（自检态：不打开真麦克风。要验真设备请 TINGZHE_ALLOW_MIC=1）")
            return
        }
        let input = engine.inputNode
        // ⛔ 回声消除:没有它,常开麦必然把我自己的 TTS 录回来 → 死循环
        do { try input.setVoiceProcessingEnabled(true) }
        catch { log("⚠ 回声消除打不开(\(error.localizedDescription)) —— 建议戴耳机,否则会听见自己") }

        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { log("✗ 拿不到麦克风格式,常开麦没启动"); return }
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
            self?.consume(buf, fmt)
        }
        do {
            engine.prepare()
            try engine.start()
            running = true
            log("常开麦已启动（静音 \(Int(silenceEnd * 1000))ms 判一句话说完）")
        } catch {
            log("✗ 常开麦启动失败: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        // ⛔ 光丢掉 engine 还不够:`setVoiceProcessingEnabled(true)` 装的是一个
        // **共享的语音处理 IO 单元**,它会跟着设备句柄一起留下。必须显式关掉。
        // 判据不是"资源干净",是**你能不能相信麦真的关了** —— 系统那个橙点看的就是它。
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        // ⛔ 2026-07-28 实测:光 stop()+removeTap() **不释放音频设备** ——
        // 停完 10 秒仍占着 1 个 CoreAudio 句柄,而从没开过麦的常驻是 0。
        // 后果不是资源泄漏,是**信任**:macOS 的橙点会一直亮着,作者 没法相信麦真的关了。
        // 而"麦到底有没有在听"正是这个功能最需要说得清的一件事。
        // → 整个 engine 丢掉重建,让设备句柄跟着释放。
        engine = AVAudioEngine()
        running = false
        file = nil; fileURL = nil; speaking = false
        // 攒着还没发的话跟着丢掉 —— 否则下次开麦会把上一场的半句话顶在最前面
        Composer.discard()
        log("常开麦已停")
    }

    private func rms(_ b: AVAudioPCMBuffer) -> Float {
        guard let ch = b.floatChannelData?[0] else { return 0 }
        let n = Int(b.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        return (sum / Float(n)).squareRoot()
    }

    private func consume(_ buf: AVAudioPCMBuffer, _ fmt: AVAudioFormat) {
        let level = rms(buf)
        // ⚠ 顺序不能反:先用**更新前**的门槛判这一帧是不是人声,再拿这个判定去更新底噪。
        //   反过来 = 这一帧参与抬高它自己要跨过的坎(原来的写法就是这样)。
        let isVoice = level > threshold
        if !speaking { floorRMS = VoiceLoop.updateFloor(floorRMS, level: level, isVoice: isVoice) }

        // 每帧约 buf.frameLength / sampleRate 秒
        let frameMs = Double(buf.frameLength) / fmt.sampleRate * 1000
        if isVoice {
            onsetFrames += 1
            let sustainedMs = Double(onsetFrames) * frameMs
            if speaking || sustainedMs >= onsetMs {
                // ⛔ 打断:你一开口,我立刻闭嘴。**这条要在"是不是一句话"之前判**,
                // 否则得等一整句说完才停,那就不叫打断了。
                if Speaker.isPlaying { Speaker.shutUp() }
                lastVoiceAt = Date()
                if !speaking { beginTurn(fmt); VoiceBadge.shared.setCapturing(true) }
            }
        } else {
            onsetFrames = 0        // 断了就重新数 —— 必须是**连续**的
        }
        if speaking {
            turnPeak = max(turnPeak, level)
            try? file?.write(from: buf)
            let sinceVoice = Date().timeIntervalSince(lastVoiceAt)
            let dur = turnDuration()
            if (sinceVoice > silenceEnd && dur > minTurn) || dur > maxTurn {
                endTurn()
            } else if sinceVoice > silenceEnd {
                cancelTurn()          // 太短 = 咳嗽/杂音,丢掉别发
            }
        }
    }

    private var turnStart = Date()
    private func turnDuration() -> TimeInterval { Date().timeIntervalSince(turnStart) }

    /// ⛔ 2026-07-28 作者 抓:「光标必须点在输入框里，否则话就丢了」。
    /// 根因:`deliver` 往**当前焦点**粘,而你说话时焦点常常不在那儿(比如刚点过别处)。
    /// ⇒ 在你**开口那一刻**记住焦点元素与前台 app,粘之前先还回去。
    /// 那一刻是对的:你正看着要说进去的那个框。
    static var savedFocus: AXUIElement?
    static var savedApp: NSRunningApplication?
    private func rememberFocus() {
        VoiceLoop.savedApp = NSWorkspace.shared.frontmostApplication
        guard AXIsProcessTrusted() else { return }
        var f: AnyObject?
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
              kAXFocusedUIElementAttribute as CFString, &f) == .success, let f = f {
            VoiceLoop.savedFocus = (f as! AXUIElement)
        }
    }

    private func beginTurn(_ fmt: AVAudioFormat) {
        rememberFocus()
        Composer.userSpeaking()          // 你又开口了 → 撤掉待发计时器

        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("moss-turn-\(UUID().uuidString).caf")
        guard let f = try? AVAudioFile(forWriting: u, settings: fmt.settings) else { return }
        file = f; fileURL = u; speaking = true; turnStart = Date()
        beep("Tink")
    }

    private func cancelTurn() {
        if let u = fileURL { try? FileManager.default.removeItem(at: u) }
        // ⚠ 先落 speaking=false 再刷徽章 —— 徽章要读 isCapturing 才能决定画哪个态,
        //   原来的顺序让它读到"还在收",于是画不出「等你说完」那一档。
        file = nil; fileURL = nil; speaking = false
        VoiceBadge.shared.setCapturing(false)
        // ⛔ 这一段被丢了(太短=咳嗽/杂音),但 beginTurn 已经撤过计时器 ——
        //   不在这儿重新上弦,前面攒着的话就**永远发不出去**了。
        Composer.arm()
    }

    private func endTurn() {
        guard let u = fileURL else { cancelTurn(); return }
        file = nil; fileURL = nil; speaking = false
        VoiceBadge.shared.setCapturing(false)
        // 诊断:下次再出现「说着说着就聋了」,日志里直接有数,不用再靠推理。
        log(String(format: "一段结束 · 峰值 %.4f · 门槛 %.4f · 底噪 %.4f（峰值/门槛 = %.1f 倍）",
                   turnPeak, threshold, floorRMS, turnPeak / max(threshold, 0.0001)))
        turnPeak = 0
        beep("Pop")
        Controller.shared.transcribeTurn(u)
    }
}

/// ⛔⛔ 2026-07-28 咖啡馆实证 —— 作者 的一句话被切成三条发出去,**连着打断我三次**:
///     「我需要就是说有一个单方面静音的功能。」/「个呢就是。」/「呃呃，我需要能够在那种单条语音发送。」
/// 根因**不是**灵敏度:当时 `voice_gate_mult` 已经是最钝的 5.0,照样如此,
/// 而且进来的每一段都是 作者 本人的话 —— 麦没有误触发,**它听对了,是我发错了**。
/// 真正的病:我把**一段音频的边界**直接当成了**一条消息的边界** ——
/// 静音 1.4 秒 → endTurn → 转写 → 粘贴 **+ 回车**。而人边想边说,停 1.4 秒太常见了。
/// ⇒ 两个边界拆开:
///    · `voice_silence_ms`(1.4s)= 一段音频说完 → **立刻转写**(首字延迟、分块长度都不变)
///    · `voice_send_after_ms`(3.2s)= 一条消息说完 → 才 ⌘V + 回车
///    中间转写出来的碎片先攒着,拼成一条再发。
/// ⭐ 判据不是"多长算一句话"(那又是猜一个数),是**你真的不说话了**:
///    还在说(`isCapturing`)或还有转写在路上(`inFlight > 0`)→ 计时器一律不许响。
enum Composer {
    private static let lock = NSLock()
    private static var buf: [(raw: String, fixed: String, fired: Bool)] = []
    private static var inFlight = 0
    private static var timer: DispatchWorkItem?

    /// 两种发送方式并行(作者 2026-07-28 拍:「两种方式并行，不是让你用旧的替代掉，要能来回切换」):
    ///  · `batch`(默认)= 攒到你真的停下来,拼成一条发 —— 边想边说不会被切碎
    ///  · `instant`    = 一段一条,立刻发 —— 快问快答,或者你要的就是"一句一条语音"那种节奏
    /// ⛔ instant **不是**"把窗口设成 0":那样第一段仍要等后面那段的转写落地(inFlight 闸拦着),
    ///   而 instant 的全部意义就是**不等**。所以它走的是攒之前那条老路 —— 那条路一个字没改,
    ///   顺序投递的闸(乱序完成仍按原顺序)照旧守着它。
    static var isInstant: Bool {
        if let s = ProcessInfo.processInfo.environment["TINGZHE_SEND_MODE"], !s.isEmpty {
            return s == "instant"
        }
        return ((hudConfig()["voice_send_mode"] as? String) ?? "batch") == "instant"
    }

    /// env 覆盖只给自检用 —— 让闸走**同一条**攒/拼/发的路,只是不用真等 3.2 秒。
    static var windowSec: TimeInterval {
        if let s = ProcessInfo.processInfo.environment["TINGZHE_SEND_AFTER_MS"], let v = Double(s) {
            return v / 1000
        }
        return ((hudConfig()["voice_send_after_ms"] as? Double) ?? 3200) / 1000
    }

    /// 你又开口了 → 撤掉待发计时器。**这条是整件事的关键**:
    /// 计时器只有在你确实停下来之后才该开始走,否则又变成"按停顿切消息"。
    static func userSpeaking() {
        lock.lock(); timer?.cancel(); timer = nil; lock.unlock()
    }
    static func enter() { lock.lock(); inFlight += 1; lock.unlock() }
    static func leave() {
        lock.lock(); inFlight -= 1; lock.unlock()
        arm()
        VoiceBadge.shared.setCapturing(false)   // 转写落地 → 徽章换到「等你说完」
    }

    static func append(raw: String, fixed: String, fired: Bool) {
        lock.lock(); buf.append((raw, fixed, fired)); lock.unlock()
    }

    static func discard() {
        lock.lock(); buf.removeAll(); timer?.cancel(); timer = nil; inFlight = 0; lock.unlock()
    }
    static var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return buf.count }
    /// 手上还攥着你的话没发 —— 徽章据此画第三档「等你说完」。
    /// ⛔ 必须含 inFlight:一段刚说完、转写还在路上时 buf 还是空的,
    ///   而那正是你最需要看到「它还拿着我的话」的那几秒。
    static var isHolding: Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight > 0 || !buf.isEmpty
    }

    static func arm() {
        lock.lock()
        timer?.cancel(); timer = nil
        guard inFlight <= 0, !buf.isEmpty else { lock.unlock(); return }
        let w = DispatchWorkItem { flush() }
        timer = w
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + windowSec, execute: w)
    }

    /// 拼成一条发出去。⛔ 还在说话 / 还有转写在路上 → 再等一轮。**宁可晚发,不可发半句。**
    static func flush() {
        if VoiceLoop.shared.isCapturing { arm(); return }
        lock.lock()
        guard inFlight <= 0, !buf.isEmpty else {
            let retry = !buf.isEmpty
            lock.unlock()
            if retry { arm() }
            return
        }
        let items = buf
        buf.removeAll(); timer = nil
        lock.unlock()
        let raw = join(items.map { $0.raw })
        let fixed = join(items.map { $0.fixed })
        log("攒够一条(\(items.count) 段)→ 发出:\(fixed)")
        deliver(fixed)
        HUD.shared.show(raw: raw, fixed: fixed, fired: items.contains { $0.fired })
        VoiceBadge.shared.setCapturing(false)   // 发完 → 徽章回「听着」
    }

    /// 中文碎片直接接上(「…功能。」+「个呢就是。」),只有两边都是英文字母/数字才补空格 ——
    /// 否则 `work` + `hard` 会粘成 `workhard`。
    private static func join(_ xs: [String]) -> String {
        var out = ""
        for x in xs where !x.isEmpty {
            if let a = out.last, let b = x.first,
               a.isASCII, b.isASCII, a.isLetter || a.isNumber, b.isLetter || b.isNumber {
                out += " "
            }
            out += x
        }
        return out
    }
}

// MARK: - 流式朗读(MOSS-TTS-v1.5-Flash)

/// ⭐ 2026-07-28 · 作者 给了 platform.mosi.cn 的模型页,实测确认:
///   `POST /v1/audio/speech` + `model=moss-tts` + **`version=flash-20260626`** + `stream=true`
///   + `response_format=pcm` → 200,**首块音频 1.19 秒**(非流式是 ~4 秒),310 块持续到达。
/// ⛔ 我此前断言"MOSS 不支持流式"是错的 —— 错因是**我从没传过 `version`**,
///   而 400 的报错文案(`unsupported_response_format`)把我引向了格式,没引向版本。
///   → 铁律复用:「X 做不到」的断言必须附"我试过什么",而我试过的组合里缺了官方文档写明的那个参数。
///
/// ⛔ 两个实测数字,都不是猜的:
///   ① flash 流式版是 **48000 Hz 立体声 16bit**(默认版是 24000 Hz 单声道)——
///      直接读非流式 wav 头量出来的。**猜错就是花栗鼠音或慢动作**。
///   ② 本机只有 `afplay`,而它**跟不住正在长大的 wav**(4.0 秒音频 2.90 秒就退出)。
///      所以播放必须在进程内做,不能再外包给 afplay —— 这就是这个类存在的理由。
enum TTS {
    static func requestBody(_ text: String) -> [String: Any] {
        [
            "model": (hudConfig()["tts_model"] as? String) ?? "moss-tts",
            "version": (hudConfig()["tts_stream_version"] as? String) ?? "flash-20260626",
            "stream": true,
            "input": text,
            "response_format": "pcm",
        ]
    }
    static var sampleRate: Double { (hudConfig()["tts_sample_rate"] as? Double) ?? 48000 }
    /// ⛔⛔ 2026-07-28 作者:「你发给我的语音现在完全都是花的」。
    /// 根因:这里原来是 **2**。我拿**非流式 wav 的头**(2 声道 48k)去推流式 pcm 的格式,
    /// 而那条流其实是**单声道** —— 按立体声解交错,每个声道拿到的是隔一个的采样,
    /// 等于半速 + 噪音,正好就是"全是花的"。
    /// 实测判据(两条独立,都不靠耳朵):
    ///  ① 交错立体声里相邻一对是同一时刻的左右声道,几乎相同 ——
    ///     参照 wav 相邻对平均差 0.8 / 隔一个 235.4(比值 292);这条流是 218.9 / 408.4(比值 1.87)。
    ///  ② 基频:参照(已知 48k)162.7 Hz;这条流按 48k 单声道解得 174.5 Hz(同一个嗓子),
    ///     按 24k 解得 87.3 Hz(低了整整一个八度)。
    /// ⚠ 教训:**非流式的头不能拿来推流式的格式**,它们是两条不同的编码路径。
    static var channels: UInt32 { UInt32((hudConfig()["tts_channels"] as? Int) ?? 1) }

    /// 这块数据看起来像不像**交错立体声**。⛔ 存在的理由:格式配错时产物是噪音,
    /// 而噪音**不会让任何断言变红** —— 上一版闸拿自己造的立体声 buffer 测解交错器,
    /// 绿得好好的,而 作者 耳朵里全是花的。这个函数让"格式不对"能被机器发现。
    /// 判据:交错立体声的相邻一对 = 同一时刻左右声道,差值远小于隔一个(同声道相邻时刻)。
    static func looksStereo(_ data: Data) -> Bool? {
        let n = data.count / 2
        guard n >= 2048 else { return nil }               // 太短,不下结论
        var pair = 0.0, skip = 0.0, cnt = 0.0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let s = raw.bindMemory(to: Int16.self)
            var i = 0
            while i + 2 < n {
                pair += abs(Double(Int16(littleEndian: s[i])) - Double(Int16(littleEndian: s[i + 1])))
                skip += abs(Double(Int16(littleEndian: s[i])) - Double(Int16(littleEndian: s[i + 2])))
                cnt += 1; i += 2
            }
        }
        guard cnt > 0, skip > 0 else { return nil }       // 全是静音 → 不下结论
        // ⚠ pair 可能**恰好为 0**(左右逐位相同的合成信号) —— 那是"最立体声"的情形,
        //   而不是"没结论"。第一版把它 guard 掉了,于是闸自己的合成立体声被判成 nil。
        return (skip / max(pair, 1e-9)) > 8.0             // 实测:真立体声 ~292,单声道 ~1.9
    }

    /// 打断信号 —— 你一开口,常驻碰一下这个文件,正在念的那个进程看见就闭嘴。
    /// ⛔ 不能再用 `pkill -x tingzhe`:**常驻自己也叫这个名字**,一 pkill 连它一起杀。
    ///   (旧路是 pkill afplay,那时候念的是 afplay 所以没事;播放挪进来之后这条就变致命了。)
    static var shutUpFlag: URL {
        VoiceMode.flagURL.deletingLastPathComponent().appendingPathComponent("shutup")
    }
    static func signalShutUp() {
        try? FileManager.default.createDirectory(at: shutUpFlag.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data("\(Date().timeIntervalSince1970)".utf8).write(to: shutUpFlag)
    }
    static func shutUpToken() -> String {
        (try? String(contentsOf: shutUpFlag, encoding: .utf8)) ?? ""
    }

    /// ⛔⛔ 差点漏掉的致命处:`Speaker.isPlaying` 原来查 `pgrep -x afplay`,
    /// 而念声音的进程现在叫 `tingzhe --speak` ⇒ isPlaying 恒 false ⇒ **shutUp 永远不被调用**
    /// ⇒ **打断整个失效,而且不报任何错**。换播放方式时必须同时换"谁在播"的判据 ——
    /// 这两件事看起来是两处,其实是一处。
    /// ⚠ 不用 pgrep 认进程名:常驻自己也叫 tingzhe。用 PID 文件 + `kill -0` 验活,
    ///   崩溃留下的陈旧 PID 会被验活挡掉,不会让 isPlaying 恒真。
    static var speakingFlag: URL {
        VoiceMode.flagURL.deletingLastPathComponent().appendingPathComponent("speaking.pid")
    }
    static func markSpeaking(_ on: Bool) {
        if on {
            try? FileManager.default.createDirectory(at: speakingFlag.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: speakingFlag)
        } else {
            try? FileManager.default.removeItem(at: speakingFlag)
        }
    }
    static var isSpeaking: Bool {
        guard let s = try? String(contentsOf: speakingFlag, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0        // 进程还活着才算在念(挡掉崩溃留下的陈旧 PID)
    }

    /// 交错 int16 → AVAudioPCMBuffer(float32 非交错)。
    /// ⛔ 纯函数,闸直接验 —— 声道解交错错一位,左右声道就会互相灌,听感是"糊在一起"。
    static func buffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ch = Int(format.channelCount)
        let bytesPerFrame = 2 * ch
        let frames = data.count / bytesPerFrame
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            let src = rawBuf.bindMemory(to: Int16.self)
            for f in 0..<frames {
                for c in 0..<ch {
                    dst[c][f] = Float(Int16(littleEndian: src[f * ch + c])) / 32768.0
                }
            }
        }
        return buf
    }
}

/// 一次性把一段话流式念出来。⛔ 走 CLI(`--speak`)而不是常驻内部:
/// 念是**可以被杀掉、可以并发、可以失败**的活,把它关在自己的进程里,
/// 崩了不会带走常驻(而常驻掉了 = 热键和麦一起没)。
final class StreamSpeaker: NSObject, URLSessionDataDelegate {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var fmt: AVAudioFormat!
    private var carry = Data()
    private var formatChecked = false
    private var httpOK = false
    private var status = 0
    private var errBody = Data()
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var inFlightBuffers = 0
    private var firstAudioAt: Date?
    private var startedAt = Date()
    private var aborted = false
    private var token = ""

    func speak(_ text: String, key: String) -> Bool {
        guard !text.isEmpty else { return true }
        guard let f = AVAudioFormat(standardFormatWithSampleRate: TTS.sampleRate,
                                    channels: AVAudioChannelCount(TTS.channels)) else {
            log("✗ 拿不到播放格式（\(TTS.sampleRate)Hz \(TTS.channels)ch）"); return false
        }
        fmt = f
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: f)
        do { try engine.start() } catch { log("✗ 播放引擎起不来: \(error.localizedDescription)"); return false }
        node.play()
        TTS.markSpeaking(true)          // 让常驻知道"现在有人在念",否则打断判据落空
        defer { TTS.markSpeaking(false) }

        token = TTS.shutUpToken()
        // ⛔ 打断得**在播放中途**生效,不是等这段念完 —— 那就不叫打断了。
        let watch = DispatchSource.makeTimerSource(queue: .global())
        watch.schedule(deadline: .now() + 0.05, repeating: 0.05)
        watch.setEventHandler { [weak self] in
            guard let self = self, TTS.shutUpToken() != self.token else { return }
            self.lock.lock(); self.aborted = true; self.lock.unlock()
            self.node.stop()
            self.finished.signal()
        }
        watch.resume()
        defer { watch.cancel() }

        var req = URLRequest(url: URL(string: ((hudConfig()["api_base"] as? String)
                                               ?? "https://api.mosi.cn/v1") + "/audio/speech")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: TTS.requestBody(text))
        req.timeoutInterval = 60
        startedAt = Date()
        let sess = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        sess.dataTask(with: req).resume()

        _ = finished.wait(timeout: .now() + 90)
        lock.lock(); let killed = aborted; lock.unlock()
        if !killed { drain() }
        node.stop(); engine.stop()
        if killed { log("念到一半被你打断"); return false }
        if !httpOK {
            let msg = String(data: errBody.prefix(300), encoding: .utf8) ?? ""
            log("✗ 流式合成失败 http=\(status) \(msg)")
            return false
        }
        if let t = firstAudioAt {
            log(String(format: "念完 · 首块音频 %.2fs · 全程 %.2fs",
                       t.timeIntervalSince(startedAt), Date().timeIntervalSince(startedAt)))
        }
        return true
    }

    /// 等已排进去的都放完。⛔ 请求结束 ≠ 声音放完 —— 网络那头早就说完了,
    /// 而喇叭还有好几秒没响完;这里不等,最后几个字就没了。
    private func drain() {
        while true {
            lock.lock(); let n = inFlightBuffers; let killed = aborted; lock.unlock()
            if n <= 0 || killed { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        httpOK = status == 200
        completionHandler(.allow)          // 非 200 也收,好把错误正文读出来给人看
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard httpOK else { errBody.append(data); return }
        lock.lock()
        // ⛔ 第一块到了就核对格式 —— 配错的产物是**噪音**,而噪音不会让任何断言变红。
        //   2026-07-28 就是这样:闸绿着,作者 耳朵里全是花的。让机器能自己发现这件事。
        if !formatChecked, carry.count + data.count >= 4096 {
            formatChecked = true
            var probe = carry; probe.append(data)
            if let isStereo = TTS.looksStereo(probe) {
                let want = TTS.channels == 2
                if isStereo != want {
                    log("⛔ 音频格式对不上:配的是 \(TTS.channels) 声道，这条流看起来是 \(isStereo ? 2 : 1) 声道 —— 现在放出来会是噪音。改 config.json 的 tts_channels。")
                }
            }
        }
        carry.append(data)
        let bpf = 2 * Int(fmt.channelCount)
        let n = (carry.count / bpf) * bpf
        guard n > 0 else { lock.unlock(); return }
        let chunk = carry.prefix(n)
        carry.removeFirst(n)               // ⚠ 半个采样点留到下一块,否则声道会错位
        lock.unlock()
        guard let buf = TTS.buffer(from: Data(chunk), format: fmt) else { return }
        if firstAudioAt == nil { firstAudioAt = Date() }
        lock.lock(); inFlightBuffers += 1; lock.unlock()
        node.scheduleBuffer(buf) { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); self.inFlightBuffers -= 1; self.lock.unlock()
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error { log("✗ 流式请求出错: \(e.localizedDescription)"); httpOK = false }
        finished.signal()
    }
}

/// 播放侧 —— 只为一件事存在:**让"打断"有东西可打断**。
/// 钩子那边用 afplay 播放,这里负责知道它在不在播、以及一句话把它掐掉。
enum Speaker {
    static var isPlaying: Bool {
        // ⛔ 流式朗读在 tingzhe --speak 里放,不是 afplay —— 只查 afplay 会让打断静默失效
        if TTS.isSpeaking { return true }
        let t = Process(); t.launchPath = "/usr/bin/pgrep"
        t.arguments = ["-x", "afplay"]
        let pipe = Pipe(); t.standardOutput = pipe; t.standardError = Pipe()
        do { try t.run() } catch { return false }
        t.waitUntilExit()
        return t.terminationStatus == 0
    }
    static func shutUp() {
        // ⛔ 流式朗读在**自己的进程**里放,不能 pkill —— 那个进程也叫 tingzhe,
        //   连常驻一起杀。改成碰一下标志文件,它自己看见就闭嘴(TTS.shutUpFlag)。
        TTS.signalShutUp()
        for p in ["afplay", "say"] {          // 兜底:非流式那条路仍走 afplay
            let t = Process(); t.launchPath = "/usr/bin/pkill"
            t.arguments = ["-x", p]; t.standardError = Pipe()
            try? t.run()
        }
        log("你开口了 → 掐掉正在播的")
    }
}

// MARK: - 主控

final class Controller {
    static let shared = Controller()
    private var recorder: AVAudioRecorder?
    private var currentFile: URL?
    private var busy = false
    let key: String
    private(set) var rules: [(String, String)] = []
    private(set) var canon: [(term: String, key: String)] = []
    private(set) var protected: [String] = []
    private(set) var rulesHash = ""
    private var dictStamp: Date?
    private var canonStamp: Date?
    private var negStamp: Date?

    private init() {
        guard let k = loadAPIKey() else {
            log("✗ 找不到 TINGZHE_API_KEY(查 \(projectDir.path)/.env.local)")
            exit(1)
        }
        key = k
        loadTables()
    }

    private func tableStamp(_ name: String) -> Date? {
        let p = projectDir.appendingPathComponent(name).path
        return (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate]) as? Date
    }

    private func loadTables() {
        rules = loadDict()
        canon = loadCanon()
        protected = loadProtected()
        dictStamp = tableStamp("dict.json")
        canonStamp = tableStamp("canon.json")
        negStamp = tableStamp("protect.json")
        // 词表指纹：条数 + 内容长度。够用来区分版本，不必引 CryptoKit。
        let flat = rules.map { $0.0 + "\u{1}" + $0.1 }.joined(separator: "\u{2}")
        rulesHash = "v\(rules.count)+c\(canon.count)+p\(protected.count)-\(flat.count)"
        log("词表已加载 字面 \(rules.count) 条 · canon \(canon.count) 条 · 保护词 \(protected.count) 个 (\(rulesHash))")
    }

    /// 词表热重载。⛔ **不是可选项**:没有它,加一个词就要重启常驻进程,
    /// 而「加词麻烦」会直接杀死方案 A 自己 —— 按 A 的否决条件,30 天后词表仍是 25 条就该撤掉它。
    /// 放在按下热键那一刻做:主线程、与其它改动同线程(无竞态),且语义正确
    /// (「加了词,下次按住说话就生效」)。
    /// ⚠ 非 private:`--selftest-reload` 要驱动它。
    /// 理由:本方法只在按下热键时被调用,而热键按不了 → **判据 N4 原本无法验证**。
    /// 一个我验不了的判据 = 一个我以为会好的地方 = 上一轮"六项全绿而主功能不通"的同型盲区。
    @discardableResult
    func reloadTablesIfChanged() -> Bool {
        guard tableStamp("dict.json") != dictStamp || tableStamp("canon.json") != canonStamp
                || tableStamp("protect.json") != negStamp else { return false }
        log("检测到词表变更 → 热重载")
        loadTables()
        return true
    }

    func startRecording() {
        guard !busy, recorder == nil else { return }
        reloadTablesIfChanged()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tingzhe-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: kSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.record()
            recorder = r
            currentFile = url
            beep("Tink")
            log("● 录音中…")
        } catch {
            log("✗ 录音启动失败: \(error.localizedDescription)")
            beep("Basso")
        }
    }

    /// 常开麦一句话说完 → 走**完全相同**的生产管线。
    /// ⛔ 绝不另写一份转写/词表/投递逻辑 —— 本项目已被独立复核抓过两次「断言测的是副本」,
    /// 而"复制一条管线"正是副本的来源。这里只负责把音频文件交给既有那条路。
    /// ⛔ 2026-07-28 作者 抓:「有时候时间顺序上会切反」。
    /// 根因:每段各自异步转写,**短的那段先转完就先粘出去** = 竞态。
    /// ⇒ 给每段编号,按编号顺序投递;没轮到的先存着。
    private var turnSeq = 0
    private var nextDeliver = 0
    private var pending: [Int: (String, String, Int, Int)] = [:]
    private let seqLock = NSLock()

    private func deliverInOrder(_ seq: Int, _ raw: String, _ fixed: String, _ dn: Int, _ cn: Int) {
        seqLock.lock()
        pending[seq] = (raw, fixed, dn, cn)
        var ready: [(String, String, Int, Int)] = []
        while let item = pending[nextDeliver] {
            ready.append(item); pending.removeValue(forKey: nextDeliver); nextDeliver += 1
        }
        seqLock.unlock()
        for (raw, fixed, dn, cn) in ready {
            DispatchQueue.main.async {
                // ⛔ 语音模式下不许一段一发 —— 那正是咖啡馆里把一句话切成三条的那一刀。
                // 攒进 Composer,等你真的停下来再拼成一条(见 Composer 头注)。
                // ⚠ 顺序在这之前已经排好,append 是按序进的,拼出来就是原话顺序。
                // 一句一条模式走的就是这条老路,不经 Composer —— 作者 要的"两种并行"在这里分叉。
                guard VoiceMode.isOn, !Composer.isInstant else {
                    deliver(fixed)
                    HUD.shared.show(raw: raw, fixed: fixed, fired: (dn + cn) > 0)
                    return
                }
                Composer.append(raw: raw, fixed: fixed, fired: (dn + cn) > 0)
                Composer.arm()
            }
        }
    }

    /// 只给自检用 —— 走的是**同一条** deliverInOrder,不是副本
    func probeDeliverInOrder(_ seq: Int, _ t: String) { deliverInOrder(seq, t, t, 0, 0) }

    /// 只给自检:把投递序号归零,让各测试块互不影响。
    /// ⛔ 归的是**计数器**,不是排队逻辑 —— 顺序规则本身照旧被那些断言守着,这不是绕过。
    /// ⚠ 加它的理由:序号跨块累加已经咬了三次(每加一块新测试就得手算上一块用到几),
    ///   而算错的表现是「静静地一条都不投」—— 看起来像功能坏了,其实是闸自己没对齐。
    func resetSeqForSelftest() {
        seqLock.lock()
        turnSeq = 0; nextDeliver = 0; pending.removeAll()
        seqLock.unlock()
    }

    func transcribeTurn(_ url: URL) {
        seqLock.lock(); let mySeq = turnSeq; turnSeq += 1; seqLock.unlock()
        let t0 = Date()
        // ⛔ 必须在**派出去之前**记账:转写还在路上时 Composer 不许发,
        //   否则慢的那段回来时前半句已经发出去了 —— 又变成半句一条。
        Composer.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // ⚠ leave() 必须在**所有**返回路径上都跑到(含转写为空、转写失败),
            //   漏一条 inFlight 就永远归不了零 → 计时器永远不响 → 话再也发不出去。
            defer { try? FileManager.default.removeItem(at: url); Composer.leave() }
            guard let raw = transcribe(url, key: self.key), !raw.isEmpty else { return }
            let (fixed, dn, cn) = correct(raw, self.rules, self.canon, self.protected)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            log("✓ 常开麦一句 → \(ms)ms" + ((dn + cn) > 0 ? " · 修正 \(dn + cn) 处" : ""))
            appendJSONL(dur: 0, ms: ms, raw: raw, fixed: fixed, fixes: dn + cn,
                        dictHash: self.rulesHash, fixDict: dn, fixCanon: cn)
            self.deliverInOrder(mySeq, raw, fixed, dn, cn)
        }
    }

    func stopAndTranscribe() {
        guard let r = recorder, let url = currentFile else { return }
        // ⛔ currentTime 必须在 stop() 之前读 —— AVAudioRecorder.h 明写
        // "This method is only vaild while recording",stop() 之后恒为 0。
        // 2026-07-25 踩过的坑:原代码在 stop() 之后读,dur 恒为 0 → guard 永远失败
        // → 每一次按住说话都被丢弃,transcribe() 从未被调用过。判官抓出,已实机复现。
        let dur = r.currentTime
        r.stop()
        recorder = nil
        currentFile = nil
        beep("Pop")
        guard dur > 0.4 else {
            log("太短(\(String(format: "%.1f", dur))s),丢弃")
            try? FileManager.default.removeItem(at: url)
            return
        }
        busy = true
        let t0 = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            defer {
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async { self.busy = false }
            }
            guard let raw = transcribe(url, key: self.key) else {
                log("✗ 转写失败(已重试 \(kRetries) 次)")
                DispatchQueue.main.async { beep("Basso") }
                return
            }
            let (fixed, dn, cn) = correct(raw, self.rules, self.canon, self.protected)
            let n = dn + cn
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            log("✓ \(String(format: "%.1f", dur))s 音频 → \(ms)ms"
                + (n > 0 ? " · 修正 \(n) 处(字面 \(dn) / 拼音 \(cn))" : ""))
            if n > 0 { log("  原文: \(raw)") }
            log("  输出: \(fixed)")
            // 结构化侧车日志 —— 作者 2026-07-25 拍 Q2乙「日志全留」,理由是
            // 「不留正文我们后面怎么迭代词表方向的功能,我还想以后往向量化热词表方向迭代」。
            // ⭐ raw 与 fixed 必须分开存:向量化迭代要知道**模型错在哪**,而不只是修完什么样。
            // ⚠ 本文件是明文,含 作者 说过的一切。禁区见 ENGINEERING-NOTES.md。
            appendJSONL(dur: dur, ms: ms, raw: raw, fixed: fixed, fixes: n,
                        dictHash: self.rulesHash, fixDict: dn, fixCanon: cn)
            DispatchQueue.main.async {
                deliver(fixed)
                HUD.shared.show(raw: raw, fixed: fixed, fired: n > 0)
            }
        }
    }
}

// MARK: - 热键

/// 单键长按(右⌘ 之类)必须监听 flagsChanged,而那需要辅助功能权限;
/// Carbon 组合键不需要权限但至少要按两三个键。所以两条路都留:
/// 有权限 → 单键;没权限 → 自动回落 Carbon 组合键,而不是整个不能用。
enum HotKeyStyle {
    case singleModifier(name: String, keyCode: UInt16, flag: NSEvent.ModifierFlags)
    case carbonCombo(name: String, keyCode: UInt32, mods: UInt32)
}

/// 「按住说话」能用的键。⛔ 这里**不能**像三把开关键那样任意配:
/// 长按必须是「按住不放也不打出字」的键 —— 按住字母会打出 vvvvv,那不是保守是真坏。
/// 所以是一份**受约束的枚举**,面板上点一下轮换。作者 2026-07-28:
/// 「那个模式是要按下去我再说话，可是按什么键呢？你根本就没有给我那个配置项」——
/// 之前它只能改 config.json,等于没有入口。
let pttChoices: [(raw: String, label: String, needsAX: Bool)] = [
    ("rightOption",   "右 ⌥（单键）",  true),
    ("rightControl",  "右 ⌃（单键）",  true),
    ("rightCommand",  "右 ⌘（单键·⚠ 会跟 ⌘C/⌘V/⌘Tab 打架）", true),
    ("fn",            "fn（单键·需先在系统设置里把 fn 设为「无操作」）", true),
    ("leftOption",    "左 ⌥（单键·⚠ 日常在用）",  true),
    ("leftControl",   "左 ⌃（单键·⚠ 日常在用）",  true),
    ("leftCommand",   "左 ⌘（单键·⚠ 会跟 ⌘C/⌘V 打架）", true),
    ("f13",           "F13（不需要辅助功能权限）", false),
    ("ctrl+opt+space", "⌃⌥Space（组合键·不需要权限）", false),
]

func hotKeyStyle(from raw: String) -> HotKeyStyle {
    switch raw.lowercased() {
    case "rightcommand", "right_cmd", "rcmd":
        return .singleModifier(name: "右 ⌘", keyCode: UInt16(kVK_RightCommand), flag: .command)
    case "rightoption", "right_opt", "ropt":
        return .singleModifier(name: "右 ⌥", keyCode: UInt16(kVK_RightOption), flag: .option)
    case "rightcontrol", "right_ctrl", "rctrl":
        return .singleModifier(name: "右 ⌃", keyCode: UInt16(kVK_RightControl), flag: .control)
    case "leftcommand", "left_cmd", "lcmd":
        return .singleModifier(name: "左 ⌘", keyCode: UInt16(kVK_Command), flag: .command)
    case "leftoption", "left_opt", "lopt":
        return .singleModifier(name: "左 ⌥", keyCode: UInt16(kVK_Option), flag: .option)
    case "leftcontrol", "left_ctrl", "lctrl":
        return .singleModifier(name: "左 ⌃", keyCode: UInt16(kVK_Control), flag: .control)
    case "fn", "function":
        return .singleModifier(name: "fn", keyCode: UInt16(kVK_Function), flag: .function)
    case "f13":
        return .carbonCombo(name: "F13", keyCode: UInt32(kVK_F13), mods: 0)
    default:
        return .carbonCombo(name: "⌃⌥Space", keyCode: UInt32(kVK_Space),
                            mods: UInt32(controlKey | optionKey))
    }
}

func loadHotKeyRaw() -> String {
    let f = projectDir.appendingPathComponent("config.json")
    if let d = try? Data(contentsOf: f),
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       let v = j["hotkey"] as? String { return v }
    // ⛔ 默认不用右⌘ —— 它是 ⌘C/⌘V/⌘Tab 的修饰键,按住 ⌘Tab 切窗口就会误触发录音,
    // 松手后把环境音转写粘进当前焦点框。2026-07-25 判官 #4 抓出。
    return "rightOption"
}

/// 方案丙的总开关(作者 2026-07-26 拍 Q11丙)。
/// ⭐ 存在的理由:我推荐的是甲、作者 拍的是丙,而丙的已知弱点是「每次说话都被看一眼」。
/// 留这个字段 = 试了不喜欢**改一个 JSON 字段就能关掉**,不用改代码、不用重新构建、**不用重授权**。
func loadHUDEnabled() -> Bool {
    let f = projectDir.appendingPathComponent("config.json")
    if let d = try? Data(contentsOf: f),
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       let v = j["hud"] as? Bool { return v }
    return true
}

/// ⭐ 浮层的**位置与时长都走 config,不写死** —— 理由不是灵活性,是成本:
/// 改一次代码就要正式构建一次,而正式构建可能打掉 作者 的辅助功能授权。
/// 「想把它挪一挪 / 多留两秒」不该花掉一次重新授权。
private func hudConfig() -> [String: Any] {
    let f = projectDir.appendingPathComponent("config.json")
    guard let d = try? Data(contentsOf: f),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return j
}
/// 停留秒数。2026-07-28 作者:「时间也太短了」→ 默认 4s 改 10s。
/// 它不抢焦点也不挡输入,所以留久一点几乎零代价;鼠标悬上去还会继续续命。
func loadHUDSeconds() -> Double {
    if let v = hudConfig()["hud_seconds"] as? Double, v > 0 { return v }
    if let v = hudConfig()["hud_seconds"] as? Int, v > 0 { return Double(v) }
    return 10
}
/// "caret"(默认·插入点正下方) · "bottom"(底部居中) · "topright"(旧的屏角行为)
func loadHUDPosition() -> String {
    (hudConfig()["hud_position"] as? String) ?? "caret"
}

var hotKeyRef: EventHotKeyRef?
var flagsMonitor: Any?

// MARK: - 语音对话模式（作者 2026-07-28：「按一个键就打开，一直打开，再按一个键就关上」）
//
// ⛔ 状态的唯一真相 = `~/Library/Caches/tingzhe/voice-on` 这个文件 ——
// 因为**读它的是另一个进程**（`speak-hook.sh`，Claude 每轮说完时被 Claude Code 拉起来）。
// 进程内的布尔变量它看不见，所以状态必须落在两边都能看到的地方。
enum VoiceMode {
    static var flagURL: URL {
        // ⛔⛔ 2026-07-28 踩过的坑:第 12 项自检把 HOME 指向沙箱就以为隔离了 —— 而 macOS 的
        // `homeDirectoryForCurrentUser` **走 getpwuid,不认 HOME 环境变量**(本ENGINEERING-NOTES.md
        // 早就写着这条,我还是踩了)。后果:闸删掉了 作者 **生产**的状态位,
        // 界面显示"关"、常驻那边的麦却没收到停的指令 → **作者 被卡在麦一直开着且关不掉的状态**。
        // → 状态位必须有独立的覆盖口,自检走它。
        if let d = ProcessInfo.processInfo.environment["TINGZHE_STATE_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d).appendingPathComponent("voice-on")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/tingzhe/voice-on")
    }
    static var isOn: Bool { FileManager.default.fileExists(atPath: flagURL.path) }

    /// ⭐ 单方面静音(作者 2026-07-28 咖啡馆)——「语音模式关掉」和「我这会儿不想让你听」是两件事:
    /// 关掉会断掉会话选择、也不再念给你听;静音只堵**我说话这个方向**,你照旧念给我听。
    /// ⛔ 状态位跟 voice-on 一样落文件,不放内存:进程重启后它还在,而且 `ls` 一眼能看出来。
    ///   这个项目上"只活在一个地方的状态"已经把 作者 卡住过一次(见 flagURL 头注)。
    static var mutedURL: URL {
        flagURL.deletingLastPathComponent().appendingPathComponent("voice-muted")
    }
    static var isMuted: Bool { FileManager.default.fileExists(atPath: mutedURL.path) }

    static func setMuted(_ m: Bool) {
        let f = mutedURL
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if m {
            FileManager.default.createFile(atPath: f.path, contents: Data())
            // ⛔ 必须真的把引擎丢掉,不是"收进来但不发" —— 系统那个橙点看的是设备句柄。
            //   判据不是省 CPU,是**你能不能相信麦真的没在听**。
            VoiceLoop.shared.stop()
            beep("Bottle")
        } else {
            try? FileManager.default.removeItem(at: f)
            if isOn { VoiceLoop.shared.start() }
            beep("Hero")
        }
        log("麦克风: \(m ? "静音（我还念给你听）" : "在听")")
        VoiceBadge.shared.refresh()
        StatusBar.shared.refresh()
    }
    static func toggleMute() { setMuted(!isMuted) }

    static func toggle() {
        setOn(!isOn)
    }

    static func setOn(_ on: Bool) {
        let f = flagURL
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if on {
            FileManager.default.createFile(atPath: f.path, contents: Data())
            // ⛔ 开语音模式 = 从"在听"开始。静音位若从上一场留下来,
            //   会变成「我明明打开了它却听不见我」—— 最难自己诊断的那种坏法。
            try? FileManager.default.removeItem(at: mutedURL)
            beep("Hero")
        } else {
            try? FileManager.default.removeItem(at: f)
            // ⛔ 关掉的同时必须掐掉正在念的 —— 否则"关上了却还在说话"
            for p in ["afplay", "say"] {
                let t = Process()
                t.launchPath = "/usr/bin/pkill"
                t.arguments = ["-x", p]
                try? t.run()
            }
            beep("Bottle")
        }
        log("语音模式: \(on ? "开" : "关")")
        if on { VoiceLoop.shared.start() } else { VoiceLoop.shared.stop() }
        VoiceBadge.shared.refresh()
        StatusBar.shared.refresh()
    }
}

/// 菜单栏 —— 作者 2026-07-28 要的「前端交互」:
/// 「能够决定我跟哪个 session 进行语音对话，并且能够关掉那些我不想继续语音对话的 session，
///   并且在第二次打开的时候不用再继续听它的语音」
///
/// ⛔ 关键的设计更正:上一版用「最后跟你说话的那个 session」自动判定 —— 那是**猜**。
/// 作者 要的是**他自己指定**。所以这里给一个菜单,点谁谁说话,别人一律闭嘴。
/// 「第二次打开不用再听它的」由此自然成立:没被选中的 session,它的钩子直接退出,什么都不排队。
final class StatusBar: NSObject, NSMenuDelegate {
    static let shared = StatusBar()
    private var item: NSStatusItem?

    static var partnerURL: URL { VoiceMode.flagURL.deletingLastPathComponent().appendingPathComponent("voice-partner") }
    static var sessionsDir: URL { VoiceMode.flagURL.deletingLastPathComponent().appendingPathComponent("sessions") }

    static var partner: String? {
        guard let d = try? String(contentsOf: partnerURL, encoding: .utf8) else { return nil }
        let t = d.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    static func setPartner(_ sid: String?) {
        if let sid = sid {
            try? FileManager.default.createDirectory(at: partnerURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? sid.write(to: partnerURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: partnerURL)
        }
    }

    /// ⛔⛔ 2026-07-28 作者:「你要拿 Claude Desktop 上面前端用户给他们命名的那个名字，
    ///    不能拿后端的名字或者 repo 的名字，那谁能分得出来？如果我有两个 session 都在同一个 repo 上，
    ///    那不就乱了」——**实证他是对的**:那份表里有一个仓底下挂着 4 个 session
    ///    (四个完全不同的活),
    ///    而我全都显示成那个仓名。
    /// ⭐ 真名在桌面端自己的库里:
    ///    `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json`
    ///    每个文件带 `cliSessionId`(= 钩子拿到的 session_id)和 **`title`**(用户看到的那个)。
    /// ⚠ 在**这里**解析而不是在钩子里写死:标题是对话开始一会儿才被命名的,
    ///    钩子那一刻常常还没有;每次开面板现查,才总是最新的。
    static var desktopTitles: [String: String] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        var m: [String: String] = [:]
        guard let e = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return m }
        for case let u as URL in e where u.pathExtension == "json" {
            guard let d = try? Data(contentsOf: u),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let sid = j["cliSessionId"] as? String,
                  let t = (j["title"] as? String), !t.isEmpty else { continue }
            m[sid] = t
        }
        return m
    }

    /// 优先用户自己看到的那个名字;还没被命名才退回仓名,再退回 id 前 8 位。
    /// ⛔ 提成纯函数是因为闸里那条断言原来是**空的**:沙箱里一个 session 都没有,
    ///   "0 个名字各不相同"永远成立。真要测的病是**同一个仓两个 session**,
    ///   而那种情况只能自己造出来喂进去。
    static func resolveLabel(id: String, repoLabel: String?, titles: [String: String]) -> String {
        if let t = titles[id], !t.isEmpty { return t }
        if let r = repoLabel, !r.isEmpty { return r }
        return String(id.prefix(8))
    }

    struct Sess { let id: String; let label: String; let seen: Double }
    static func sessions() -> [Sess] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir.path) else { return [] }
        let titles = desktopTitles
        var out: [Sess] = []
        for n in names {
            guard let d = try? Data(contentsOf: sessionsDir.appendingPathComponent(n)),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let id = j["id"] as? String else { continue }
            out.append(Sess(id: id,
                            label: resolveLabel(id: id, repoLabel: j["label"] as? String, titles: titles),
                            seen: (j["seen"] as? Double) ?? 0))
        }
        return out.sorted { $0.seen > $1.seen }
    }

    /// ⛔ 2026-07-28 实测:常驻由 launchd **直接 exec 裸二进制**(不走 LaunchServices),
    /// 该进程**拿不到菜单栏** —— `System Events` 查得逐字:tingzhe 的 menu bars = **1**,
    /// 而有状态项的 app(微信)是 **2**。而它自己的 `isVisible` **返回 true** ——
    /// **那个属性在这种情况下是撒谎的**,我上一轮据此打了个假绿灯。
    /// ⚠ 改走 `open -a` 启动能拿到菜单栏,但会破坏 TCC 的 responsible process 归属
    /// (install-agent.sh 里记着这条,当初就是因此退回来的)—— **不拿授权换一个图标**。
    /// ⇒ 换方法:可见指示改用**浮层**(NSPanel)。它在常驻里**已被证明能画**(转写后那个红点)。
    func install() {
        VoiceBadge.shared.refresh()
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let m = NSMenu(); m.delegate = self
        it.menu = m
        item = it
        it.button?.title = VoiceMode.isOn ? "🔴 听着" : "🎙 关"
        it.button?.alphaValue = 1.0
        // ⛔ 我看不到菜单栏 —— 不落日志的话,"图标在不在"只能靠 作者 一次次告诉我。
        // 2026-07-28 就是这么来回了三轮:我以为是透明度,其实它根本没建出来。
        log("菜单栏项: button=\(it.button != nil ? "有" : "无") · 标题=\(it.button?.title ?? "-") · 可见=\(it.isVisible)")
    }

    /// ⭐ 每次点开菜单才重建 —— session 名单随时在变,静态菜单会立刻过时
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let on = VoiceMode.isOn
        let head = NSMenuItem(title: on ? "语音对话：开着" : "语音对话：关着",
                              action: #selector(toggleMode), keyEquivalent: "")
        head.target = self
        menu.addItem(head)
        menu.addItem(.separator())

        let ss = StatusBar.sessions()
        if ss.isEmpty {
            let e = NSMenuItem(title: "（还没有 session 说过话）", action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        } else {
            menu.addItem(NSMenuItem(title: "跟哪个说话：", action: nil, keyEquivalent: ""))
            let cur = StatusBar.partner
            for s in ss.prefix(8) {
                let mi = NSMenuItem(title: "  \(s.label)  ·  \(s.id.prefix(8))",
                                    action: #selector(pickSession(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = s.id
                mi.state = (cur == s.id) ? .on : .off
                menu.addItem(mi)
            }
        }
        menu.addItem(.separator())
        let off = NSMenuItem(title: "全部闭嘴（谁都不念）", action: #selector(muteAll), keyEquivalent: "")
        off.target = self
        menu.addItem(off)
    }

    @objc private func toggleMode() { VoiceMode.toggle() }

    /// 选中某个 session = 只有它会说话。⛔ 同时**掐掉正在念的** ——
    /// 否则刚切过去就先听完上一个的尾巴,正是 作者 说的「一股脑倒给我」。
    @objc private func pickSession(_ sender: NSMenuItem) {
        guard let sid = sender.representedObject as? String else { return }
        Speaker.shutUp()
        StatusBar.setPartner(StatusBar.partner == sid ? nil : sid)
        if !VoiceMode.isOn { VoiceMode.setOn(true) }
        refresh()
    }

    @objc private func muteAll() {
        Speaker.shutUp()
        StatusBar.setPartner(nil)
        VoiceMode.setOn(false)
        refresh()
    }

    func refresh() {
        DispatchQueue.main.async { [weak self] in
            guard let b = self?.item?.button else { return }
            let on = VoiceMode.isOn && StatusBar.partner != nil
            // ⛔ 2026-07-28 作者 抓「麦克风图标不见了」——是我弄隐形的:
            // 关态我用了 🎤 + U+0338(组合斜杠),那个斜杠很多字体**渲染不出来**,
            // 再叠 35% 透明 = 等于隐形。**一个"关着"的开关看不见,人就找不到它了** ——
            // 而 作者 要的恰恰是「一个明显的开关」。
            // ⇒ 两态都用**独立的、必然渲染得出的**字符,而且都不透明。
            b.title = on ? "🔴 听着" : "🎙 关"
            b.alphaValue = 1.0
            b.toolTip = on ? "语音对话开着（点开可换 session 或全部闭嘴）"
                           : "语音对话关着（点开选一个 session）"
        }
    }
}

/// 语音模式的常驻可见指示 —— 菜单栏拿不到,改用浮层(已证明能画)。
/// 开着时屏幕右上角挂一个小条:看得见状态,点它就关。
final class VoiceBadge {
    static let shared = VoiceBadge()
    private var panel: NSPanel?

    func refresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if VoiceMode.isOn { self.showBadge(); self.paint() } else { self.panel?.orderOut(nil) }
        }
    }

    /// 徽章必须**看得出静音**。⛔ 状态只写进文件而界面不变 = 又一次「界面说 X、实际是 Y」,
    /// 这个项目上正是那种坏法把 作者 卡住过。
    private func paint() {
        guard let v = panel?.contentView else { return }
        let muted = VoiceMode.isMuted
        for sub in v.subviews where sub.identifier?.rawValue == "badgeLabel" {
            (sub as? NSTextField)?.stringValue = muted ? "🔇 静音" : "🔴 听着"
        }
        v.layer?.backgroundColor = (muted ? NSColor.systemGray : NSColor.systemRed)
            .withAlphaComponent(0.92).cgColor
    }

    private func showBadge() {
        let w: CGFloat = 96, h: CGFloat = 28
        let p = panel ?? {
            let np = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                             styleMask: [.nonactivatingPanel, .borderless],
                             backing: .buffered, defer: false)
            np.isFloatingPanel = true
            np.level = .statusBar
            np.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            np.hidesOnDeactivate = false
            np.isOpaque = false
            np.backgroundColor = .clear
            let bg = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            bg.wantsLayer = true
            bg.layer?.cornerRadius = h / 2
            bg.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.92).cgColor
            let t = NSTextField(labelWithString: "🔴 听着")
            t.identifier = NSUserInterfaceItemIdentifier("badgeLabel")
            t.frame = NSRect(x: 0, y: 5, width: w, height: 18)
            t.alignment = .center
            t.font = .systemFont(ofSize: 12, weight: .semibold)
            t.textColor = .white
            bg.addSubview(t)
            bg.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(self.clicked)))
            np.contentView = bg
            if let scr = NSScreen.main {
                let v = scr.visibleFrame
                np.setFrameOrigin(NSPoint(x: v.maxX - w - 16, y: v.maxY - h - 16))
            }
            self.panel = np
            return np
        }()
        p.orderFrontRegardless()
    }

    /// ⭐ 正在收你说话时把徽标变一下 —— 作者 才知道「它到底听没听到我」,
    /// 不用靠猜阈值。这是调灵敏度时最需要的即时反馈。
    /// ⛔⛔ 2026-07-28 作者:「我话没说完就从收音状态切回听着了」。
    /// 两档不够了 —— 自从话按「你真的停下来」才发出去(见 Composer),
    /// **一段音频结束 ≠ 这句话结束**,而徽章只有"在收/没收"两档,
    /// 于是每段之间都退回红色,看着就像"它不听我了"。⇒ 加第三档:
    ///   🎙 收到了(绿)= 正在收 · ⏳ 等你说完(橙)= 攥着你的话还没发 · 🔴 听着(红)= 空闲
    /// ⚠ 静音时不许被这个方法覆盖 —— 静音是更强的状态,画错了就又是「界面说 X 实际是 Y」。
    func setCapturing(_ on: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let v = self?.panel?.contentView else { return }
            if VoiceMode.isMuted { self?.paint(); return }
            let capturing = on || VoiceLoop.shared.isCapturing
            let (txt, color): (String, NSColor) =
                capturing ? ("🎙 收到了", .systemGreen)
                          : (Composer.isHolding
                                ? (Composer.isInstant ? ("⏳ 转写中", .systemOrange)
                                                      : ("⏳ 等你说完", .systemOrange))
                                : ("🔴 听着", .systemRed))
            for sub in v.subviews where sub.identifier?.rawValue == "badgeLabel" {
                (sub as? NSTextField)?.stringValue = txt
            }
            v.layer?.backgroundColor = color.withAlphaComponent(0.92).cgColor
        }
    }

    /// 点徽标 = 展开 session 选择器。⛔ 作者 2026-07-28 要的「前端交互」原本做在菜单栏里,
    /// 而这个进程**拿不到菜单栏**(已查实) —— 于是那个界面等于不存在,
    /// 连带把「必须先选 session 才出声」变成了一个**永远无法满足的条件**。
    /// ⇒ 选择器改做在浮层上(浮层已证明能画)。
    @objc private func clicked() { Picker.shared.toggle() }
}

/// 切发送方式。⛔ 面板上那两个按钮和快捷键走**同一个**函数 —— 复制两份就会漂移。
/// ⛔ 切走之前先把手上攒着的那半句发出去:否则它要么永远卡在缓冲里,
///    要么被后面的 discard 丢掉 —— 而你根本不知道自己刚说的话去哪了。
/// ⚠ 不传 to 就是**翻转**(快捷键用),传了就是指定(面板按钮用)。
func setSendMode(to: String? = nil) {
    Composer.flush()
    let v = to ?? (Composer.isInstant ? "batch" : "instant")
    let f = projectDir.appendingPathComponent("config.json")
    var j = (try? Data(contentsOf: f)).flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    } ?? [:]
    j["voice_send_mode"] = v
    if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: f)
    }
    log("发送方式 → \(v == "instant" ? "一句一条（说完一句立刻发）" : "攒成一条（等你真停下来）")")
    beep(v == "instant" ? "Tink" : "Pop")     // 快捷键切的时候看不见面板,得有个响
    VoiceBadge.shared.setCapturing(false)
}

/// session 选择器 —— 作者:「能决定我跟哪个 session 语音对话，能关掉我不想要的」
final class Picker {
    static let shared = Picker()
    private var panel: NSPanel?

    func toggle() {
        if panel?.isVisible == true { close() } else { open() }
    }
    func close() { panel?.orderOut(nil); panel = nil }

    func open() {
        let ss = StatusBar.sessions()
        let rowH: CGFloat = 30, w: CGFloat = 260
        let h = rowH * CGFloat(ss.count + 12) + 12
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true; p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false; p.isOpaque = false; p.backgroundColor = .clear
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.material = .hudWindow; bg.blendingMode = .behindWindow; bg.state = .active
        bg.wantsLayer = true; bg.layer?.cornerRadius = 12
        p.contentView = bg

        var y = h - rowH - 6
        // ⭐ 静音放在**最上面第一行** —— 咖啡馆里你要按的就是它,不该往下找。
        let mb = NSButton(title: VoiceMode.isMuted ? "🔇 静音中 · 点这里恢复听" : "🔇 单方面静音（我还念给你听）",
                          target: self, action: #selector(toggleMute))
        mb.frame = NSRect(x: 10, y: y, width: w - 20, height: 26)
        mb.isBordered = false; mb.alignment = .left
        mb.font = .systemFont(ofSize: 13, weight: .semibold)
        bg.addSubview(mb); y -= rowH

        let title = NSTextField(labelWithString: "跟哪个 session 说话")
        title.frame = NSRect(x: 14, y: y, width: w - 28, height: 20)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        bg.addSubview(title); y -= rowH

        let cur = StatusBar.partner ?? (try? String(contentsOf: VoiceMode.flagURL
                    .deletingLastPathComponent().appendingPathComponent("active-session"), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
        for sess in ss.prefix(6) {
            let b = NSButton(title: (cur == sess.id ? "● " : "○ ") + sess.label,
                             target: self, action: #selector(pick(_:)))
            b.frame = NSRect(x: 10, y: y, width: w - 20, height: 26)
            b.isBordered = false
            b.alignment = .left
            b.font = .systemFont(ofSize: 13)
            b.identifier = NSUserInterfaceItemIdentifier(sess.id)
            bg.addSubview(b); y -= rowH
        }
        // ── 收音灵敏度(作者 2026-07-28 要的第二个交互) ──────────────────
        let cur3 = VoiceLoop.shared.gateMult
        let sl = NSTextField(labelWithString: "收音灵敏度")
        sl.frame = NSRect(x: 14, y: y, width: w - 28, height: 20)
        sl.font = .systemFont(ofSize: 12, weight: .semibold)
        sl.textColor = .secondaryLabelColor
        bg.addSubview(sl); y -= rowH

        // ⭐ 三档而不是让 作者 填数字:数字他没法判断对不对,而"太钝/太灵"是他能直接感受的。
        //    倍数越小越灵敏(相对环境底噪)。
        // ⛔ 2026-07-28 咖啡馆实测:底噪 0.0007–0.0060 ⇒ `底噪×倍数` 永远小于 startRMS(0.02),
        //   门槛恒等于 0.02 —— **这三个按钮在嘈杂环境里一动没动过门槛**。
        //   真正卡着的是那个绝对下限,所以三档必须同时动它。倍数管安静环境,下限管嘈杂环境。
        //   ⚠ 数值含义 = 「多大的声音才算你在说话」。别人隔一两米说话大约 0.02–0.05,
        //     你对着电脑说话通常 0.1 以上(近讲比远讲响一个数量级)。
        let presets = VoiceLoop.presets
        var bx: CGFloat = 12
        for (name, v, lo) in presets {
            let on = abs(Double(cur3) - v) < 0.01
            let pb = NSButton(title: (on ? "● " : "○ ") + name, target: self, action: #selector(setSens(_:)))
            pb.toolTip = "门槛不低于 \(lo)（别人隔一两米说话约 0.02–0.05）"
            pb.frame = NSRect(x: bx, y: y, width: (w - 30) / 3, height: 26)
            pb.isBordered = false
            pb.font = .systemFont(ofSize: 12.5)
            pb.identifier = NSUserInterfaceItemIdentifier("\(v)/\(lo)")
            bg.addSubview(pb)
            bx += (w - 30) / 3 + 3
        }
        y -= rowH

        // ── 发送方式(作者 2026-07-28:「两种方式并行，要能来回切换」) ──────────
        let ml = NSTextField(labelWithString: "发送方式")
        ml.frame = NSRect(x: 14, y: y, width: w - 28, height: 20)
        ml.font = .systemFont(ofSize: 12, weight: .semibold)
        ml.textColor = .secondaryLabelColor
        bg.addSubview(ml); y -= rowH

        let inst = Composer.isInstant
        let modes: [(String, String)] = [("攒成一条", "batch"), ("一句一条", "instant")]
        var mx: CGFloat = 12
        for (name, v) in modes {
            let on = (v == "instant") == inst
            let mbn = NSButton(title: (on ? "● " : "○ ") + name, target: self, action: #selector(setMode(_:)))
            mbn.frame = NSRect(x: mx, y: y, width: (w - 30) / 2, height: 26)
            mbn.isBordered = false
            mbn.font = .systemFont(ofSize: 12.5)
            mbn.identifier = NSUserInterfaceItemIdentifier(v)
            bg.addSubview(mbn)
            mx += (w - 30) / 2 + 3
        }
        y -= rowH

        // ── 快捷键(作者 2026-07-28:「让我去 config 文件里改，这有点费劲的」) ──────
        // ⛔ 可配 ≠ 好改。上一版把它做成了 config.json 里的字符串 —— 对我方便,对人不方便,
        //   而这条需求的**理由本来就是"别人的设备我不确定"**:那些人更不会去翻 json。
        let hl = NSTextField(labelWithString: HotKey.capturing
            ? "快捷键 · 按任意键，或轻点 ⌘/⌃/⌥ · Esc 取消"
            : "快捷键（点一下改 · ⚠ = 有代价，鼠标停上去看；不拦你）")
        hl.frame = NSRect(x: 14, y: y, width: w - 28, height: 20)
        hl.font = .systemFont(ofSize: 12, weight: .semibold)
        hl.textColor = HotKey.capturing ? .systemOrange : .secondaryLabelColor
        bg.addSubview(hl); y -= rowH

        let curKeys = HotKey.current()
        for key in ["voice_toggle_key", "voice_mute_key", "voice_mode_key"] {
            let capturingThis = (Picker.capturingKey == key)
            let bound = curKeys[key] ?? ""
            // ⚠ 单键且会打出字 → 标出来。**允许你用,但让你看得见代价**
            let why = HotKey.warnReason(bound, forKey: key, others: curKeys)
            let warn = why == nil ? "" : " ⚠"
            let shown = capturingThis ? "按下任意键…" : HotKey.pretty(bound) + warn
            // 发送方式那行顺手告诉你现在在哪一档 —— 否则按下去才知道切到哪
            let nowAt = key == "voice_mode_key"
                ? (Composer.isInstant ? "（现在：一句一条）" : "（现在：攒成一条）") : ""
            let kb = NSButton(title: "\(HotKey.label(key))\(nowAt)    \(shown)",
                              target: self, action: #selector(grabKey(_:)))
            kb.frame = NSRect(x: 10, y: y, width: w - 20, height: 26)
            kb.isBordered = false
            kb.alignment = .left
            kb.font = NSFont.systemFont(ofSize: 12.5)
            if capturingThis { kb.contentTintColor = NSColor.systemOrange }
            kb.identifier = NSUserInterfaceItemIdentifier(key)
            kb.toolTip = why                       // ⚠ 只说代价，不挡路
            bg.addSubview(kb); y -= rowH
        }

        // 按住说话 —— 作者 找的就是这一条("要按下去我再说话的那个模式")
        let pttRaw = loadHotKeyRaw().lowercased()
        let pttIdx = pttChoices.firstIndex { $0.raw.lowercased() == pttRaw } ?? 0
        let pb2 = NSButton(title: "按住说话（点一下换）    \(pttChoices[pttIdx].label)",
                           target: self, action: #selector(cyclePTT))
        pb2.frame = NSRect(x: 10, y: y, width: w - 20, height: 26)
        pb2.isBordered = false; pb2.alignment = .left
        pb2.font = NSFont.systemFont(ofSize: 12.5)
        bg.addSubview(pb2); y -= rowH

        let off = NSButton(title: "✕ 关掉语音对话", target: self, action: #selector(turnOff))
        off.frame = NSRect(x: 10, y: 6, width: w - 20, height: 26)
        off.isBordered = false; off.alignment = .left
        off.font = .systemFont(ofSize: 13, weight: .semibold)
        bg.addSubview(off)

        if let scr = NSScreen.main {
            let v = scr.visibleFrame
            p.setFrameOrigin(NSPoint(x: v.maxX - w - 16, y: v.maxY - h - 50))
        }
        p.orderFrontRegardless()
        panel = p
    }

    @objc private func pick(_ sender: NSButton) {
        guard let sid = sender.identifier?.rawValue else { return }
        Speaker.shutUp()                    // 切过去先别听上一个的尾巴
        StatusBar.setPartner(sid)
        close()
    }
    /// 写回 config.json —— ⛔ 必须**保留其它字段**,不能整个覆盖
    /// (config 里还有 hotkey / hud 等,冲掉就等于把 作者 的设置抹了)。
    /// ⚠ VAD 门槛是**每次取用时现读** config 的,所以写完立刻生效,不用重启。
    @objc private func setSens(_ sender: NSButton) {
        let parts = (sender.identifier?.rawValue ?? "").split(separator: "/")
        guard parts.count == 2, let v = Double(parts[0]), let lo = Double(parts[1]) else { return }
        let f = projectDir.appendingPathComponent("config.json")
        var j = (try? Data(contentsOf: f)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        j["voice_gate_mult"] = v
        // ⛔ 只写倍数不写下限 = 这个按钮在嘈杂环境里等于没接线(当天实测)
        j["voice_start_rms"] = lo
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: f)
        }
        log("收音灵敏度 → 倍数 \(v) · 绝对下限 \(lo)（门槛取两者较大的那个）")
        close(); open()          // 重开面板,让选中标记跟上
    }

    /// 点一行 → 等你按下新组合键。⛔ 捕获期间已装的那几把一律不响应(HotKey.capturing),
    /// 否则你为了改静音键按下 ⌃⌥M,会**顺手把自己静音**,而面板同时又在等键 —— 两件事一起发生。
    static var capturingKey: String?
    private var grabMonitor: Any?
    private var grabAux: Any?

    @objc private func grabKey(_ sender: NSButton) {
        guard let cfgKey = sender.identifier?.rawValue else { return }
        endGrab()
        Picker.capturingKey = cfgKey
        HotKey.capturing = true
        close(); open()
        // ⛔ 修饰键不产生 keyDown —— 不加这个监听器,你按 ⌘/⌃/⌥ 时捕获器什么都收不到,
        //   表现就是"这几个键不让选"(作者 2026-07-28 原话)。
        var tapDown: UInt16?
        var tapDirty = false
        grabAux = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] ev in
            guard let self = self else { return }
            let anyMod = ev.modifierFlags.intersection([.command, .control, .option, .shift, .function])
            if !anyMod.isEmpty && tapDown == nil {
                tapDown = ev.keyCode; tapDirty = false; return
            }
            guard let dn = tapDown, anyMod.isEmpty else { return }
            tapDown = nil
            if tapDirty { return }                       // 中间按过别的键 = 在打组合键
            guard let name = HotKey.tapKeys.first(where: { $0.value.code == dn })?.key else { return }
            if let why = HotKey.rejectReason(name, forKey: cfgKey, others: HotKey.current()) {
                log("⚠ \(name) 装不上：\(why)"); beep("Basso"); return   // 只有"装不上"才不收
            }
            DispatchQueue.main.async {
                self.endGrab(); saveHotKey(cfgKey, name); beep("Hero"); self.close(); self.open()
            }
        }
        grabMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            tapDirty = true                              // 按了真键 → 这轮不是轻点
            guard let self = self else { return }
            let mods = ev.modifierFlags.intersection([.command, .control, .option, .shift])
            if ev.keyCode == UInt16(kVK_Escape) && mods.isEmpty {
                DispatchQueue.main.async { self.endGrab(); self.close(); self.open() }
                return
            }
            guard let raw = HotKey.describe(code: ev.keyCode, mods: mods) else { return }
            // 只按了修饰键本身(⌃/⌥ 单独按)不算 —— 那是你正要按组合键的中间态
            if HotKey.parse(raw) == nil { return }
            if let why = HotKey.rejectReason(raw, forKey: cfgKey, others: HotKey.current()) {
                log("⚠ \(raw) 装不上：\(why)"); beep("Basso"); return   // 只有"装不上"才继续等
            }
            DispatchQueue.main.async {
                self.endGrab()
                saveHotKey(cfgKey, raw)
                beep("Hero")
                self.close(); self.open()
            }
        }
    }

    private func endGrab() {
        if let m = grabMonitor { NSEvent.removeMonitor(m) }
        if let m = grabAux { NSEvent.removeMonitor(m) }
        grabMonitor = nil; grabAux = nil
        Picker.capturingKey = nil
        HotKey.capturing = false
    }

    /// 点一下换下一个。⛔ 用轮换而不是按键捕获:能长按的键就那几个,
    /// 让你按一下"右⌥"去捕获反而更难说清(它是修饰键,按下去先改的是 modifierFlags)。
    @objc private func cyclePTT() {
        let cur = loadHotKeyRaw().lowercased()
        let i = pttChoices.firstIndex { $0.raw.lowercased() == cur } ?? 0
        let next = pttChoices[(i + 1) % pttChoices.count]
        let f = projectDir.appendingPathComponent("config.json")
        var j = (try? Data(contentsOf: f)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        j["hotkey"] = next.raw
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: f)
        }
        log("按住说话 → \(next.label)")
        if next.needsAX && !AXIsProcessTrusted() {
            log("  ⚠ 这个选项要辅助功能权限，当前没有 → 会回落到 ⌃⌥Space")
        }
        // ⛔ 已注册的旧热键必须先撤 —— 不撤会两把键同时活着,而你看到的只有新的那把
        installHotKey()          // 它自己会先撤旧的（幂等）
        beep("Pop")
        close(); open()
    }

    @objc private func setMode(_ sender: NSButton) {
        guard let v = sender.identifier?.rawValue else { return }
        setSendMode(to: v)
        close(); open()          // 重开面板,让选中标记跟上
    }

    @objc private func toggleMute() {
        VoiceMode.toggleMute()
        close()
    }

    @objc private func turnOff() {
        close()
        VoiceMode.setOn(false)
    }
}

let hotKeyHandler: EventHandlerUPP = { _, event, _ -> OSStatus in
    guard let event = event else { return noErr }
    // ⚠ toggle 已改用 NSEvent 全局监听(见 installVoiceToggleHotKey),
    // 这里只剩录音热键一种,不必再分辨 id。
    switch GetEventKind(event) {
    case UInt32(kEventHotKeyPressed):  Controller.shared.startRecording()
    case UInt32(kEventHotKeyReleased): Controller.shared.stopAndTranscribe()
    default: break
    }
    return noErr
}

/// 语音模式开关键。⛔ 默认 ⌃⌥V,理由:
/// ① 不能用右⌥（那是按住说话）② 不能用双击右⌥（那是浮层否决，今天刚定）
/// ③ 不能用右⌘（ENGINEERING-NOTES.md 记着它是 ⌘C/⌘V/⌘Tab 的修饰键，会误触发）
/// ④ Carbon 组合键**不需要辅助功能权限**，权限掉了它照样能用
/// 语音模式开关键 —— ⛔ 2026-07-28 改用 **NSEvent 全局监听**,不再用 Carbon。
/// 根因:常驻由 launchd **直接 exec 裸二进制**(不走 LaunchServices),那个进程
/// **拿不到菜单栏**(实测 `menu bars = 1`,而有状态项的 app 是 2),
/// 而 Carbon 热键很可能是同一个根因 —— 作者 实测 ⌃⌥V 按了没反应。
/// ⭐ 判据不是"我觉得哪个好",是**已经被证明在这个进程里能用的机制**:
///    按住右⌥ 走的就是 NSEvent 全局监听,它一直是好的。
/// ⛔ 作者 2026-07-28:「快捷键全是你写死的话，改起来会非常非常不方便，
///    因为我不能确定别人用的是什么设备」——这是**开源前提**,不是锦上添花:
///    别人的键盘布局不同、已有的快捷键冲突不同,而原来 `voice_toggle_key`
///    只认 **4 个写死的字符串**,不在表里就是"不认识 → 键没装",没有出路。
/// ⇒ 通用解析:任意修饰键组合 + 任意主键。
///    `ctrl+opt+v` · `cmd+shift+m` · `⌃⌥space` · `f13` · `ctrl-opt-1` 都行,大小写随意。
enum HotKey {
    static let keys: [String: UInt16] = {
        var m: [String: UInt16] = [
            "space": UInt16(kVK_Space), "return": UInt16(kVK_Return), "enter": UInt16(kVK_Return),
            "tab": UInt16(kVK_Tab), "escape": UInt16(kVK_Escape), "esc": UInt16(kVK_Escape),
            "delete": UInt16(kVK_Delete), "grave": UInt16(kVK_ANSI_Grave), "`": UInt16(kVK_ANSI_Grave),
            "minus": UInt16(kVK_ANSI_Minus), "equal": UInt16(kVK_ANSI_Equal),
            "comma": UInt16(kVK_ANSI_Comma), "period": UInt16(kVK_ANSI_Period),
            "slash": UInt16(kVK_ANSI_Slash), "semicolon": UInt16(kVK_ANSI_Semicolon),
            "quote": UInt16(kVK_ANSI_Quote), "backslash": UInt16(kVK_ANSI_Backslash),
            "leftbracket": UInt16(kVK_ANSI_LeftBracket), "rightbracket": UInt16(kVK_ANSI_RightBracket),
            "home": UInt16(kVK_Home), "end": UInt16(kVK_End),
            "pageup": UInt16(kVK_PageUp), "pagedown": UInt16(kVK_PageDown),
            "left": UInt16(kVK_LeftArrow), "right": UInt16(kVK_RightArrow),
            "up": UInt16(kVK_UpArrow), "down": UInt16(kVK_DownArrow),
        ]
        for (n, c) in [("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D),
                       ("e", kVK_ANSI_E), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H),
                       ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
                       ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
                       ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
                       ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
                       ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z),
                       ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
                       ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7),
                       ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
                       ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4), ("f5", kVK_F5),
                       ("f6", kVK_F6), ("f7", kVK_F7), ("f8", kVK_F8), ("f9", kVK_F9), ("f10", kVK_F10),
                       ("f11", kVK_F11), ("f12", kVK_F12), ("f13", kVK_F13), ("f14", kVK_F14),
                       ("f15", kVK_F15), ("f16", kVK_F16), ("f17", kVK_F17), ("f18", kVK_F18),
                       ("f19", kVK_F19), ("f20", kVK_F20)] { m[n] = UInt16(c) }
        return m
    }()

    static func parse(_ raw: String) -> (code: UInt16, mods: NSEvent.ModifierFlags)? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        for (sym, name) in [("⌘", "cmd+"), ("⌃", "ctrl+"), ("⌥", "opt+"), ("⇧", "shift+")] {
            s = s.replacingOccurrences(of: sym, with: name)
        }
        s = s.replacingOccurrences(of: "-", with: "+")   // ⚠ 减号键写 "minus",别写 "-"
        var mods: NSEvent.ModifierFlags = []
        var keyName: String?
        for part in s.split(separator: "+").map(String.init) where !part.isEmpty {
            switch part {
            case "cmd", "command", "meta": mods.insert(.command)
            case "ctrl", "control":        mods.insert(.control)
            case "opt", "option", "alt":   mods.insert(.option)
            case "shift":                  mods.insert(.shift)
            default:
                if keyName != nil { return nil }        // 两个主键 = 写错了,别猜
                keyName = part
            }
        }
        guard let k = keyName, let code = keys[k] else { return nil }
        return (code, mods)
    }

    /// ⛔⛔ 2026-07-28 作者:「我不能选择 command control option 这几个键」。
    /// 根因:捕获器只监听 `.keyDown`,而**修饰键不产生 keyDown**(它们走 `flagsChanged`)——
    /// 于是你按 ⌘/⌃/⌥ 时捕获器**什么都没收到**,看起来就是"这几个键不让选"。
    /// ⇒ 修饰键单独当一把开关键用:**轻点一下**(按下再松开,中间没按别的键)。
    /// ⚠ 左侧那几个日常一直在用(⌘C/⌘V/⌘Tab),点一下也会触发 —— 面板上标 ⚠,但允许你选。
    static let tapKeys: [String: (code: UInt16, flag: NSEvent.ModifierFlags, pretty: String, risky: Bool)] = [
        "rightcmd":   (UInt16(kVK_RightCommand), .command, "右⌘", false),
        "rightctrl":  (UInt16(kVK_RightControl), .control, "右⌃", false),
        "rightopt":   (UInt16(kVK_RightOption),  .option,  "右⌥", false),
        "rightshift": (UInt16(kVK_RightShift),   .shift,   "右⇧", false),
        "cmd":        (UInt16(kVK_Command),      .command, "左⌘", true),
        "ctrl":       (UInt16(kVK_Control),      .control, "左⌃", true),
        "opt":        (UInt16(kVK_Option),       .option,  "左⌥", true),
        "shift":      (UInt16(kVK_Shift),        .shift,   "左⇧", true),
        "fn":         (UInt16(kVK_Function),     .function, "fn", false),
    ]
    /// 整串就是一个修饰键名 → 这是「轻点那个键」,不是组合键。
    static func parseTap(_ raw: String) -> (code: UInt16, flag: NSEvent.ModifierFlags, pretty: String, risky: Bool)? {
        var k = raw.lowercased().trimmingCharacters(in: .whitespaces)
        for (a, b) in [("rightcommand", "rightcmd"), ("rightoption", "rightopt"),
                       ("rightcontrol", "rightctrl"), ("command", "cmd"),
                       ("control", "ctrl"), ("option", "opt"), ("alt", "opt"),
                       ("⌘", "cmd"), ("⌃", "ctrl"), ("⌥", "opt"), ("⇧", "shift")] {
            if k == a { k = b }
        }
        return tapKeys[k]
    }

    /// 反向:按下来的那一下 → 规范写法。⚠ 一个键码可能有多个别名(return/enter),
    /// 这里钉死首选名,否则同一把键写回 config 会长出两种样子。
    static let preferred: [UInt16: String] = {
        var m: [UInt16: String] = [:]
        // 先塞全部,再用首选名覆盖 —— 覆盖顺序就是"谁是正名"的唯一声明处
        for (n, c) in keys where m[c] == nil { m[c] = n }
        for n in ["return", "escape", "grave", "space", "tab", "delete"] {
            if let c = keys[n] { m[c] = n }
        }
        return m
    }()

    static func describe(code: UInt16, mods: NSEvent.ModifierFlags) -> String? {
        guard let k = preferred[code] else { return nil }
        var out = ""
        if mods.contains(.control) { out += "ctrl+" }
        if mods.contains(.option)  { out += "opt+" }
        if mods.contains(.shift)   { out += "shift+" }
        if mods.contains(.command) { out += "cmd+" }
        return out + k
    }

    /// 正在等你按新键 —— 已装的那几把这期间一律不响应,
    /// 否则你为了改静音键而按下 ⌃⌥M,会**顺手把自己静音了**。
    static var capturing = false

    /// ⛔⛔ 2026-07-28 作者:「你不要给人家设这么多限制…他愿意误触是他的事情…
    ///    你这给人家当爹呢，爹味儿这么重的设计」。
    /// 上一版我拦了三类:撞车 / 右⌥ / 裸文字键。**那三类全都是"能装上、只是可能烦"**——
    /// 拦掉它们是我替用的人做了决定,而这个项目的用户里有一半我根本不认识(要开源)。
    /// ⇒ 现在**只拒装不上的**(解析不出来那一种),其余一律装上 + 在面板上标 ⚠ 说清代价。
    /// 判据:这把键**能不能工作** —— 不是"我觉得你会不会后悔"。
    static func rejectReason(_ raw: String, forKey: String, others: [String: String]) -> String? {
        (parse(raw) == nil && parseTap(raw) == nil) ? "认不出这个键" : nil
    }

    /// 会有什么代价 —— 只提醒,永不拦。nil = 没什么好说的。
    static func warnReason(_ raw: String, forKey: String = "", others: [String: String] = [:]) -> String? {
        var why: [String] = []
        for (name, other) in others where name != forKey {
            let same = (parseTap(raw) != nil && parseTap(other)?.code == parseTap(raw)?.code)
                || (parse(raw) != nil && parseTap(raw) == nil && parseTap(other) == nil
                    && parse(other)?.code == parse(raw)?.code && parse(other)?.mods == parse(raw)?.mods)
            if same { why.append("跟「\(label(name))」是同一把，两件事会一起发生") }
        }
        if let t = parseTap(raw) {
            if t.code == UInt16(kVK_RightOption) { why.append("右⌥ 同时是按住说话那把") }
            if t.risky { why.append("左侧修饰键日常一直在用（⌘C/⌘V/⌘Tab）") }
        } else if typesText(raw) {
            why.append("单键且会打出字，打字时会误触发")
        }
        return why.isEmpty ? nil : why.joined(separator: "；")
    }

    /// 给人看的写法:`ctrl+opt+v` → `⌃⌥V`;轻点型 → `轻点 左⌘`。
    static func pretty(_ raw: String) -> String {
        if let t = parseTap(raw) { return "轻点 " + t.pretty }
        guard let p = parse(raw), let k = preferred[p.code] else { return raw }
        var out = ""
        if p.mods.contains(.control) { out += "⌃" }
        if p.mods.contains(.option)  { out += "⌥" }
        if p.mods.contains(.shift)   { out += "⇧" }
        if p.mods.contains(.command) { out += "⌘" }
        return out + (k.count == 1 ? k.uppercased() : k)
    }

    static func label(_ cfgKey: String) -> String {
        switch cfgKey {
        case "voice_toggle_key": return "语音对话 开/关"
        case "voice_mute_key":   return "麦克风 静音/恢复"
        // ⛔ 原来叫「切发送方式」—— 作者 找了一圈没找到"一条一条发信息的那个模式",
        //   因为这个名字没说出它切的是什么。**名字里必须出现你会用来找它的那个词。**
        case "voice_mode_key":   return "攒成一条 ⇄ 一句一条"
        default: return cfgKey
        }
    }
    static let defaults: [String: String] = [
        "voice_toggle_key": "ctrl+opt+v",
        "voice_mute_key": "ctrl+opt+m",
        "voice_mode_key": "ctrl+opt+b",
    ]
    static func current() -> [String: String] {
        var m: [String: String] = [:]
        let c = hudConfig()
        for (k, d) in defaults { m[k] = (c[k] as? String) ?? d }
        return m
    }

    /// 这一下会不会打出字来。⛔ 这是**单键能不能用**的真判据 ——
    /// 不是"有没有修饰键"。F 键、方向键、Esc、Home/End、翻页键单独按都不产生文字,
    /// 拿它们当单键开关完全没问题。
    /// ⚠ 上一版我把"必须带修饰键"做成了**拒装**,作者 2026-07-28 直接问
    ///   「我一定要是两个键的组合吗？」—— 那条限制是我加的,不是系统的。
    ///   现在改成:**允许,但会告诉你代价**。要不要承担是用的人决定,不是我决定。
    static func typesText(_ raw: String) -> Bool {
        if parseTap(raw) != nil { return false }          // 修饰键本身不打出字
        guard let (code, mods) = parse(raw) else { return false }
        if !mods.isEmpty { return false }         // 带修饰键就不会顺手打出来
        guard let k = preferred[code] else { return false }
        let harmless: Set<String> = ["escape", "home", "end", "pageup", "pagedown",
                                     "left", "right", "up", "down", "delete"]
        if harmless.contains(k) { return false }
        if k.hasPrefix("f"), Int(k.dropFirst()) != nil { return false }   // f1-f20
        return true                                // 字母/数字/标点/space/return/tab
    }

    /// 能用但要提醒的 —— 返回 nil = 没什么好说的。
    static func warnReason(_ raw: String) -> String? {
        if let t = parseTap(raw) {
            return t.risky ? "左侧修饰键日常一直在用（⌘C/⌘V/⌘Tab），会误触发" : nil
        }
        return typesText(raw) ? "单键且会打出字，你打字时会误触发" : nil
    }

    /// 只剩"解析得了"这一条硬要求。裸键不再拦。
    static func isSafe(_ raw: String) -> Bool { parse(raw) != nil || parseTap(raw) != nil }
}

var hotKeyMonitors: [Any] = []

/// 装一把全局开关键。三把(语音模式/静音/发送方式)走**同一条**路 ——
/// ⛔ 复制三份 = 以后修一处漏两处,而漏掉的那两处正好是最少用到、最晚被发现的。
func installToggleKey(_ cfgKey: String, default def: String, label: String,
                      action: @escaping () -> Void) {
    let raw = ((hudConfig()[cfgKey] as? String) ?? def).trimmingCharacters(in: .whitespaces)
    if raw.isEmpty || raw.lowercased() == "none" {
        log("\(label): 未绑定（config.json 里 \(cfgKey) 设成 none 就是这个意思）")
        return
    }
    // ⛔ 轻点修饰键这条路必须单独装 —— 修饰键**不产生 keyDown**,
    //   走 .keyDown 的监听器对它是全聋的(这正是 作者「不能选 command control option」的根因)。
    if let t = HotKey.parseTap(raw) {
        guard AXIsProcessTrusted() else {
            log("⚠ \(label) 需要辅助功能权限,当前没有 → 授权后重启即可用"); return
        }
        var down = false
        var otherKeyDuring = false
        var downAt = Date()
        // 别的键按下 → 这次修饰键是在**当组合键的修饰键**用,不算轻点
        if let k = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ in
            if down { otherKeyDuring = true }
        }) { hotKeyMonitors.append(k) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { ev in
            guard !HotKey.capturing else { return }
            let pressed = ev.modifierFlags.contains(t.flag) && ev.keyCode == t.code
            if pressed && !down {
                down = true; otherKeyDuring = false; downAt = Date()
            } else if !ev.modifierFlags.contains(t.flag) && down {
                down = false
                // 轻点 = 按下到松开很短,且中间没按别的键。长按/当修饰键用都不算。
                if !otherKeyDuring, Date().timeIntervalSince(downAt) < 0.4 {
                    DispatchQueue.main.async { action() }
                }
            }
        }) { hotKeyMonitors.append(m) }
        if let w = HotKey.warnReason(raw, forKey: cfgKey, others: HotKey.current()) {
            log("⚠ \(label) = \(HotKey.pretty(raw))：\(w)。（你选的就是它，这只是提醒）")
        }
        log("\(label): \(HotKey.pretty(raw))（按一下就松开，别按住）")
        return
    }
    guard let (code, mods) = HotKey.parse(raw) else {
        log("⚠ \(cfgKey)=\(raw) 解析不了 → \(label) 没装。写法：ctrl+opt+v / f13 / 或单独一个 cmd/ctrl/opt（轻点）")
        return
    }
    if let w = HotKey.warnReason(raw, forKey: cfgKey, others: HotKey.current()) {
        log("⚠ \(label) = \(HotKey.pretty(raw))：\(w)。（你选的就是它，这只是提醒）")
    }
    guard AXIsProcessTrusted() else {
        log("⚠ \(label) 需要辅助功能权限,当前没有 → 授权后重启即可用")
        return
    }
    if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { ev in
        guard !HotKey.capturing, ev.keyCode == code else { return }
        // ⛔ 必须**精确相等**。原来写的是 `f.contains(mods), !f.contains(.command)` ——
        //   contains 意味着 ctrl+opt+**shift**+v 也会触发它,而那很可能是别的 app 的快捷键;
        //   手工排除的只有 command 一个,shift 从来没被挡住过。
        let f = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard f == mods else { return }
        DispatchQueue.main.async { action() }
    }) {
        hotKeyMonitors.append(m)
    }
    log("\(label): \(raw)")
}

func installVoiceToggleHotKey() {
    // 改键之后要能**立刻**生效 —— 让你为了换一把快捷键去重启常驻,
    // 跟"去 config 文件里改"是同一种费劲。
    for m in hotKeyMonitors { NSEvent.removeMonitor(m) }
    hotKeyMonitors.removeAll()
    installToggleKey("voice_toggle_key", default: "ctrl+opt+v",
                     label: "语音模式开关（按一下开，再按一下关）") { VoiceMode.toggle() }
    installToggleKey("voice_mute_key", default: "ctrl+opt+m",
                     label: "单方面静音（我还念给你听）") { VoiceMode.toggleMute() }
    installToggleKey("voice_mode_key", default: "ctrl+opt+b",
                     label: "切发送方式（攒成一条 ⇄ 一句一条）") { setSendMode() }
}

/// 把一把快捷键写回 config 并**立刻重装**。⛔ 只写文件不重装 = 面板显示新的、按下去还是旧的。
func saveHotKey(_ cfgKey: String, _ raw: String) {
    let f = projectDir.appendingPathComponent("config.json")
    var j = (try? Data(contentsOf: f)).flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    } ?? [:]
    j[cfgKey] = raw
    if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: f)
    }
    log("\(HotKey.label(cfgKey)) → \(raw)")
    installVoiceToggleHotKey()
}


func installCarbon(_ name: String, _ keyCode: UInt32, _ mods: UInt32) {
    var spec = [
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 2, &spec, nil, nil)
    let id = EventHotKeyID(signature: OSType(0x4D53_5054), id: 1)  // 'MSPT' · 录音热键(Carbon 回落路径专用)
    if RegisterEventHotKey(keyCode, mods, id, GetApplicationEventTarget(), 0, &hotKeyRef) != noErr {
        log("✗ 热键 \(name) 注册失败 —— 可能已被别的程序占用")
        exit(1)
    }
    log("热键: 按住 \(name)")
}

func installSingleModifier(_ name: String, _ keyCode: UInt16, _ flag: NSEvent.ModifierFlags) {
    var isDown = false
    var downAt: Date?
    var lastTapEnd: Date?
    flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { ev in
        guard ev.keyCode == keyCode else { return }
        let nowDown = ev.modifierFlags.contains(flag)
        guard nowDown != isDown else { return }   // 去重:同一物理键会连发
        isDown = nowDown
        if nowDown { downAt = Date(); Controller.shared.startRecording(); return }

        let held = downAt.map { Date().timeIntervalSince($0) } ?? 1
        Controller.shared.stopAndTranscribe()     // 短按会被它按 dur>0.4 的 guard 丢掉
        // ⛔ 方案丙的否决键 = **双击既有热键**,不新注册全局快捷键
        // (多一个要记的键、可能撞、且会永久占用一个组合)。
        // 判据:两次按压**都不足 0.4s**(真要说话的按压必 ≥0.4s,这是既有的丢弃阈值)
        //      且两次结束点相隔 <0.5s。用既有阈值当护栏,不是新拍一个数。
        guard held < 0.4 else { lastTapEnd = nil; return }
        if let t = lastTapEnd, Date().timeIntervalSince(t) < 0.5, HUD.shared.isLive {
            lastTapEnd = nil
            DispatchQueue.main.async { HUD.shared.veto() }
        } else {
            lastTapEnd = Date()
        }
    }
    log("热键: 按住 \(name)（单键）")
}

/// 撤掉当前这把「按住说话」。⛔ 换键前必须先撤:
/// Carbon 那把不撤会一直活着,单键那个 monitor 不撤会叠加 ——
/// 结果是你以为换了键,其实是**两把键都能录音**,而只有一把在界面上。
func unregisterHotKey() {
    if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
    if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
}

func installHotKey() {
    unregisterHotKey()          // 幂等:重复装不会留下上一把
    let style = hotKeyStyle(from: loadHotKeyRaw())
    switch style {
    case .carbonCombo(let n, let k, let m):
        installCarbon(n, k, m)
    case .singleModifier(let n, let k, let f):
        if AXIsProcessTrusted() {
            installSingleModifier(n, k, f)
        } else {
            log("⚠ 单键热键 \(n) 需要辅助功能权限,当前没有 → 回落到 ⌃⌥Space")
            log("  授权后重启即可用单键: 系统设置 → 隐私与安全性 → 辅助功能 → 加入 tingzhe.app")
            installCarbon("⌃⌥Space", UInt32(kVK_Space), UInt32(controlKey | optionKey))
        }
    }
}

// MARK: - 方案 A · 纠错回流（作者 2026-07-26 拍 Q3丙）
//
// 要解决的洞:唯一知道"模型说错了"的人是 作者,而他**在字被粘贴出来那一刻就知道**。
// 现在这个信息当场丢掉 —— 2026-07-26 实测:真实使用 10 次、251 字,词表命中 **0/10**,
// 25 条规则覆盖的词一次都没说过,而说过的词一条规则也没有。**词表进不来新词,是本项目最大的洞。**

/// JSON 字符串转义。手写是为了**保留原样的中文**(`JSONSerialization` 的 pretty 输出会把
/// 非 ASCII 转成 \uXXXX,dict.json 就没法人眼读、也没法看 diff 了)。
func jsonStr(_ s: String) -> String {
    var o = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"":  o += "\\\""
        case "\\":  o += "\\\\"
        case "\n":  o += "\\n"
        case "\t":  o += "\\t"
        case "\r":  o += "\\r"
        default:
            if c.value < 0x20 { o += String(format: "\\u%04x", c.value) } else { o.unicodeScalars.append(c) }
        }
    }
    return o + "\""
}

/// 把一条纠错写进 dict.json。
/// ⛔ **值钱的地方是插对位置**:dict.json 顺序有意义 —— 若模式 A 是模式 B 的子串,A 必须排在 B **之后**,
/// 否则 A 先咬掉一段、B 永不命中。手工维护最容易在这里错,且症状隐蔽
/// (ENGINEERING-NOTES.md 已把它列为禁区)。check.sh 第 3 项守同一条不变式。
func addFix(_ wrong: String, _ right: String) -> Bool {
    let f = projectDir.appendingPathComponent("dict.json")
    guard let d = try? Data(contentsOf: f),
          var arr = try? JSONSerialization.jsonObject(with: d) as? [[String]] else {
        print("✗ 读不了 dict.json（\(f.path)）"); return false
    }
    // —— 校验(与 check.sh 第 3 项同口径,早失败早报错)
    if wrong.isEmpty || right.isEmpty { print("✗ 两侧都不能为空"); return false }
    if wrong == right { print("✗ 自替换无意义"); return false }
    if right.contains(wrong) {
        print("✗ 「正确的」含「错的」(\(right) ⊃ \(wrong)) → 替换结果里还带着模式,会反复放大。拒绝。")
        return false
    }
    // ⛔ F11:畸形条目(非二元组)会让下面的 $0[1] 越界 → SIGTRAP(exit 133),stdout/stderr 全空
    if let bad = arr.firstIndex(where: { $0.count != 2 }) {
        print("✗ dict.json 第 \(bad) 条不是 [错,对] 二元组:\(arr[bad])。先修好它再加词。")
        return false
    }
    let srcs = arr.map { $0[0] }, dsts = arr.map { $0[1] }
    if let k = srcs.firstIndex(of: wrong) {
        print("✗ 已有这条:第 \(k) 条 \(wrong) → \(arr[k][1])"); return false
    }
    // ⛔ F6(独立复核实测):新规则若能命中**旧规则的产物**,旧规则此后永不可能产出正确结果。
    // 实测:`--fix 项目 项旗` 之后「甲项目演练」→「青梧项旗演练」,而 check.sh 第 3 项
    // 只比 wrong↔wrong、第 4 项只断言「青梧」在结果里 → **两闸全绿**。
    // 这是「A 咬掉 B」那条不变式的另一半,原来完全没看。
    if let k = dsts.firstIndex(where: { $0.contains(wrong) }) {
        print("✗ 新模式「\(wrong)」出现在第 \(k) 条的**结果**里(\(srcs[k]) → \(dsts[k]))")
        print("  加了它以后第 \(k) 条永远产不出正确结果 —— 那正是顺序不变式要防的终局。拒绝。")
        return false
    }
    // ⛔ F10:原来只对「≤2 汉字」告警。1 字规则、纯空白、纯标点同样是全文级爆炸半径,
    // 而 check.sh 第 3 项的风险名单也只看汉字、第 4 项的 norm() 把空白标点全 strip 掉 → 天然瞎。
    let onlyPunctOrSpace = wrong.allSatisfy { $0.isWhitespace || $0.isPunctuation || $0.isSymbol }
    if onlyPunctOrSpace || wrong.count == 1 {
        print("✗ 「\(wrong)」是 \(onlyPunctOrSpace ? "纯空白/标点" : "单字符") 模式 —— 爆炸半径是全文。")
        print("  实测 `--fix \" \" \"-\"` 会把每个空格换成横线,而两道闸都看不见。拒绝。")
        return false
    }
    // —— 定位:排在「所有把它当子串的模式」之后、「所有它包含的模式」之前
    var lower = 0, upper = arr.count
    for (k, s) in srcs.enumerated() where s != wrong {
        if s.contains(wrong) { lower = max(lower, k + 1) }   // 我是别人的子串 → 我排后面
        if wrong.contains(s) { upper = min(upper, k) }       // 别人是我的子串 → 我排前面
    }
    if lower > upper {
        print("✗ 顺序无解:既要排在第 \(lower) 条之后、又要排在第 \(upper) 条之前。手工看一眼 dict.json。")
        return false
    }
    // 插在合法区间的**末端**:两端都满足不变式,但取末端让「与谁都无关的新规则」落在文件尾部,
    // diff 好读、文件大致按加入时间排;取首端会让每条新规则都插到最前面。
    let at = upper
    arr.insert([wrong, right], at: at)
    let text = "[\n" + arr.map { "  [\(jsonStr($0[0])), \(jsonStr($0[1]))]" }.joined(separator: ",\n") + "\n]\n"
    // 写前自校验:重新解析一遍并比对,别把配置文件写坏了才发现
    guard let back = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String]], back == arr else {
        print("✗ 生成的 JSON 自校验不过,已放弃写入（原文件未动）"); return false
    }
    do { try text.write(to: f, atomically: true, encoding: .utf8) }
    catch { print("✗ 写入失败: \(error)"); return false }

    print("✓ 已插入第 \(at) 条:\(wrong) → \(right)（共 \(arr.count) 条）")
    if at != arr.count - 1 {
        print("  ↳ 没排在末尾是因为顺序不变式:它必须排在第 \(at + 1) 条 \(arr[at + 1][0]) 之前"
            + "（短模式若在前会先咬掉一段,长模式就永不命中）")
    }
    if wrong.count <= 2 && wrong.allSatisfy(isHan) {
        print("⚠ 这是 ≤2 汉字的规则,会**无条件全文替换** —— 你真说到含它的别的词会被静默改掉。")
        print("  已知实例:规则「星规→星轨」会把「克星规」改成「克星轨」。")
    }
    print("→ 跑 ./check.sh 确认全绿。常驻进程会自己热重载,**不用重启**。")
    return true
}

/// 从转写日志挖「可能该进词表」的候选词。这是方案 A 的另一半 —— `--fix` 只给了入口,
/// 没给"该加什么词"。
/// ⛔ **隐私边界**:transcripts.jsonl 是明文语音记录。
/// ⚠ 2026-07-26 独立复核推翻了本处原来那句「绝不输出整句原文」—— **它当时是假的**:
/// 4 字窗口首尾重叠 3 字,说两遍的整句可逐字重建;ASCII 分词不含 `.`/`_`,密钥被原样打印。
/// 现在装了三道闸(见函数体 looksSecret / 断链 / 字典序+上限)。
/// **仍然只是缓解,不是证明** —— 语料一大总有残余可推断性,别把它当保证。
func printCandidates(minCount: Int = 2) -> Bool {
    let p = logDirURL.appendingPathComponent("transcripts.jsonl")
    guard let text = try? String(contentsOf: p, encoding: .utf8) else {
        print("✗ 读不到转写日志（\(p.path)）。还没用过?"); return false
    }
    var raws: [String] = []
    for line in text.split(separator: "\n") where !line.isEmpty {
        if let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
           let r = d["raw"] as? String, !r.isEmpty { raws.append(r) }
    }
    let covered = Set(loadDict().flatMap { [$0.0, $0.1] } + loadCanon().map { $0.term })
    var count: [String: Int] = [:]
    for r in raws {
        // 英文/技术词
        for m in r.split(whereSeparator: { !($0.isLetter && $0.isASCII) && !$0.isNumber && $0 != "." && $0 != "_" })
        where m.count >= 3 && m.first!.isASCII && m.first!.isLetter {
            count[String(m), default: 0] += 1
        }
        // 汉字 2-4 连续串
        let chars = Array(r)
        for w in 2...4 where chars.count >= w {
            for i in 0...(chars.count - w) {
                let s = chars[i..<(i + w)]
                if s.allSatisfy(isHan) { count[String(s), default: 0] += 1 }
            }
        }
    }
    // ⛔ F5(独立复核实测 · 最严重的一条):原来 2-4 字汉字窗口**首尾重叠 3 字**,
    // 说过两遍的整句可从输出**逐字重建** —— 实测重建出「跟某某谈的那个方案报价压到若干万」;
    // 而且 ASCII 分词器的分隔符集不含 `.`/`_`,说过两遍的密钥被**原样打印**
    // (实测 `sk_live_FAKE1234567890abcdef`)。
    // ⛔ 而我在本函数注释里逐字写着「绝不输出整句原文」—— **那句是假的**。
    //    假的安全承诺比没有承诺更坏。三道闸:
    //    ① 疑似密钥/邮箱/长随机串一律不出
    //    ② 同一簇里能首尾重叠拼接的候选只留一个代表 → 断掉重建链
    //    ③ 按字典序输出(不按频次)+ 硬上限,避免"按顺序读下来就是原句"
    func looksSecret(_ s: String) -> Bool {
        if s.contains("@") { return true }
        let lower = s.lowercased()
        for k in ["sk_", "sk-", "token", "secret", "apikey", "api_key", "passwd", "password", "bearer"]
        where lower.contains(k) { return true }
        let hasDigit = s.contains { $0.isNumber }
        return s.count >= 16 && hasDigit          // 长且含数字 = 随机串形态
    }
    let hits = count.filter { $0.value >= minCount && !covered.contains($0.key) }
        // 短串若被一个同频的更长串包含,只留长的(减噪)
        .filter { kv in !count.contains { $0.key != kv.key && $0.key.contains(kv.key) && $0.value >= kv.value } }
        .filter { !looksSecret($0.key) }                        // 闸①
    // 闸②:断重建链 —— 若两个候选能首尾重叠(a 的后 n-1 字 == b 的前 n-1 字),只留一个
    var kept: [String: Int] = [:]
    for (k, v) in hits.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
        let chainable = kept.keys.contains { o in
            guard o.count == k.count, o.count >= 2 else { return false }
            return String(o.dropFirst()) == String(k.dropLast()) || String(k.dropFirst()) == String(o.dropLast())
        }
        if !chainable { kept[k] = v }
    }
    let shown = kept.sorted { $0.key < $1.key }                 // 闸③:字典序,不按频次

    let chars = raws.reduce(0) { $0 + $1.count }
    print("语料:\(raws.count) 条转写 / \(chars) 字 · 已覆盖词 \(covered.count) 个 · 阈值 ≥\(minCount) 次")
    if shown.isEmpty {
        print("—— 没有出现 ≥\(minCount) 次的未覆盖候选。")
        print("   这在语料还小的时候是正常的（本命令要等你用出量才有产出）,不是故障。")
        return true
    }
    print("候选（字典序 · 出现次数）—— 眼过一遍,该收的用 `--fix 错 对` 收:")
    for (k, v) in shown.prefix(20) { print("  \(v)×  \(k)") }
    if shown.count > 20 { print("  …还有 \(shown.count - 20) 个未显示（上限 20:防止顺着读下来就是原句）") }
    let dropped = hits.count - shown.count
    if dropped > 0 { print("  （已隐去 \(dropped) 个:疑似密钥/可拼接成原句的重叠片段）") }
    return true
}

// MARK: - 子命令（⚠ 必须在单实例锁之前 —— 常驻进程握着锁,否则这些命令一律被拒）

if let i = CommandLine.arguments.firstIndex(of: "--fix") {
    // ⛔ F7(2026-07-26 独立复核实测):原来取完 [i+1]/[i+2] 就不管了 ——
    // `--fix 推 min 推 main`(忘加引号)会静默丢掉后两个参数,插入 `推 → min`,
    // 于是此后**每个「推」都变 min**;而 --fix 写完立即热重载,闸是事后才跑的。
    if CommandLine.arguments.count > i + 3 {
        print("✗ 参数太多。含空格的词必须加引号：tingzhe --fix \"推 min\" \"推 main\"")
        print("  你给的是：\(CommandLine.arguments[(i+1)...].map { "\"\($0)\"" }.joined(separator: " "))")
        exit(2)
    }
    guard i + 2 < CommandLine.arguments.count else {
        print("用法: tingzhe --fix <模型听错的> <正确的>")
        print("例:   tingzhe --fix 星盾 星轨")
        exit(2)
    }
    exit(addFix(CommandLine.arguments[i + 1], CommandLine.arguments[i + 2]) ? 0 : 1)
}

if CommandLine.arguments.contains("--candidates") {
    exit(printCandidates() ? 0 : 1)
}

/// 对任意文本跑完整修正管线（字面层 + 拼音层）。
/// ⭐ 存在的理由不只是手动试:check.sh 的词表回归**原本在 Python 里重写了一遍 applyDict**,
/// 那是个静默分叉源(Python 版对拼音层一无所知)。改由闸调用本命令 → 闸测的是真实代码路径。
if let i = CommandLine.arguments.firstIndex(of: "--apply") {
    guard i + 1 < CommandLine.arguments.count else { print("用法: tingzhe --apply \"<文本>\""); exit(2) }
    let r = correct(CommandLine.arguments[i + 1], loadDict(), loadCanon(), loadProtected())
    print(r.text)
    exit(0)
}

// MARK: - 启动

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不进 Dock,不抢焦点

AVCaptureDevice.requestAccess(for: .audio) { granted in
    if !granted {
        log("✗ 麦克风权限被拒 —— 系统设置 → 隐私与安全性 → 麦克风")
        exit(1)
    }
}

// MARK: - 自检模式（判卷闸用 · 无这两个模式,#1 那种 bug 能全绿通过所有闸）

if CommandLine.arguments.contains("--selftest-record") {
    // 专治 2026-07-25 的 #1:断言录音时长真的读得出来。
    // 原 bug 是 stop() 之后读 currentTime 恒为 0,而任何"启动到就绪"的冒烟都发现不了。
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("selftest.m4a")
    let s: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: kSampleRate,
                            AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
    guard let r = try? AVAudioRecorder(url: url, settings: s), r.record() else {
        log("✗ selftest-record: 录音器起不来"); exit(1)
    }
    Thread.sleep(forTimeInterval: 1.0)
    let dur = r.currentTime           // 必须在 stop() 之前
    r.stop()
    try? FileManager.default.removeItem(at: url)
    if dur > 0.4 {
        log("✓ selftest-record: 录得时长 \(String(format: "%.2f", dur))s,过 guard"); exit(0)
    } else {
        log("✗ selftest-record: 时长读出 \(dur) —— 录音必被当「太短」丢弃,主路径不通"); exit(1)
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--selftest-transcribe"),
   i + 1 < CommandLine.arguments.count {
    // 端到端:真调 API + 过词表。会消耗积分,故只在 TINGZHE_CHECK_E2E=1 时由闸调用。
    let f = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    guard let key = loadAPIKey() else { log("✗ 无 API key"); exit(1) }
    guard let raw = transcribe(f, key: key) else { log("✗ 转写失败"); exit(1) }
    // ⛔ 必须走 `correct()`（字面层 + 拼音层），不是只调 applyDict ——
    // 2026-07-26 抓到:原来只调 applyDict 且分层计数恒为 0。canon 空表时结果等价,
    // 一旦启用拼音层就会**静默分叉**：主路径修了、自检路径没修，而自检正是用来断言主路径的。
    let rr = loadDict(), cc = loadCanon()
    let (fixed, dn, cn) = correct(raw, rr, cc, loadProtected())
    let flat = rr.map { $0.0 + "\u{1}" + $0.1 }.joined(separator: "\u{2}")
    appendJSONL(dur: 0, ms: 0, raw: raw, fixed: fixed, fixes: dn + cn,
                dictHash: "selftest-v\(rr.count)+c\(cc.count)-\(flat.count)",
                fixDict: dn, fixCanon: cn, file: "transcripts-selftest.jsonl")
    log("✓ selftest-transcribe: 修正 \(dn + cn) 处（字面 \(dn) / 拼音 \(cn)）")
    print(fixed)
    exit(0)
}

if CommandLine.arguments.contains("--selftest-reload") {
    // 判据 N4:改了词表,不重启进程也能生效。
    // ⚠ 本项验的是**热重载机制**(mtime 比对 + 重新载表),
    //   **不是**"按下热键会触发它"那一步 —— 那一步是 startRecording() 里的一行调用,
    //   要端到端验证需要真按一次键。别把本项当成端到端已验。
    let c = Controller.shared
    let f = projectDir.appendingPathComponent("dict.json")
    guard let orig = try? Data(contentsOf: f) else { print("✗ 读不到 dict.json"); exit(1) }
    // ⛔ 不能用 defer 还原 —— exit() 不做栈展开,defer 根本不会跑,临时规则会残留在 dict.json 里。
    func bail(_ msg: String) -> Never {
        try? orig.write(to: f)
        print(msg)
        exit(1)
    }
    let h0 = c.rulesHash
    if c.reloadTablesIfChanged() { bail("✗ 未改动却报「有变更」—— mtime 比对逻辑不对") }
    guard addFix("自检临时错例", "自检临时正例") else { bail("✗ --fix 写入失败") }
    guard c.reloadTablesIfChanged() else {
        bail("✗ 词表已改而热重载没触发 —— 加词必须重启进程,方案 A 会因此没人用")
    }
    let h1 = c.rulesHash
    if h0 == h1 { bail("✗ 重载了但指纹没变(\(h0)) —— 表其实没换") }
    try? orig.write(to: f)
    print("✓ selftest-reload: 指纹 \(h0) → \(h1),改表无需重启")
    print("  ⚠ 本项只验机制;「按下热键会调用它」那一步需真按一次键才算端到端验过。")
    exit(0)
}

if CommandLine.arguments.contains("--selftest-mainpath") {
    // ⛔ 这一项才是踩过的坑 #1 的真正断言:它驱动**生产那份** startRecording/stopAndTranscribe,
    // 不是副本。若有人再把 `r.currentTime` 挪到 `stop()` 之后,这里必红。
    guard kSelftest else {
        print("✗ 需要 TINGZHE_SELFTEST_MAINPATH=1（防止误调真 API / 误粘到焦点框）"); exit(2)
    }
    let c = Controller.shared
    c.startRecording()
    Thread.sleep(forTimeInterval: 1.0)      // 录够 1 秒,越过 dur > 0.4 的 guard
    c.stopAndTranscribe()
    // ⛔ 生产路径的最后一步是 `DispatchQueue.main.async { deliver(fixed) }` —— 它依赖**主队列在跑**。
    // 常驻里那个 run loop 由 `app.run()` 提供;CLI 路径没有,所以 deliver 永不执行。
    // 「忠实驱动主路径」也包括**给它它依赖的运行环境**,否则自检会因为自己的缺失而误报产品坏了
    // (2026-07-26 实测踩到:干净构建下也红,而日志显示管线全对)。
    var signaled = false
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        if mainPathDone.wait(timeout: .now()) == .success { signaled = true; break }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    if !signaled {
        print("✗ 主路径没走到 deliver —— 录音时长 guard 或转写链路断了（踩过的坑 #1 的形状）")
        exit(1)
    }
    guard mainPathClipboardOK else {
        print("✗ deliver 走到了,但**剪贴板里不是修正后的文本** —— 投递那一段坏了")
        exit(1)
    }
    print("✓ selftest-mainpath: 生产路径 startRecording → stopAndTranscribe → 词表 → deliver 全通")
    print("  （剪贴板内容已断言；transcribe 未出网）")
    print("  ⚠ 仍未被断言:AX 判定分支与 CGEvent ⌘V 投递 —— 闸里 post 真 ⌘V 会粘进当时聚焦的窗口,不能做")
    exit(0)
}

// ⛔ 让闸去问产品「按住说话有哪些合法值」,而不是在 check.sh 里抄一份。
// 2026-07-28:抄的那份没跟上 pttChoices 扩到 9 个,作者 从面板选了 leftOption,
// 闸当场判红 —— 而产品是对的。**同一份清单存两处,第二处一定会落后。**
if CommandLine.arguments.contains("--list-ptt-keys") {
    for c in pttChoices { print(c.raw) }
    exit(0)
}

if CommandLine.arguments.contains("--selftest-voice") {
    // ⛔ 作者 2026-07-28 拍的开关行为:「按一个键就打开，一直打开，再按一个键就关上」。
    // 这一项存在的理由跟第 7/10/11 项一样:**开关的状态被另一个进程读**
    // (`speak-hook.sh` 是 Claude 每轮说完时才被拉起来的独立进程),
    // 进程内的布尔值它看不见 —— 所以"状态落到文件"这件事必须有人断言。
    var bad = 0
    func check(_ ok: Bool, _ what: String) {
        print(ok ? "  ✓ \(what)" : "  ✗ \(what)"); if !ok { bad += 1 }
    }
    // ⛔⛔ 2026-07-28 踩过的坑的第一道防线:自检**绝不许碰生产状态位**。
    // 上一版靠 HOME="$SANDBOX" 隔离,而 homeDirectoryForCurrentUser 不认 HOME →
    // 自检删掉了 作者 生产的 voice-on,把他卡在「麦开着、界面说关着、关不掉」。
    // 现在:没显式给 TINGZHE_STATE_DIR 就**直接拒跑**,而不是"默默去动真的那个"。
    guard let sd = ProcessInfo.processInfo.environment["TINGZHE_STATE_DIR"], !sd.isEmpty else {
        print("✗ 拒绝运行:没给 TINGZHE_STATE_DIR。本自检会真的建/删语音状态位,")
        print("   不隔离就会动到生产的那个 —— 2026-07-28 正是这样把 作者 卡在「麦关不掉」。")
        exit(2)
    }
    let prodFlag = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/tingzhe/voice-on")
    let prodBefore = FileManager.default.fileExists(atPath: prodFlag.path)
    // ⚠ 静音位同规:要查的是「**我**有没有动它」,不是「它存不存在」。
    //   第一版写成了后者 —— 作者 合法地点一次静音,闸就红了(2026-07-28 当场踩到)。
    //   旁边 prodBefore/prodAfter 本来就是对的形状,我却在隔壁两行写错了同一件事。
    let prodMuted = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/tingzhe/voice-muted")
    let prodMutedBefore = FileManager.default.fileExists(atPath: prodMuted.path)

    let f = VoiceMode.flagURL
    check(f.path.hasPrefix(sd), "状态位落在沙箱里（\(f.path)）")
    try? FileManager.default.removeItem(at: f)

    check(!VoiceMode.isOn, "出厂是关的（不是全天候）")
    VoiceMode.setOn(true)
    check(VoiceMode.isOn, "开：状态位已建立")
    check(FileManager.default.fileExists(atPath: f.path),
          "开：状态落在**文件**里（钩子那个进程读得到）")
    VoiceMode.toggle()
    check(!VoiceMode.isOn, "再按一下：关掉了")
    check(!FileManager.default.fileExists(atPath: f.path), "关：状态位已清除")
    VoiceMode.toggle()
    check(VoiceMode.isOn, "再按一下：又开了（切换是幂等来回的）")
    VoiceMode.setOn(false)

    // ── 快捷键可配(作者 2026-07-28:「我不能确定别人用的是什么设备」) ─────────
    // ⛔ 这是开源前提。原来只认 4 个写死的字符串,别人键盘一冲突就没有出路。
    check(HotKey.parse("ctrl+opt+v")?.code == UInt16(kVK_ANSI_V), "解析 ctrl+opt+v 的主键")
    check(HotKey.parse("ctrl+opt+v")?.mods == [.control, .option], "解析 ctrl+opt+v 的修饰键")
    check(HotKey.parse("CMD+Shift+M")?.mods == [.command, .shift], "大小写随意（CMD+Shift+M）")
    check(HotKey.parse("⌃⌥space")?.code == UInt16(kVK_Space)
          && HotKey.parse("⌃⌥space")?.mods == [.control, .option], "符号写法也认（⌃⌥space）")
    check(HotKey.parse("ctrl-opt-1")?.code == UInt16(kVK_ANSI_1), "连字符当分隔符（ctrl-opt-1）")
    check(HotKey.parse("f13")?.code == UInt16(kVK_F13) && HotKey.parse("f13")?.mods == [],
          "裸 F 键（f13）")
    check(HotKey.parse("ctrl+opt+紫") == nil, "认不出来就返回 nil，不瞎猜一个键")
    check(HotKey.parse("ctrl+v+m") == nil, "两个主键 = 写错了，也不猜")
    check(HotKey.keys.count >= 60, "键名表覆盖 a-z/0-9/F1-F20/方向键等（\(HotKey.keys.count) 个）")
    // ⛔ 裸键必须**拒装**而不是警告 —— 一个会在打字时乱开麦的快捷键,
    //   "警告一句"没有任何东西依赖它(本项目已被这个形状咬过好几次)。
    // ⛔⛔ 作者 2026-07-28:「你不要给人家设这么多限制…他愿意误触是他的事情…爹味儿这么重」。
    //   这一组断言的方向是**反过来的**:验的不是"我拦住了什么",而是
    //   **"我什么都没拦"** —— 只要装得上就必须能选。以前拦的三类逐条验它们现在能装。
    let anyOthers = ["voice_toggle_key": "ctrl+opt+v", "voice_mute_key": "rightopt",
                     "voice_mode_key": "cmd"]
    for k in ["v", "5", "space", "cmd", "ctrl", "opt", "rightopt", "rightcmd",
              "f13", "escape", "ctrl+opt+v", "shift"] {
        check(HotKey.rejectReason(k, forKey: "voice_mute_key", others: anyOthers) == nil,
              "「\(HotKey.pretty(k))」装得上，不拦")
    }
    check(HotKey.rejectReason("紫薯布丁", forKey: "voice_mute_key", others: anyOthers) != nil,
          "只有真的解析不出来才不收（那不是限制，是装不上）")
    // 代价只提醒,不影响能不能装
    check(HotKey.warnReason("rightopt", forKey: "voice_mute_key", others: [:])?.contains("按住说话") == true,
          "选右⌥ 会告诉你它跟按住说话是同一把 —— 但照样给你装")
    check(HotKey.warnReason("cmd", forKey: "voice_mute_key", others: [:]) != nil, "左⌘ 提醒日常在用")
    check(HotKey.warnReason("v", forKey: "voice_mute_key", others: [:]) != nil, "裸字母提醒会误触发")
    check(HotKey.warnReason("ctrl+opt+v", forKey: "voice_mute_key",
                            others: ["voice_toggle_key": "ctrl+opt+v"])?.contains("同一把") == true,
          "跟别人撞了会提醒「两件事会一起发生」—— 也照样给你装")
    check(HotKey.warnReason("f13", forKey: "voice_mute_key", others: [:]) == nil, "F13 没什么好提醒的")
    check(HotKey.warnReason("rightcmd", forKey: "voice_mute_key", others: [:]) == nil, "右⌘ 没什么好提醒的")
    check(HotKey.parseTap("rightopt") != nil, "右⌥ 也能当开关键（作者 点名的那个）")

    check(HotKey.keys.count >= 60, "键名表覆盖 a-z/0-9/F1-F20/方向键等（\(HotKey.keys.count) 个）")
    // ⛔ 裸键必须**拒装**而不是警告 —— 一个会在打字时乱开麦的快捷键,
    //   "警告一句"没有任何东西依赖它(本项目已被这个形状咬过好几次)。
    // ⛔ 作者 2026-07-28:「我一定要是两个键的组合吗？」—— 不是。那条限制是我加的。
    //   现在**单键一律允许**,只在它会打出字时提醒一句。要不要承担由用的人决定。
    check(HotKey.isSafe("v"), "单个字母 v 也能当快捷键（作者 要的就是这个）")
    check(HotKey.warnReason("v", forKey: "", others: [:]) != nil, "但会提醒：单键且会打出字，打字时会误触发")
    check(HotKey.warnReason("f13", forKey: "", others: [:]) == nil, "F13 单键不提醒（它本来就不产生文字）")
    check(HotKey.warnReason("escape", forKey: "", others: [:]) == nil, "Esc 单键不提醒")
    check(HotKey.warnReason("up", forKey: "", others: [:]) == nil, "方向键单键不提醒")
    check(HotKey.warnReason("ctrl+opt+v", forKey: "", others: [:]) == nil, "带修饰键的不提醒")
    check(HotKey.typesText("space") && HotKey.typesText("1") && HotKey.typesText("comma"),
          "space / 数字 / 标点都算会打出字")

    // 三把开关键 + 按住说话那把,谁跟谁都不许撞
    let bindings: [(String, String)] = [
        ("voice_toggle_key", (hudConfig()["voice_toggle_key"] as? String) ?? "ctrl+opt+v"),
        ("voice_mute_key", (hudConfig()["voice_mute_key"] as? String) ?? "ctrl+opt+m"),
        ("voice_mode_key", (hudConfig()["voice_mode_key"] as? String) ?? "ctrl+opt+b"),
    ]
    var seen: [String: String] = [:]
    var clash: String?
    for (name, raw) in bindings {
        guard let p = HotKey.parse(raw) else { continue }
        let sig = "\(p.code)/\(p.mods.rawValue)"
        if let other = seen[sig] { clash = "\(name) 跟 \(other) 都是 \(raw)" }
        seen[sig] = name
    }
    // ⚠ 撞车不再判红 —— 作者 拍「他愿意误触是他的事情」。撞了会在面板上标 ⚠ 说清。
    if clash != nil { print("     ℹ️  \(clash!)（不拦，面板上会标 ⚠）") }

    // ── 面板上改键(作者 2026-07-28:「让我去 config 文件里改，这有点费劲的」) ─────
    // 捕获→回写这条链的判断部分全是纯函数,闸直接验;真按键那一下验不了,如实标。
    check(HotKey.describe(code: UInt16(kVK_ANSI_V), mods: [.control, .option]) == "ctrl+opt+v",
          "按下的那一下能翻回规范写法（⌃⌥V → ctrl+opt+v）")
    check(HotKey.parse(HotKey.describe(code: UInt16(kVK_ANSI_K), mods: [.command, .shift])!)?.code
          == UInt16(kVK_ANSI_K), "写出来的还能读回去（describe → parse 往返一致）")
    check(HotKey.preferred[UInt16(kVK_Return)] == "return",
          "一个键码只有一个正名（return/enter 不会写出两种样子）")
    check(HotKey.pretty("ctrl+opt+v") == "⌃⌥V", "面板上显示成 ⌃⌥V（给人看的）")
    // ⛔ 判据用**固定**的 others,不读实时 config —— 上一版读了,
    //   而 作者 当天用面板把 voice_toggle_key 改成了 opt+slash,于是这条断言当场变红。
    //   **闸红了却不是产品坏了 = 假警报**,而假警报比没有警报更贵:下次真红你会先怀疑闸。
    // 名字里必须出现你会用来找它的那个词 —— 作者 找不到"一条一条发信息那个模式",
    // 就是因为它当时叫「切发送方式」
    // ⛔ 作者 2026-07-28:「你要拿前端用户给他们命名的那个名字…两个 session 同一个 repo 就乱了」
    do {
        let titles = StatusBar.desktopTitles
        check(!titles.isEmpty, "读得到桌面端那份 session 标题表（\(titles.count) 条）")
        // ⛔ 病例:同一个仓两个 session。旧写法两个都显示仓名,分不开。
        // ⚠ 例子里别写真实仓名 —— 会触发跨仓治理注入,每跑一次闸污染一次 context。
        let fake = ["aaaaaaaa-1": "甲线 · 引擎开发", "bbbbbbbb-2": "乙线 · 每日巡检"]
        let a = StatusBar.resolveLabel(id: "aaaaaaaa-1", repoLabel: "某个仓", titles: fake)
        let b = StatusBar.resolveLabel(id: "bbbbbbbb-2", repoLabel: "某个仓", titles: fake)
        check(a != b, "同一个仓的两个 session 名字分得开（\(a) / \(b)）")
        check(a == "甲线 · 引擎开发", "用的是用户在前端起的那个名字，不是仓名")
        check(StatusBar.resolveLabel(id: "cccc-3", repoLabel: "某个仓", titles: fake) == "某个仓",
              "还没被命名的退回仓名")
        check(StatusBar.resolveLabel(id: "dddddddd-4", repoLabel: nil, titles: [:]) == "dddddddd",
              "仓名也没有就退回 id 前 8 位（永远不会显示成空白）")
        check(StatusBar.resolveLabel(id: "e-5", repoLabel: "repo", titles: ["e-5": ""]) == "repo",
              "标题是空字符串时当没有（否则面板上会出现一行没字的按钮）")
        // 真实数据上跑一遍,把结果打出来给人看(不当判据 —— 它依赖 作者 当下开着哪些会话)
        let real = StatusBar.sessions()
        if !real.isEmpty {
            print("     ℹ️  当前会列出 \(real.count) 个会话，取的是前端标题（名字不打印，避免泄漏别的项目）")
        }
    }

    // ⛔ 作者 2026-07-28:「那个模式是要按下去我再说话，可是按什么键呢？你根本没给我配置项」
    // ⛔ 作者 2026-07-28:「我不能选择 command control option 这几个键」
    check(HotKey.parseTap("cmd") != nil && HotKey.parseTap("ctrl") != nil
          && HotKey.parseTap("opt") != nil, "⌘ / ⌃ / ⌥ 单独能当开关键（轻点一下）")
    check(HotKey.parseTap("command")?.code == HotKey.parseTap("cmd")?.code,
          "command 和 cmd 是同一把（别名不分家）")
    check(HotKey.parseTap("rightopt")?.pretty == "右⌥" && HotKey.parseTap("opt")?.pretty == "左⌥",
          "左右分得开（右⌥ 是按住说话用的，不能被开关键占走）")
    check(HotKey.isSafe("cmd") && HotKey.pretty("cmd") == "轻点 左⌘",
          "面板上显示成「轻点 左⌘」")
    check(!HotKey.typesText("cmd"), "修饰键本身不打出字，不该按「会误触发文字」提醒")
    check(pttChoices.contains { $0.raw.lowercased().hasPrefix("left") },
          "按住说话也能选左侧那几个（作者 点名要的）")
    check(pttChoices.allSatisfy { c in
            if case .singleModifier(let n, _, _) = hotKeyStyle(from: c.raw) {
                return c.raw.lowercased().hasPrefix("left") ? n.contains("左") : true
            }
            return true
          }, "左右标签没弄反（选左⌥ 装的就是左⌥）")

    check(pttChoices.count >= 5, "按住说话有多个可选项可以在面板上换（\(pttChoices.count) 个）")
    check(pttChoices.contains { !$0.needsAX },
          "至少有一个不需要辅助功能权限的选项（否则没授权时面板上全是不能用的）")
    check(pttChoices.allSatisfy { c in
            if case .carbonCombo = hotKeyStyle(from: c.raw) { return true }
            if case .singleModifier = hotKeyStyle(from: c.raw) { return true }
            return false
          }, "面板列的每个选项都真的解析得出一把键（没有列一个装不上的）")
    check(pttChoices.contains { $0.raw.lowercased() == loadHotKeyRaw().lowercased() },
          "你当前用的那把在列表里（\(loadHotKeyRaw())）—— 否则面板会显示成第一项，看着像被改掉了")

    check(HotKey.label("voice_mode_key").contains("一句一条"),
          "发送方式那把键的名字里带「一句一条」（实得「\(HotKey.label("voice_mode_key"))」）")
    // 实时配置只用来查**当前有没有撞车**(那是真该红的),不用来当固定判据的素材
    // ⛔ 用 isSafe 不用 parse:parse 只认组合键,而「轻点 ⌘/⌃/⌥」走 parseTap ——
    //   作者 当天把三把全设成了轻点型,闸当场判红,**而产品是对的**。
    //   这是同一天第三次「闸落后于产品」。
    check(HotKey.current().values.allSatisfy { HotKey.isSafe($0) },
          "你当前三把键都认得（\(HotKey.current().values.sorted().map { HotKey.pretty($0) }.joined(separator: " / "))）")
    check(HotKey.current().count == 3 && HotKey.defaults.count == 3,
          "面板列的就是这三把，跟实际装的是同一份表（没有第二份清单）")
    for (name, raw) in bindings {
        check(HotKey.isSafe(raw), "\(name)=\(HotKey.pretty(raw)) 认得（组合键或轻点修饰键）")
        // ⚠ 有代价的照旧说,但**不判红** —— 作者 2026-07-28 拍「他愿意误触是他的事情」。
        if let w = HotKey.warnReason(raw, forKey: name, others: HotKey.current()) {
            print("     ℹ️  \(name)=\(HotKey.pretty(raw))：\(w)（你选的就是它）")
        }
    }

    // ── 常开麦(作者 2026-07-28 拍 Q3改判丙) ────────────────────────────
    // ⛔ 回声消除是**上线前提**,不是优化项:没有它,麦开着就会把我自己的 TTS 录回去转写再发给我
    //    = 死循环。所以这一条必须有人断言,不能"我以为系统会处理"。
    let eng = AVAudioEngine()
    var aecOK = false
    do { try eng.inputNode.setVoiceProcessingEnabled(true); aecOK = eng.inputNode.isVoiceProcessingEnabled }
    catch { aecOK = false }
    check(aecOK, "回声消除可开启（否则常开麦会把我自己的声音录回去 → 死循环）")
    let fmt = eng.inputNode.outputFormat(forBus: 0)
    check(fmt.sampleRate > 0, "拿得到麦克风格式（采样率 \(Int(fmt.sampleRate))Hz）")

    // 打断:必须能把正在播的掐掉。起一个真的 afplay 来打,不是嘴上说能打
    let probe = FileManager.default.temporaryDirectory.appendingPathComponent("moss-shutup.aiff")
    let mk = Process(); mk.launchPath = "/usr/bin/say"
    mk.arguments = ["-v", "Tingting", "-o", probe.path, "这是一段用来测试打断的比较长的话，说完之前应该被掐掉。"]
    try? mk.run(); mk.waitUntilExit()
    if FileManager.default.fileExists(atPath: probe.path) {
        let pl = Process(); pl.launchPath = "/usr/bin/afplay"; pl.arguments = [probe.path]
        try? pl.run()
        Thread.sleep(forTimeInterval: 0.6)
        let wasPlaying = Speaker.isPlaying
        Speaker.shutUp()
        Thread.sleep(forTimeInterval: 0.4)
        check(wasPlaying, "打断前确实在播（否则这条测了个寂寞）")
        check(!Speaker.isPlaying, "你一开口能把正在播的掐掉（barge-in）")
        pl.terminate()
        try? FileManager.default.removeItem(at: probe)
    }

    // ⛔ 灵敏度必须**改完立刻生效** —— 否则面板上那三个按钮就是装饰。
    // 作者 2026-07-28 要的就是这个交互,而"要重启才生效"等于没有交互。
    let cfgF = projectDir.appendingPathComponent("config.json")
    let orig = try? Data(contentsOf: cfgF)
    func writeMult(_ v: Double) {
        var j = (try? Data(contentsOf: cfgF)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        j["voice_gate_mult"] = v
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted]) {
            try? d.write(to: cfgF)
        }
    }
    writeMult(2.5); let m1 = VoiceLoop.shared.gateMult
    writeMult(5.0); let m2 = VoiceLoop.shared.gateMult
    check(abs(m1 - 2.5) < 0.01 && abs(m2 - 5.0) < 0.01,
          "灵敏度改完**立刻生效**，不用重启（读到 \(m1) → \(m2)）")
    // ⛔ 写回时不许冲掉别的字段 —— config 里还有 hotkey/hud,冲掉等于抹了 作者 的设置
    let after = (try? Data(contentsOf: cfgF)).flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    check(after["hotkey"] != nil, "写灵敏度没冲掉 config 里的其它字段（hotkey 还在）")
    if let o = orig { try? o.write(to: cfgF) }   // 还原,自检不留痕

    // ⛔ 作者 2026-07-28 抓「有时候时间顺序上会切反」→ 顺序投递必须能验。
    // 构造:第 2 段先完成、第 0 段最后完成 —— 只有按编号排队才能出对的顺序。
    do {
        let c = Controller.shared
        var got: [String] = []
        deliverProbe = { got.append($0) }
        c.resetSeqForSelftest()
        c.probeDeliverInOrder(2, "丙")
        c.probeDeliverInOrder(1, "乙")
        c.probeDeliverInOrder(0, "甲")     // 最后到,但它该第一个出来
        // ⚠ deliverInOrder 把真投递扔进主队列,而自检里主循环没在跑 —— 必须泵一下,
        // 否则测的是"队列里有没有东西",不是"顺序对不对"(第一版就这么打了空)。
        let dl = Date().addingTimeInterval(1.5)
        while Date() < dl && got.count < 3 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        deliverProbe = nil
        check(got == ["甲", "乙", "丙"],
              "乱序完成也按原顺序投递（实得 \(got.joined(separator: "→")))")
    }

    // ⛔⛔ 2026-07-28 咖啡馆回归 —— 这一条守的就是那次事故本身。
    // 当时 作者 一句话被切成三条、各自补了回车,**连着打断我三次**。
    // 用的就是他当时那三段原话,这样将来谁把 Composer 拆了,闸会直接把病重演出来。
    do {
        let c = Controller.shared
        var got: [String] = []
        deliverProbe = { got.append($0) }
        VoiceMode.setOn(true)
        // 只要状态位,不要真麦 —— 否则环境音会触发 beginTurn 撤掉计时器,闸变成随机红
        VoiceLoop.shared.stop()
        Composer.discard()
        c.resetSeqForSelftest()
        c.probeDeliverInOrder(0, "我需要就是说有一个单方面静音的功能。")
        c.probeDeliverInOrder(1, "个呢就是。")
        c.probeDeliverInOrder(2, "呃呃，我需要能够在那种单条语音发送。")
        let dl = Date().addingTimeInterval(Composer.windowSec + 2.0)
        while Date() < dl && got.isEmpty {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        // 再泵一会儿:确认后面**没有**第二条跟出来(只验"发过了"抓不到切成多条这个病)
        let dl2 = Date().addingTimeInterval(0.7)
        while Date() < dl2 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        deliverProbe = nil
        VoiceMode.setOn(false)
        check(got.count == 1,
              "三段停顿说完的话只发**一条**（实得 \(got.count) 条 · 07-28 咖啡馆就是被切成三条）")
        check(got.first == "我需要就是说有一个单方面静音的功能。个呢就是。呃呃，我需要能够在那种单条语音发送。",
              "拼回来仍是原话原顺序")
        check(Composer.pendingCount == 0, "发完缓冲清空（不会把这句话顶到下一条前面）")
    }
    // ⛔ 作者 2026-07-28:「两种方式并行，不是让你用旧的替代掉」。
    // ⇒ **两条路都要有闸**。只守新路 = 切回一句一条那天它已经悄悄坏了,而没人知道。
    do {
        let c = Controller.shared
        var got: [String] = []
        deliverProbe = { got.append($0) }
        setenv("TINGZHE_SEND_MODE", "instant", 1)
        VoiceMode.setOn(true); VoiceLoop.shared.stop(); Composer.discard()
        c.resetSeqForSelftest()
        c.probeDeliverInOrder(0, "第一句。")
        c.probeDeliverInOrder(1, "第二句。")
        c.probeDeliverInOrder(2, "第三句。")
        let dl = Date().addingTimeInterval(2.0)
        while Date() < dl && got.count < 3 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        deliverProbe = nil; VoiceMode.setOn(false)
        unsetenv("TINGZHE_SEND_MODE")
        check(got == ["第一句。", "第二句。", "第三句。"],
              "一句一条模式：三段发**三条**、且按原顺序（实得 \(got.count) 条 \(got.joined(separator: "|"))）")
        check(!Composer.isInstant, "env 撤掉后回到默认的攒成一条（两种模式不会互相粘住）")
    }

    do {   // join 里唯一不显然的那个分支:中文直接接、英文之间补空格
        let c = Controller.shared
        var got: [String] = []
        deliverProbe = { got.append($0) }
        VoiceMode.setOn(true); VoiceLoop.shared.stop(); Composer.discard()
        c.resetSeqForSelftest()
        c.probeDeliverInOrder(0, "run"); c.probeDeliverInOrder(1, "fast")
        let dl = Date().addingTimeInterval(Composer.windowSec + 2.0)
        while Date() < dl && got.isEmpty {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        deliverProbe = nil; VoiceMode.setOn(false)
        check(got.first == "run fast", "英文碎片之间补空格（实得「\(got.first ?? "")」，不能是 runfast）")
    }

    // ── 单方面静音(作者 2026-07-28 咖啡馆要的) ──────────────────────
    VoiceMode.setOn(true)
    check(!VoiceMode.isMuted, "开语音模式时静音位是清的（否则会「打开了却听不见我」）")
    check(VoiceMode.mutedURL.path.hasPrefix(sd), "静音位也落在沙箱里（\(VoiceMode.mutedURL.path)）")
    VoiceMode.setMuted(true)
    check(VoiceMode.isMuted, "静音：状态落在**文件**里（跟 voice-on 同规，进程重启还在）")
    // ⛔ 原来这条读的是 `isRunning`,而那要求闸真去开一次麦(见 start() 头注的事故路径)。
    //   ⇒ 默认验**判断本身**(纯函数,不碰设备);真设备行为留给显式开关。
    check(!VoiceLoop.wantsRunning(), "静音时按状态就不该开着麦（判断层）")
    if ProcessInfo.processInfo.environment["TINGZHE_ALLOW_MIC"] == "1" {
        check(!VoiceLoop.shared.isRunning, "静音时麦**真的停了**（真设备 · TINGZHE_ALLOW_MIC=1）")
    } else {
        print("     ⚪ 真设备那半没测（要 TINGZHE_ALLOW_MIC=1）—— 默认不开麦，见 start() 头注")
    }
    check(VoiceMode.isOn, "静音 ≠ 关掉语音模式（单方面：我还念给你听）")
    VoiceMode.setMuted(false)
    check(VoiceLoop.wantsRunning(), "取消静音后按状态就该开着麦（判断层，两个方向都验）")
    VoiceMode.setMuted(true)
    VoiceMode.setMuted(false)
    check(!VoiceMode.isMuted, "取消静音：状态位已清除")
    VoiceMode.setOn(false)
    VoiceMode.setMuted(false)

    // ⛔ 作者 2026-07-28:「在卧室都嫌敏感，到咖啡馆就爆炸」→ 起录必须要求**持续**发声。
    // 这条守的是"瞬时噪音不该触发录音"这个性质,不是某个具体数字。
    // ⛔⛔ 2026-07-28 咖啡馆第二次的回归闸 —— 作者:「话没说完就切回听着，之后再也收不到」。
    // 病是**正反馈**:被切断后 speaking=false,你还在说的帧被当环境音吸进底噪 →
    // 门槛涨 → 更进不来 → 吸得更多。纯数值逻辑,必须有闸。
    do {
        var f: Float = 0.010
        for _ in 0..<600 { f = VoiceLoop.updateFloor(f, level: 0.080, isVoice: true) }
        check(f <= 0.010 + 1e-6,
              "600 帧你自己的说话声**一点都没进底噪**（\(String(format: "%.4f", f))；旧写法会涨到 0.08 附近）")

        var q: Float = 0.050
        for _ in 0..<200 { q = VoiceLoop.updateFloor(q, level: 0.002, isVoice: false) }
        check(q < 0.006,
              "环境一安静，底噪快速降回来（\(String(format: "%.4f", q))）—— 否则吵过一阵就永久变聋")

        var r: Float = 0.005
        for _ in 0..<200 { r = VoiceLoop.updateFloor(r, level: 0.020, isVoice: false) }
        check(r > 0.005 && r < 0.020,
              "真环境音能缓慢抬底噪但不会一步到位（\(String(format: "%.4f", r))）")

        check(VoiceLoop.gateFrom(floor: 1.0, startRMS: 0.02, mult: 5, ceiling: 0.09) == 0.09,
              "底噪再离谱，门槛也封顶在 0.09（不封顶 = 涨到听不见你之后再没帧能证明它太高）")
        check(VoiceLoop.gateFrom(floor: 0.0, startRMS: 0.02, mult: 5, ceiling: 0.09) == 0.02,
              "再安静也不低于 startRMS（否则呼吸声都算说话）")
    }

    // ⛔⛔ 2026-07-28 咖啡馆实证:三档灵敏度**一动没动过门槛**(日志里 13 次有 8 次门槛恰好 0.0200
    //   = 出厂绝对下限)。这条闸守的就是「这个控件真的接线了」——
    //   拿实测到的底噪 0.002 喂进去,三档必须给出三个**不同**的门槛。
    do {
        let cafeFloor: Float = 0.002       // 实测区间 0.0007–0.0060 的中位附近
        let gates = VoiceLoop.presets.map {
            VoiceLoop.gateFrom(floor: cafeFloor, startRMS: Float($0.floor),
                               mult: Float($0.mult), ceiling: 0.09)
        }
        check(Set(gates).count == 3,
              "三档灵敏度在真实咖啡馆底噪(0.002)下给出三个不同门槛（实得 \(gates)）")
        check(gates == gates.sorted(),
              "从灵敏到迟钝，门槛单调变高（否则按钮的方向是错的）")
        check(gates.last! > 0.05,
              "最钝那档高到能挡住隔壁桌（\(gates.last!)；别人隔一两米说话约 0.02–0.05）")
        check(VoiceLoop.presets.count == 3, "面板上那三个按钮读的就是这份表（没有第二份）")
    }

    check(VoiceLoop.shared.onsetMs >= 150,
          "起录要求连续发声 ≥\(Int(VoiceLoop.shared.onsetMs))ms（瞬时噪音撑不到）")
    check(VoiceLoop.shared.gateMult >= 3.0,
          "门槛倍数 \(VoiceLoop.shared.gateMult)×底噪（越大越不容易被环境音触发）")

    let cfgKeys = ["voice_start_rms", "voice_silence_ms", "voice_min_turn_s", "voice_max_turn_s",
                   "voice_gate_mult", "voice_onset_ms", "voice_send_after_ms"]
    check(cfgKeys.count == 7, "VAD 门槛均可由 config.json 覆盖（\(cfgKeys.joined(separator: " / "))）")
    // ⛔ 发送窗口必须**明显长于**分段窗口 —— 两者相等就等于没拆开这两个边界,病会原样回来。
    check(Composer.windowSec > 1.4 || ProcessInfo.processInfo.environment["TINGZHE_SEND_AFTER_MS"] != nil,
          "发送窗口 \(Composer.windowSec)s > 分段窗口 1.4s（相等 = 又变回按停顿切消息）")

    // ⛔⛔ 2026-07-28 作者:「你在改另一个东西，为什么弄得我的插件一直嘚嘚嘚地响？」
    // 闸对**用户能察觉的东西**也必须无副作用 —— 不只是不写盘。
    // 这三条盯的就是它们，因为每一条都是"跑闸的人听得见/看得见"的:
    check(beepsPlayed == 0,
          "整段自检**一声都没响过**（实测响了 \(beepsPlayed) 声；这一段本身会开关语音模式 6 次、静音 4 次）")
    check(!VoiceLoop.shared.isRunning || ProcessInfo.processInfo.environment["TINGZHE_ALLOW_MIC"] == "1",
          "自检没有打开真麦克风（那条路能把转写结果 ⌘V 进你当时的窗口）")

    // ⛔ 收尾必查:整段跑完,**生产状态位一个字节都不该动过**
    let prodAfter = FileManager.default.fileExists(atPath: prodFlag.path)
    let prodMutedAfter = FileManager.default.fileExists(atPath: prodMuted.path)
    // ⛔ 这条**分不清「闸动了它」和「人动了它」**。2026-07-28 实测:作者 在我跑闸的那 40 秒里
    //   自己按了一下关掉语音模式,闸当场判红 —— 而闸什么都没碰。
    //   **同一形状的第二次假警报**(第一次是静音位),而假警报比没有警报贵:下次真红先怀疑闸。
    // ⇒ 真正的保证是结构性的那条:`flagURL` 落在沙箱里(上面已断言),物理上够不着生产。
    //   前后对比只是纵深防御,而常驻活着时它跟"有人正在用"天生冲突 → 那种情况下只报信息。
    let pg = Process()
    pg.launchPath = "/usr/bin/pgrep"
    pg.arguments = ["-f", "tingzhe.app/Contents/MacOS"]
    pg.standardOutput = Pipe(); pg.standardError = Pipe()
    try? pg.run(); pg.waitUntilExit()
    let daemonAlive = (pg.terminationStatus == 0)
    if prodBefore == prodAfter {
        check(true, "整段自检没碰生产状态位（跑前后都是\(prodAfter ? "开" : "关")）")
    } else if daemonAlive {
        print("     ℹ️  生产状态位在这 40 秒里变了（\(prodBefore ? "开" : "关") → \(prodAfter ? "开" : "关")）"
              + "—— 常驻在跑，多半是你自己按的。闸够不着生产（状态位在沙箱里，上面已验）。")
    } else {
        check(false, "整段自检没碰生产状态位（跑前 \(prodBefore ? "开" : "关") → 跑后 \(prodAfter ? "开" : "关")；"
              + "常驻没在跑，那就只能是闸干的）")
    }
    check(prodMutedBefore == prodMutedAfter,
          "整段自检没碰生产静音位（跑前 \(prodMutedBefore ? "静音" : "在听") → 跑后 \(prodMutedAfter ? "静音" : "在听")）")

    if bad > 0 { print("✗ selftest-voice: \(bad) 项不过"); exit(1) }
    print("✓ selftest-voice: 开关落文件 · 切换正确 · 未撞既有手势 · 回声消除可开 · 打断有效 · 未碰生产状态")
    print("  ⚠ 未断言:菜单栏点得动不动、热键按下去灵不灵、VAD 在真人声音上准不准 —— 要真人用")
    exit(0)
}

// ⭐ 流式朗读入口。文本从 **stdin** 进,不走 argv ——
// argv 会出现在 `ps` 输出里,而念的正文就是我回你的话(含代码/路径/业务内容)。
// 用法: echo "要念的话" | tingzhe --speak
if CommandLine.arguments.contains("--speak") {
    let raw = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { exit(0) }
    guard let key = loadAPIKey() else {
        FileHandle.standardError.write(Data("✗ 没有 API key\n".utf8)); exit(1)
    }
    exit(StreamSpeaker().speak(text, key: key) ? 0 : 1)
}

if CommandLine.arguments.contains("--selftest-speak") {
    var bad = 0
    func check(_ ok: Bool, _ what: String) {
        print(ok ? "  ✓ \(what)" : "  ✗ \(what)"); if !ok { bad += 1 }
    }
    // ⛔⛔ 跟 --selftest-voice 同规,而且是**当场踩出来的**:这一项会 markSpeaking(true/false),
    // 没沙箱时它删的是**生产**的 speaking.pid —— 我第一次跑真机打断测试,
    // 就在念到一半时用这个自检把"正在念"的标志抹掉了。
    // 判据不是"我小心点跑",是**没给沙箱就拒跑**(07-28 voice-on 那条踩过的坑的同一形状,第二次)。
    guard let sd = ProcessInfo.processInfo.environment["TINGZHE_STATE_DIR"], !sd.isEmpty else {
        print("✗ 拒绝运行:没给 TINGZHE_STATE_DIR。本自检会建/删「正在念」「闭嘴」两个状态位,")
        print("   不隔离就会掐掉 作者 正在听的那段话。")
        exit(2)
    }
    check(TTS.speakingFlag.path.hasPrefix(sd) && TTS.shutUpFlag.path.hasPrefix(sd),
          "两个状态位都落在沙箱里")
    let prodSpeaking = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/tingzhe/speaking.pid")
    let prodBefore = FileManager.default.fileExists(atPath: prodSpeaking.path)
    // ⛔ 这三个参数少一个,流式就退回非流式(或直接 400)——而症状是"怎么还是慢",不报错。
    let b = TTS.requestBody("测试")
    check(b["stream"] as? Bool == true, "请求带 stream=true")
    check(b["version"] as? String == "flash-20260626",
          "请求带 version=flash-20260626（漏了它就没有流式 —— 我上一轮正是漏了这个才误判成不支持）")
    check(b["response_format"] as? String == "pcm", "response_format=pcm（mp3/wav 服务端一律 400）")

    // ⛔ 采样率/声道是**量出来的**:flash 流式版 48000Hz 立体声,默认版 24000Hz 单声道。
    //   写错不会报错,只会让你听见花栗鼠或慢动作 —— 所以钉在闸里。
    check(TTS.sampleRate == 48000, "采样率 48000（实测 flash 版 wav 头）")
    // ⛔⛔ 原来这里写的是 `TTS.channels == 2` —— 而那条流其实是**单声道**,
    //   我是拿**非流式 wav 的头**推的流式格式。闸照着我的假设写,于是一起错,
    //   绿得好好的而 作者 耳朵里全是花的。**闸抄了实现的假设 = 闸没有独立性。**
    //   实测两条独立判据见 TTS.channels 头注(交错比值 1.87 vs 292 · 基频 174.5 vs 87.3)。
    check(TTS.channels == 1, "单声道（流式 pcm 实测；⚠ 非流式 wav 是 2 声道，别拿它推流式）")
    // 判别器本身要能分得开 —— 否则运行时那道自检也是摆设
    do {
        var mono = Data(), stereo = Data()
        for i in 0..<4096 {                      // 一段正弦:单声道逐样本走,立体声左右相同
            let v = Int16(truncatingIfNeeded: Int(8000.0 * sin(Double(i) * 0.07)))
            withUnsafeBytes(of: v.littleEndian) { mono.append(contentsOf: $0) }
            withUnsafeBytes(of: v.littleEndian) { stereo.append(contentsOf: $0) }
            withUnsafeBytes(of: v.littleEndian) { stereo.append(contentsOf: $0) }
        }
        check(TTS.looksStereo(stereo) == true, "判别器认得出交错立体声（左右相同）")
        check(TTS.looksStereo(mono) == false, "判别器认得出单声道（相邻是相邻时刻）")
        check(TTS.looksStereo(Data([1, 2, 3, 4])) == nil, "数据太短时不下结论，不瞎猜")
    }

    // 解交错:构造左声道全 +1.0、右声道全 -1.0,错一位就会看出来
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    var d = Data()
    for _ in 0..<64 {
        var l = Int16(16384).littleEndian, r = Int16(-16384).littleEndian
        withUnsafeBytes(of: &l) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: &r) { d.append(contentsOf: $0) }
    }
    let buf = TTS.buffer(from: d, format: fmt)
    check(buf?.frameLength == 64, "64 帧交错数据 → 64 帧缓冲（实得 \(buf?.frameLength ?? 0)）")
    if let c = buf?.floatChannelData {
        check(abs(c[0][0] - 0.5) < 0.01 && abs(c[1][0] + 0.5) < 0.01,
              "左右声道没串（L=\(c[0][0]) R=\(c[1][0])，串了会听成糊在一起）")
        check(abs(c[0][63] - 0.5) < 0.01 && abs(c[1][63] + 0.5) < 0.01, "最后一帧也没串")
    } else { check(false, "拿得到声道数据") }
    // 半个采样点的碎片必须被丢掉而不是错位使用
    check(TTS.buffer(from: Data([0x01, 0x02]), format: fmt) == nil,
          "不足一帧的碎块不出缓冲（凑不齐就等下一块，别错位）")

    // 打断:碰一下标志文件,token 必须变
    let t0 = TTS.shutUpToken()
    TTS.signalShutUp()
    check(TTS.shutUpToken() != t0, "打断信号会改变 token（正在念的那个进程据此闭嘴）")
    check(TTS.shutUpFlag.path.hasSuffix("shutup"), "打断信号是文件不是 pkill —— pkill 会连常驻一起杀（同名）")

    // ⛔ 换播放方式必须同时换「谁在播」的判据 —— 否则 Speaker.isPlaying 恒 false,
    //   shutUp 永远不被调用,**打断整个失效而且不报错**。差点漏掉的就是这条。
    TTS.markSpeaking(false)
    check(!TTS.isSpeaking, "没人念的时候 isSpeaking=false")
    TTS.markSpeaking(true)
    check(TTS.isSpeaking, "正在念的时候 isSpeaking=true（常驻据此决定要不要掐）")
    check(Speaker.isPlaying, "Speaker.isPlaying 认得流式那条路（只认 afplay 的话打断会静默失效）")
    try? Data("999999".utf8).write(to: TTS.speakingFlag)
    check(!TTS.isSpeaking, "陈旧 PID（进程已死）不算在念 —— 崩溃一次不会让打断永久卡住")
    TTS.markSpeaking(false)

    check(prodBefore == FileManager.default.fileExists(atPath: prodSpeaking.path),
          "整段自检没碰生产的「正在念」标志（碰了 = 掐掉 作者 正在听的那段）")

    if bad > 0 { print("✗ selftest-speak: \(bad) 项不过"); exit(1) }
    print("✓ selftest-speak: 流式三参数齐 · 48k 单声道(实测) · 解交错正确 · 碎块不错位 · 打断走文件不走 pkill")
    print("  ⚠ 未断言:真的出声好不好听、首块到达延迟 —— 要真跑一次网络 + 真耳朵")
    exit(0)
}

if CommandLine.arguments.contains("--selftest-hud") {
    // ⛔ 方案丙的判据(设计档 §18 丙-7)。**不抢焦点**是它的硬要求:
    // 作者 正在别的窗口打字,浮层一旦夺走 key window,他下一个字就打进了我们的面板。
    var bad = 0
    func check(_ ok: Bool, _ what: String) {
        print(ok ? "  ✓ \(what)" : "  ✗ \(what)"); if !ok { bad += 1 }
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let before = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"

    HUD.shared.show(raw: "乙项目的评估", fixed: "乙项目的评估", fired: true)
    let deadline = Date().addingTimeInterval(1.0)
    while Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }

    // ⛔ 2026-07-28:原来这里断言 `before == after` —— 它测的是「这一秒里前台应用有没有变」,
    // **不是「是不是我们抢的」**。作者 在这一秒切个窗口就假红(实测:闸里报 Chrome 而单跑连过 5 次)。
    // 一条会因为无关原因变红的闸,最终只会训练出「这条红可以忽略」。
    // ⭐ 改成只问跟我们有关的事:**前台的不是我们** + 我们没被激活 + 面板不是 key window。
    //    这不是放宽 —— 浮层真抢了焦点,前台就必然是我们(下面注入实测仍红)。
    let after = NSWorkspace.shared.frontmostApplication
    let mePID = NSRunningApplication.current.processIdentifier
    // ⚠ 如实标注这条的**判别力**:注入「.titled + makeKeyAndOrderFront + .regular」实测,
    //   转红的是下面的 canBecomeKey / styleMask,**这一条一声不响**。它至今没抓到过任何东西。
    //   留着是因为它覆盖一个我构造不出的模式(app 级激活),**但真正守门的是下面几条,别搞反**。
    check(after?.processIdentifier != mePID,
          "前台应用不是本进程（当前前台 \(after?.localizedName ?? "?")；起浮层前是 \(before)）")
    check(!NSRunningApplication.current.isActive, "本进程未被激活")
    let panels = app.windows.compactMap { $0 as? NSPanel }
    check(!panels.isEmpty, "浮层已创建")
    if let p = panels.first {
        check(!p.canBecomeKey, "canBecomeKey = false")
        check(!p.canBecomeMain, "canBecomeMain = false")
        check(!p.isKeyWindow, "不是 key window")
        check(p.styleMask.contains(.nonactivatingPanel), "styleMask 含 .nonactivatingPanel")
    }

    // ⛔ 写入安全 = §17.1 的否决线:否决**绝不能**自动写词表,只许落候选队列
    let dictPath = projectDir.appendingPathComponent("dict.json").path
    let negPath  = projectDir.appendingPathComponent("negatives.txt").path
    func mtime(_ p: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate]) as? Date
    }
    let d0 = mtime(dictPath), n0 = mtime(negPath)
    let pend = logDirURL.appendingPathComponent("pending-review.jsonl")
    let p0 = (try? String(contentsOf: pend, encoding: .utf8))?.count ?? 0
    HUD.shared.veto()
    let p1 = (try? String(contentsOf: pend, encoding: .utf8))?.count ?? 0
    check(d0 == mtime(dictPath), "否决没有碰 dict.json")
    check(n0 == mtime(negPath), "否决没有碰 negatives.txt")
    check(p1 > p0, "否决落进了 pending-review.jsonl（候选,不是决定）")

    // hud:false 必须真的关得掉 —— 这是我给「我推荐甲而 作者 拍丙」留的退路,退路坏了等于没有
    check(loadHUDEnabled() == true || loadHUDEnabled() == false, "config 的 hud 字段可读")

    // ⛔ 2026-07-28 作者 改判「位置太偏 + 时间太短」后新增。
    // 这两个数以前是写死的常量,没有任何东西验过它们 —— 而 作者 用起来不方便的正是它们。
    check(kHUDSeconds >= 8, "停留时长 ≥8s（当前 \(kHUDSeconds)s · 原来写死 4s）")
    check(["caret", "bottom", "topright"].contains(kHUDPosition), "位置模式合法（当前 \(kHUDPosition)）")
    if let p = panels.first {
        // 位置必须在可见屏内 —— clamp 坏了会把浮层甩到屏幕外,那就等于没有浮层
        if let v = NSScreen.main?.visibleFrame {
            check(v.intersects(p.frame), "浮层落在可见屏幕内（frame \(Int(p.frame.minX)),\(Int(p.frame.minY))）")
        }
        // ⛔ 2026-07-28 作者:「不要那么大一个板,一个红色按钮就好」——
        // 尺寸得有闸看着,否则下次改布局悄悄涨回去没人知道
        check(p.frame.width <= 40 && p.frame.height <= 40,
              "是个小红点不是一块板（\(Int(p.frame.width))×\(Int(p.frame.height))pt）")
        check((p.contentView?.toolTip ?? "").contains("这条不对"),
              "详情挪进了悬停提示（不占地方,要看才看）")
        // ⚠ 没有辅助功能权限时拿不到插入点 → 必须**降级到底部居中**而不是崩、也不是回屏角
        check(p.frame.height > 0 && p.frame.width > 0, "拿不到插入点也能定位（本进程 AX=\(AXIsProcessTrusted())，已走降级路径）")
    }

    if bad > 0 { print("✗ selftest-hud: \(bad) 项不过"); exit(1) }
    print("✓ selftest-hud: 浮层不抢焦点 · 否决只写候选队列不碰词表")
    print("  ⚠ 未断言:双击热键判定需要真实按键 + 辅助功能权限,只能人按一次")
    exit(0)
}

if CommandLine.arguments.contains("--selftest-boundary") {
    // 词边界护栏的判据（方案 C · 作者 2026-07-26 拍 Q8甲）。
    // 正例来源 = 真实语料里**实测的那 4 次误伤**（独立复核找到、我复现过），不是我编的。
    let rules = loadDict()
    var bad = 0
    func chk(_ label: String, _ input: String, _ want: String) {
        let got = applyDict(input, rules).0
        if got != want { print("✗ \(label): \(input) → \(got)（应为 \(want)）"); bad += 1 }
    }

    // ① 必须**不再**吃掉更长的真词 —— 这四条是 语料库 语料里的真实上下文
    chk("嵌入真词-1", "Let me edit the proposed content", "Let me edit the proposed content")
    chk("嵌入真词-2", "open the proposed plan in your default", "open the proposed plan in your default")
    chk("嵌入真词-3", "show you the proposed changes", "show you the proposed changes")
    // ② 但**仍然要**修独立出现的那一形态（否则护栏等于把规则废了）
    chk("独立命中", "把这个component the propose改成optional",
        "把这个component 的 props改成optional")
    // ③ 右边缘是 ASCII 的模式不得在更长词里开火
    chk("右边界", "这个不要推 mining 的数据", "这个不要推 mining 的数据")
    chk("右边界-该中", "这个不要推 min 也不要开 PR", "这个不要推 main 也不要开 PR")
    // ④ 左边缘是 ASCII 的模式不得被前缀吞进去
    chk("左边界", "recheked 过了", "recheked 过了")
    chk("左边界-该中", "chek 过了", "check 过了")
    // ⑤ 中文模式**仍是无条件替换** —— 这是方法上限,如实钉住,不假装修好了
    chk("中文无边界(已知上限)", "克星规访华", "克星轨访华")

    if bad == 0 {
        print("✓ selftest-boundary: 词边界护栏生效 —— 嵌入真词不再误伤、独立命中仍修")
        print("  ⚠ 已钉住的方法上限:中文模式仍无条件替换（`克星规`→`克星轨`）——")
        print("     中文没有词边界,没有分词就判不了。缓解靠第 9 项报基率（独立语料实测 0 次）。")
        exit(0)
    }
    print("✗ selftest-boundary: \(bad) 项不过")
    exit(1)
}

if CommandLine.arguments.contains("--selftest-canon") {
    // 拼音层的判据。⛔ 必须走本二进制而不是在 check.sh 里用 Python 重写一遍 ——
    // 拼音来自 macOS 的 CFStringTransform,Python 拿不到它,重写就是重写一个**不同的东西**。
    //
    // ⚠ 本项**不断言"拼音层不误伤"** —— 2026-07-26 对抗判卷证伪了那个说法。测的是四件:
    // 回退状态还在 / 机制本身正确 / 已知固有局限没有被悄悄改掉 / fail-open。
    var bad = 0
    let inline = [(term: "甲项目", key: pinyinOf("甲项目"))]   // 用内联表测机制,不依赖出厂表内容

    // ① ⛔ 出厂状态:canon.json 必须为空。
    //    依据:设计档 §5.5 的否决条件「canon 化后出现新误伤 → 回退字面层」**已于 2026-07-26 触发**
    //    (实测 青悟冰淇淋 → 甲项目淋,而字面表不会误伤它)。回退是 作者 拍过的预定动作,
    //    不是我的裁量。要重新启用必须先有 作者 的新 verdict —— 故由闸把它钉住,而不是靠记得。
    let shipped = loadCanon()
    if !shipped.isEmpty {
        print("✗ canon.json 非空(\(shipped.map { $0.term }))—— 否决条件已触发过,重新启用需 作者 新 verdict")
        bad += 1
    }

    // ② ≥3 汉字门槛的谓词本身有效(门槛是代码强制的,不是注释里的承诺)
    if "星轨".count >= kCanonMinHan { print("✗ 门槛失效:2 字词竟满足 kCanonMinHan=\(kCanonMinHan)"); bad += 1 }

    // ③ 机制正确:R3 实测错例(来源 语料库 _评测集 §R3,非私有语料)。
    //    一条 canon 覆盖 5 种错法 —— 这是方案 B 的机制本体,与它该不该启用是两件事。
    let pos = ["甲项目", "甲项目", "甲项目", "甲项目", "甲项目"]
    for s in pos where applyCanon(s, inline).0 != "甲项目" {
        print("✗ 机制失效:\(s) → \(applyCanon(s, inline).0)（应为 甲项目）"); bad += 1
    }

    // ④ ⛔ 已知固有局限,**钉住不许静默漂移**:拼音键在字数相同的更长词内部照样命中。
    //    「青悟冰淇」(jiaxiangmu) 与「甲项目」拼音完全相同 —— 没有分词就无法区分,
    //    这是本方法的固有上限,不是可以修的 bug。若哪天这条断言变红,说明有人改了行为 → 去更新设计档。
    let lim = applyCanon("青悟冰淇淋", inline).0
    if lim != "甲项目淋" { print("✗ 已知局限的行为变了:青悟冰淇淋 → \(lim)（原为 甲项目淋）→ 请同步更新设计档 §11"); bad += 1 }

    // ⑤ 多音字:两类都钉住(2026-07-26 对抗判卷发现,原设计档只写了"未验")
    //    类① 真同音却键不同 → B 的"自动泛化"在多音字上**静默失效**
    if pinyinOf("长盾") == pinyinOf("常盾") { print("✗ 多音字类①行为变了:长盾/常盾 现在同键了"); bad += 1 }
    //    类② 不同音却键相同 → 新误伤类别
    if pinyinOf("长盾") != pinyinOf("涨盾") { print("✗ 多音字类②行为变了:长盾/涨盾 现在不同键了"); bad += 1 }

    // ⑥ fail-open:空表必须原样返回,绝不能吞掉转写结果
    if applyCanon("甲项目", []).0 != "甲项目" { print("✗ 空 canon 未 fail-open"); bad += 1 }

    if bad == 0 {
        print("✓ selftest-canon: 出厂已回退(canon 空) · 机制 \(pos.count)/\(pos.count) 正确 · 门槛在 · fail-open 在")
        print("  ⚠ 已钉住的固有局限:青悟冰淇淋 → 甲项目淋（同字数更长词内部照样命中,无分词无法区分）")
        print("  ⚠ 已钉住的多音字行为:长盾≠常盾（真同音却泛化失效）· 长盾==涨盾（不同音却同键）")
        print("  ⛔ 本项**不证明**拼音层不误伤 —— 那个说法已于 2026-07-26 被对抗判卷证伪。")
        exit(0)
    }
    print("✗ selftest-canon: \(bad) 项不过")
    exit(1)
}

// 单实例锁 —— 跑两份会双注册热键:按一次录两次、转两次、粘两次,且没有任何报错。
// 2026-07-25 实测踩到:冒烟测试的孤儿进程活了 7.5 小时,与 作者 手动起的那份并存。
// ⛔ 不能用 temporaryDirectory —— 它读 TMPDIR，而 launchd 启动的进程与终端里的进程
// TMPDIR 不同 → 两边各拿各的锁文件、互相看不见，锁在「常驻 + 手动混跑」这个最需要它的
// 场景下正好失效。2026-07-25 由 check.sh 第 6 项当场抓出。改用固定路径。
let lockDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/tingzhe")
try? FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
let lockPath = lockDir.appendingPathComponent("instance.lock").path
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    log("✗ 已有一个 tingzhe 在跑(锁 \(lockPath))。先退掉那个再启动,别同时跑两份。")
    exit(1)
}

_ = Controller.shared          // 提前校验 key/词表,缺了就立刻退出而不是按下才发现
installHotKey()
// ⛔⛔ 2026-07-28 作者 抓「麦克风图标根本没有，快捷键也启动不了」——两个症状一个根因:
// 它们**都在 `app.run()` 之前**建。AppKit 里 NSStatusItem 在 app 还没启动完时创建
// 经常**静默不出现**;Carbon 事件处理器同理,事件循环还没起来就装,收不到事件。
// ⇒ 推迟到主 run loop 的第一趟(即 app.run() 已经开始跑之后)再装。
DispatchQueue.main.async {
    installVoiceToggleHotKey()
    StatusBar.shared.install()   // 作者 2026-07-28 要的「明显的开关」
}
// ⛔ 每 2 秒跟状态位对一次账。理由不是洁癖:状态位是跨进程的,别的东西(闸/脚本/手动 rm)
// 改了它而常驻不知道,就会出现「文件说关、麦还开着且点开关也关不掉」——
// 2026-07-28 作者 被卡住的正是这个。**对账让"关不掉"这件事在 2 秒内自愈。**
Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in VoiceLoop.shared.reconcile() }

// ⛔ 没权限时**主动向系统申请**，而不是叫用户自己去列表里拖文件。
// 2026-07-25 踩过的坑：让 作者 手动添加 tingzhe.app 试了两轮都不生效，且无从诊断
// （TCC.db 受 SIP 保护读不了，条目对不对、开关开没开、哈希匹不匹配全是黑盒）。
// AXIsProcessTrustedWithOptions 带 prompt 会弹系统对话框，并由**系统自己**把当前
// 进程加进辅助功能列表 —— 系统加的条目必然匹配，绕开所有"加错了"的可能。
if !AXIsProcessTrusted() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let granted = AXIsProcessTrustedWithOptions(opts)
    log("已向系统申请辅助功能权限（弹窗可能在其它桌面/被窗口挡住）。当前 trusted=\(granted)")
    log("  在弹窗里点「打开系统设置」→ 勾上 tingzhe → 然后重跑 ./install-agent.sh install")
}

log("就绪。说话时按住热键,松开出字。Ctrl-C 退出。")
if !AXIsProcessTrusted() {
    log("⚠ 未授辅助功能权限 → 转写结果只放剪贴板(需自己 ⌘V)。")
    log("  想要自动粘贴 + 单键热键: 系统设置 → 隐私与安全性 → 辅助功能 → 加入 tingzhe.app")
}
app.run()
