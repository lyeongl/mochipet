import AppKit

// MochiPet: Claude Code 세션마다 펫 하나를 띄운다.
// 세션 파일 <데이터 폴더>/<세션 id> 는 여섯 줄이다 (데이터 폴더는 아래 dir). 훅이 한 번 돌고 나면 일곱째 줄에 세션 기록 파일의 경로가 붙는다:
//   상태(idle·working·waiting·done), 작업 폴더, 데스크톱 세션 id(터미널에서 켰으면 그 터미널 앱의 번들 id), 색(색상환 위치 0~1. 비어 있으면 그 종류의 기본 색), 이름, 종류
//
//   --on [--name 이름]   펫을 켠다                 (이 다섯은 /pet 스킬이 부른다.
//   --off                펫을 끈다                  세션 id 는 Claude Code 가 주는 환경변수에서 읽는다)
//   --color [색]         색을 바꾼다. 색을 안 주면 지금 색만 빼고 무작위로 고르고, default 를 주면 기본 색으로 돌아간다
//   --name 이름          이름표를 바꾼다
//   --kind 종류          펫 종류를 바꾼다 (bunny, dog, cat)
//   --hook <상태>        Claude Code 훅이 부른다. 훅 JSON 을 stdin 으로 받는다
//                        (end 는 세션 파일을 지우고, resume 은 waiting 일 때만 working 으로 되돌린다)
//   --gallery <폴더>     문서에 넣을 그림과 GIF 를 뽑는다 (./build.sh gallery 가 부른다)
//   인자 없음             펫 앱으로 뜬다. 세션 파일이 하나도 없으면 바로 끝난다

let fm = FileManager.default
let args = CommandLine.arguments
let env = ProcessInfo.processInfo.environment
// 세션 파일과 설정을 두는 폴더: 이 플러그인의 데이터 폴더다. 플러그인을 지우면 Claude Code 가 이 폴더도 같이 지운다.
// 폴더 이름은 문서에 적힌 규칙(<플러그인>-<마켓>)대로 고정해서 적는다. 훅이 받는 CLAUDE_PLUGIN_DATA 를 쓰지 않는 이유:
// /pet 스킬과 펫 앱에는 그 값이 안 들어와서 따로 넘겨야 하는데, 하나라도 빠지면 훅·스킬·앱이 서로 다른 폴더를 봐서 펫이 안 뜨거나 상태가 안 바뀐다
let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/plugins/data/mochipet-mochipet")
// 설정(투명도, 크기, 날지 않기, 랜덤)은 같은 폴더의 settings.plist 에 둔다. 이름에 점이 있어서 세션 파일로 읽히지 않는다 (safe)
let settingsFile = dir.appendingPathComponent("settings.plist")
func setting(_ key: String) -> Any? { NSDictionary(contentsOf: settingsFile)?[key] }
func setSetting(_ key: String, _ value: Any) {
    let all = NSMutableDictionary(dictionary: NSDictionary(contentsOf: settingsFile) ?? [:])
    all[key] = value
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    all.write(to: settingsFile, atomically: true)
}
// 켜져 있는 펫들의 세션 파일
func sessionFiles() -> [URL] { ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { safe($0.lastPathComponent) } }
var portraits: [String: NSImage] = [:]              // 잘라 둔 얼굴 그림 (portrait)
// 위아래 둘은 판(Bar, Card)이 쓴다. 그림만 뽑을 때(--gallery)와 selftest 가 앱이 뜨기 전에 쓰므로 맨 위에 둔다
let stateDots: [String: NSColor] = ["waiting": .systemOrange, "working": .systemBlue, "done": .systemGreen]

// 세션 id 를 파일 이름이나 URL 에 쓰기 전에 걸러낸다.
func safe(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 80 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
}
func file(_ id: String) -> URL? { safe(id) ? dir.appendingPathComponent(id) : nil }

// 세션 파일을 여섯 줄로 읽는다. 파일이 없으면 nil.
func readSession(_ f: URL) -> [String]? {
    guard let s = try? String(contentsOf: f, encoding: .utf8) else { return nil }
    let l = s.components(separatedBy: "\n")
    return l + Array(repeating: "", count: max(0, 6 - l.count))
}
// 상태(첫 줄)가 그대로면 파일의 수정 시각도 그대로 둔다. 수정 시각을 "지금 상태가 된 시각"으로 쓰기 때문이다 (판의 지난 시간, 끝난 뒤 확인했는지).
// 그래야 색이나 이름을 바꿔도 지난 시간이 0 으로 돌아가지 않는다
func writeSession(_ f: URL, _ lines: [String]) {
    let since = readSession(f)?[0] == lines[0] ? (try? fm.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date : nil
    try? lines.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
    if let since = since { try? fm.setAttributes([.modificationDate: since], ofItemAtPath: f.path) }
}
// 세션 줄들의 종류를 바꾼다. 새 종류에 없는 무늬였으면 기본 색으로 돌린다
func kinded(_ l: [String], _ k: String) -> [String] {
    var l = l
    l[5] = k
    if Double(l[3]) == nil, coatName(l[3], kind: k) == nil { l[3] = "" }
    return l
}
func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
    return args[i + 1]
}

// 이름 붙은 색: 영어 이름, 한글 이름, OKLCH 색상환 각도 (Pet.swift 의 oklch 참고). 우클릭 메뉴의 "색" 도 이 순서로 나온다
let colors: [(en: String, ko: String, degrees: Double)] = [
    ("red", "빨강", 25), ("orange", "주황", 60), ("yellow", "노랑", 100), ("green", "초록", 145),
    ("blue", "파랑", 250), ("purple", "보라", 300), ("pink", "분홍", 350),
]
let colorNames = Dictionary(uniqueKeysWithValues: colors.flatMap { [($0.en, $0.degrees), ($0.ko, $0.degrees)] })   // 색 이름 → 각도

// 색을 정하지 않았을 때 그 종류가 입는 무늬. 색 줄이 비어 있으면 이 무늬다
let defaultCoat = ["bunny": "white", "dog": "golden", "cat": "siamese"]
// 무작위로 뽑을 때 컬러 줄을 먼저 볼지. 메뉴 막대 아이콘의 "랜덤" 에서 고른다. 펫 앱과 /pet 명령이 같은 설정을 읽는다
var colorFirst: Bool { setting("colorFirst") as? Bool ?? false }

// 무작위로 색 줄을 뽑는다. 후보는 두 줄 가운데 고른 한 줄이다: 무늬 줄(그 종류가 쓰는 이름 있는 색. Pet.swift 의 coats)이나 컬러 줄(흰색, 이름 붙은 색상환 색, 크림). 흰색과 크림은 두 줄에 다 있는데, 컬러 줄의 흰색(plain)과 크림(색상환 색 creamHue)은 볼터치가 없다.
// 그 줄에서 다른 펫이 가장 덜 쓰는 것 중에 고른다. 그래서 안 쓰인 것이 먼저 나오고, 다 쓰인 뒤에야 겹친다. 다른 줄로는 넘어가지 않는다
func randomLook(kind: String, used: [String], colorFirst: Bool) -> String {
    let kind = kind.isEmpty ? defaultKind : kind
    let line = colorFirst ? ["plain"] + colors.map { String($0.degrees / 360) } + [String(creamHue)] : coats.filter { wears(kind, $0) }.map(\.en)
    let count = { (look: String) in used.filter { $0 == look }.count }, least = line.map(count).min()!
    let pick = line.filter { count($0) == least }.randomElement()!
    return pick == defaultCoat[kind] ? "" : pick          // 기본 무늬는 빈 줄로 적는다
}

// 새로 켜는 펫의 종류를 무작위로 뽑는다. 다른 펫들이 가장 덜 고른 종류 중에 고른다. 종류를 안 정한 옛 세션은 기본 종류로 센다
func randomKind(used: [String]) -> String {
    let count = { (kind: String) in used.filter { ($0.isEmpty ? defaultKind : $0) == kind }.count }, least = builtinKinds.map(count).min()!
    return builtinKinds.filter { count($0) == least }.randomElement()!
}

// 색 줄이 나타내는 색의 이름. 비어 있으면(기본 색) 그 종류의 기본 무늬 이름이고, 옛 이름은 지금 이름으로 바꾼다
func lookName(_ line: String, kind: String) -> String {
    line.isEmpty ? defaultCoat[kind.isEmpty ? defaultKind : kind] ?? "" : coatAlias[line] ?? line
}

// 세션들의 색을 모두 다시 뽑는다 (메뉴 막대 아이콘의 "모두 색 섞기"). 종류는 그대로 두고, 앞에서 뽑은 색과 겹치지 않게 차례로 뽑는다
func reshuffled(_ sessions: [[String]], colorFirst: Bool) -> [[String]] {
    var used: [String] = []
    return sessions.map { l in
        var l = l
        l[3] = randomLook(kind: l[5], used: used, colorFirst: colorFirst)
        used.append(lookName(l[3], kind: l[5]))
        return l
    }
}

// 고른 색을 세션 파일의 색 줄로 바꾼다. 색 이름이나 0~360 숫자는 색상환 위치(0~1)로, default 는 빈 줄(기본 색)로 바꾸고,
// 색을 안 주면 그 줄에서 지금 색만 빼고 무작위로 뽑는다. 다른 펫이 쓰는 색인지는 보지 않는다 (그건 처음 켤 때와 모두 색 섞기만 본다). 모르는 색이면 nil
func hueLine(_ want: String?, kind: String = "", except me: URL) -> String? {
    guard let want else { return randomLook(kind: kind, used: readSession(me).map { [lookName($0[3], kind: $0[5])] } ?? [], colorFirst: colorFirst) }
    if want == "default" || want == "기본" { return "" }
    guard let degrees = colorNames[want] ?? Double(want) else { return nil }
    return String((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360)
}

// 무늬 이름(영어나 한글)을 그 종류의 무늬로 바꾼다. 그 종류에 없는 무늬면 nil. 무늬는 세션 파일의 색 줄에 숫자 대신 이름으로 적는다
func coatName(_ want: String?, kind: String) -> String? {
    let want = want.map { coatAlias[$0] ?? $0 }
    return coats.first { ($0.en == want || $0.ko == want) && wears(kind.isEmpty ? defaultKind : kind, $0) }?.en
}

if args.contains("--selftest") {
    selftest()
    precondition(coatName("얼룩", kind: "cat") == "patch" && coatName("calico", kind: "cat") == "patch" && coatName("patch", kind: "dog") == "patch" && coatName("pink", kind: "cat") == nil
                 && coatName("흰색", kind: "dog") == "white" && colorNames["mint"] == nil
                 && coatName("더치", kind: "") == "patch" && coatName("회색", kind: "cat") == "gray" && coatName("pug", kind: "dog") == "pug"
                 && coatName("크림", kind: "cat") == "cream" && coatName("은회색", kind: "dog") == "silver" && coatName("pug", kind: "cat") == nil
                 && coatName("골든", kind: "cat") == "golden" && coatName("siamese", kind: "dog") == nil
                 && coatName("시바", kind: "dog") == "shiba" && coatName("golden", kind: "bunny") == "golden", "이름으로 고르는 색이 틀림")
    precondition(host(["CLAUDE_CODE_HOST_SESSION_ID": "local_a", "__CFBundleIdentifier": "com.apple.Terminal"]) == "local_a"
                 && host(["__CFBundleIdentifier": "com.googlecode.iterm2"]) == "com.googlecode.iterm2"
                 && host(["__CFBundleIdentifier": "a b.c"]) == "" && host([:]) == "", "세션을 켠 곳을 잘못 적음")
    precondition(sameTitle("✳ test2", "test2") && sameTitle("test2", "test2") && !sameTitle("✳ test2", "test") && !sameTitle("✳ ", ""), "창 제목 견주기가 틀림")
    korean = true
    let tmp = fm.temporaryDirectory.appendingPathComponent("mochipet-selftest-\(getpid())"), old = Date(timeIntervalSince1970: 1_000_000)
    writeSession(tmp, ["working", "/", "", "", "", ""]); try? fm.setAttributes([.modificationDate: old], ofItemAtPath: tmp.path)
    func stamp() -> Date { (try? fm.attributesOfItem(atPath: tmp.path))?[.modificationDate] as? Date ?? .distantPast }   // URL 은 읽은 값을 기억해 두므로 매번 새로 묻는다
    writeSession(tmp, ["working", "/", "", "shiba", "", "dog"]); let kept = stamp()
    writeSession(tmp, ["done", "/", "", "shiba", "", "dog"]); let moved = stamp()
    try? fm.removeItem(at: tmp)
    precondition(kept == old && moved > old, "색을 바꿨는데 지난 시간이 돌아갔거나, 상태가 바뀌었는데 안 돌아감")
    let t0 = Date(timeIntervalSince1970: 0), rs = ["idle", "done", "waiting", "working"].map { Row(id: $0, name: "a", state: $0, since: t0, kind: "", look: "", host: "") }
    precondition(ago(t0, now: t0 + 45) == "45초" && ago(t0, now: t0 + 125) == "2분" && ago(t0, now: t0 + 7300) == "2시간" && ago(t0, now: t0 - 5) == "0초"
                 && sorted(rs).map(\.state) == ["waiting", "working", "done", "idle"], "메뉴 막대 판의 지난 시간이나 줄 순서가 틀림")
    precondition(hueLine("default", except: dir) == "" && hueLine("분홍", except: dir) == String(350.0 / 360) && hueLine("-90", except: dir) == "0.75"
                 && hueLine("nope", except: dir) == nil && hueLine(nil, except: dir) != nil, "색 줄이 틀림")
    var flier = Pet(pos: .zero); grounded = true; flier.start("fly"); let stayed = flier.name; flier.start("climb"); let low = flier.name; grounded = false; flier.start("balloon")
    let stack = [CGRect(x: 0, y: 300, width: 100, height: 100), CGRect(x: 0, y: 0, width: 200, height: 600)]   // 앞 창이 뒤 창의 가운데를 가린다
    precondition(ledgeAbove(stack, 50, 150, 900) == 400 && ledgeAbove(stack, 150, 150, 900) == 600 && ledgeAbove(stack, 50, 450, 500) == nil
                 && ledgeAbove([stack[1], stack[0]], 50, 150, 900) == 600, "타고 오를 때 매달릴 창 윗변이 틀림")
    precondition(stayed == "idle" && low == "idle" && flier.name == "balloon" && flying.allSatisfy { actions[$0] != nil }, "날지 않기가 틀림")
    let breeds = ["golden", "white", "ivory", "cream", "gray", "silver", "patch", "pug", "shiba"], hues = ["plain"] + colors.map { String($0.degrees / 360) } + [String(creamHue)]
    func dogLook(_ used: [String], _ colorFirst: Bool) -> String { lookName(randomLook(kind: "dog", used: used, colorFirst: colorFirst), kind: "dog") }
    precondition(breeds.contains(dogLook([], false)) && hues.contains(dogLook([], true))
                 && breeds.contains(dogLook(breeds, false)) && hues.contains(dogLook(hues, true))                  // 줄이 다 쓰여도 다른 줄로 넘어가지 않는다
                 && dogLook(breeds + breeds.dropLast(), false) == "shiba" && dogLook(hues.dropLast(), true) == hues.last!   // 가장 덜 쓰인 것이 먼저다
                 && randomLook(kind: "", used: ["white", "ivory", "cream", "patch", "gray", "golden"], colorFirst: false) == "silver" && randomLook(kind: "cat", used: ["white", "ivory", "cream", "gray", "silver", "golden", "patch"], colorFirst: false) == "", "무작위 색이 틀림")
    precondition(randomKind(used: ["bunny", "", "dog"]) == "cat" && builtinKinds.contains(randomKind(used: [])) && randomKind(used: ["dog", "cat", "cat", "dog"]) == "bunny", "무작위 종류가 틀림")
    let before = Array(repeating: ["working", "/", "", "0.5", "이름", "dog"], count: 9), after = reshuffled(before, colorFirst: false)
    precondition(zip(before, after).allSatisfy { $0[5] == $1[5] && $0[4] == $1[4] } && Set(after.map { lookName($0[3], kind: "dog") }) == Set(breeds)
                 && reshuffled(before + before, colorFirst: true).allSatisfy { hues.contains($0[3]) }, "모두 색 섞기가 틀림")
    exit(0)
}
if let out = value(after: "--gallery") { try exportGallery(to: URL(fileURLWithPath: out)); exit(0) }

if let cmd = args.dropFirst().first, ["--on", "--off", "--color", "--name", "--kind"].contains(cmd) {
    guard let f = file(env["CLAUDE_CODE_SESSION_ID"] ?? "") else {
        print(L("CLAUDE_CODE_SESSION_ID 가 없어서 어느 세션인지 알 수 없음", "CLAUDE_CODE_SESSION_ID is not set, so the session is unknown")); exit(1)
    }
    // 끈 세션은 .off 표시를 남긴다. 자동으로 켜기가 다음 프롬프트에 다시 켜지 않게 한다 (이름에 점이 있어서 세션 파일로 읽히지 않는다)
    let off = f.appendingPathExtension("off")
    if cmd == "--off" { try? fm.removeItem(at: f); try? Data().write(to: off); print(L("펫 끔", "Pet off")); exit(0) }
    let name = value(after: "--name").map { String($0.replacingOccurrences(of: "\n", with: " ").prefix(30)) }
    var l = readSession(f)
    if l == nil {
        guard cmd == "--on" else { print(L("이 세션은 펫이 꺼져 있음. /pet on 을 먼저 해야 함", "This session has no pet. Run /pet on first")); exit(1) }
        l = newPet(cwd: fm.currentDirectoryPath)
    }
    if cmd == "--color" {
        let want = value(after: "--color")?.lowercased()
        guard let line = coatName(want, kind: l![5]) ?? hueLine(want, kind: l![5], except: f) else {
            let mine = coats.filter { wears(l![5].isEmpty ? defaultKind : l![5], $0) }.flatMap { [$0.en, $0.ko] }
            let names = (colorNames.keys.sorted() + mine).joined(separator: ", ")
            print(L("모르는 색: \(want!). 이름(\(names), default)이나 0~360 숫자를 쓴다", "Unknown color: \(want!). Use a name (\(names), default) or a number from 0 to 360")); exit(1)
        }
        l![3] = line
    }
    if cmd == "--kind" {
        guard let k = value(after: "--kind"), builtinKinds.contains(k) else {
            print(L("모르는 종류. 쓸 수 있는 것: ", "Unknown kind. Use one of: ") + builtinKinds.joined(separator: ", ")); exit(1)
        }
        l = kinded(l!, k)
    }
    if let n = name { l![4] = n }
    writeSession(f, l!)
    if cmd == "--on" { try? fm.removeItem(at: off); launch() }
    print(["--on": L("펫 켬", "Pet on"), "--color": L("색 바꿈", "Color changed"), "--name": L("이름 바꿈", "Name changed"), "--kind": L("종류 바꿈", "Kind changed")][cmd]!); exit(0)
}

if args.count >= 3, args[1] == "--hook" {
    let j = (try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())) as? [String: Any]
    // 펫을 켠 세션만 건드린다. 훅은 stdout 이 대화에 섞일 수 있어서 아무것도 찍지 않는다.
    guard let f = file(j?["session_id"] as? String ?? "") else { exit(0) }
    let off = f.appendingPathExtension("off")
    if args[2] == "end" { try? fm.removeItem(at: f); try? fm.removeItem(at: off); exit(0) }
    var l: [String]
    if let old = readSession(f) { l = old }
    // 자동으로 켜기: 펫이 없는 세션에 첫 프롬프트가 들어오면 켠다. /pet off 로 끈 세션은 그대로 둔다.
    // 세션이 시작될 때(SessionStart) 켜지 않는 까닭은, 쓰지도 않은 세션에 펫이 생기기 때문이다
    else if args[2] == "working", setting("autoOn") as? Bool == true, !fm.fileExists(atPath: off.path) {
        l = newPet(cwd: j?["cwd"] as? String ?? fm.currentDirectoryPath); launch()
    } else { exit(0) }
    // resume 은 도구가 끝날 때마다 불린다. 승인을 기다리던 중이었을 때만 working 으로 되돌린다.
    if args[2] == "resume" && l[0] != "waiting" { exit(0) }
    l[0] = args[2] == "resume" ? "working" : args[2]
    // 훅이 알려 주는 세션 기록 파일의 경로를 일곱째 줄에 적어 둔다. 펫 앱이 거기서 세션 제목을 읽는다 (transcriptTitle)
    if let t = j?["transcript_path"] as? String, !t.contains("\n") { l = Array(l.prefix(6)) + [t] }
    writeSession(f, l); exit(0)
}

// 새 펫의 세션 파일 줄. 프롬프트를 받은 턴 도중에 켜지므로 working 으로 시작한다
// 종류와 색을 무작위로 정한다. 종류를 먼저 뽑고, 그 종류가 쓰는 색 중에서 색을 뽑는다
// 다른 펫이 입은 색은 이름으로 견준다 (lookName). 기본 색은 종류마다 다른 무늬라서, 빈 줄끼리 같다고 보면 샴 고양이가 있다고 흰 토끼를 못 뽑는다
func newPet(cwd: String) -> [String] {
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let others = sessionFiles().compactMap(readSession), kind = randomKind(used: others.map { $0[5] })
    return ["working", cwd, host(env), randomLook(kind: kind, used: others.map { lookName($0[3], kind: $0[5]) }, colorFirst: colorFirst), "", kind]
}
// 펫 앱이 안 떠 있으면 띄운다 (-g: 앞으로 가져오지 않는다)
func launch() {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", Bundle.main.bundleURL.path]
    try? open.run(); open.waitUntilExit()
}

// 세션 파일 셋째 줄에 적을 값. Claude Desktop에서 켰으면 데스크톱 세션 id 이고,
// 터미널에서 켰으면 그 터미널 앱의 번들 id 다 (앱이 띄운 프로세스에는 macOS 가 __CFBundleIdentifier 를 넣어 준다).
func host(_ env: [String: String]) -> String {
    if let s = env["CLAUDE_CODE_HOST_SESSION_ID"] { return s }
    let app = env["__CFBundleIdentifier"] ?? ""
    return app.contains(".") && app.count <= 100 && app.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) } ? app : ""
}

// 펫을 누르면 그 세션의 Claude Desktop 채팅을 연다. 터미널에서 켠 펫은 그 터미널 앱을 앞으로 가져온다.
// 손쉬운 사용 권한이 있으면 그 세션의 창까지 찾아서 앞으로 가져온다 (raiseWindow).
// 세션을 지정하는 링크는 문서에 없다. Claude Desktop 4.23118.1 의 URL 처리 코드에서 확인한 형식이라 버전이 바뀌면 안 열릴 수 있다.
let claudeApp = "com.anthropic.claudefordesktop"   // Claude Desktop의 번들 id
func openChat(_ host: String, title: String?) {
    if host.hasPrefix("local_"), safe(host), let link = URL(string: "claude://code/continue?session=\(host)") {
        NSWorkspace.shared.open(link)
    } else if host.contains("."), let title, raiseWindow(host, titled: title) {
    } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: host.contains(".") ? host : claudeApp) {   // 설치된 위치가 어디든 찾아서 연다
        NSWorkspace.shared.open(app)
    }
}

// 터미널 앱의 창 가운데 제목이 세션 제목인 창을 앞으로 가져온다. 그 창이 다른 화면(스페이스)에 있으면 그 화면으로 넘어간다. 가져왔으면 true.
// 앱의 메뉴에서 그 창의 항목을 찾아 누른다. 창 목록(AXWindows)에는 지금 화면의 창만 나오지만, 윈도우 메뉴에는 다른 화면의 창도 다 나오기 때문이다.
// 손쉬운 사용 권한이 필요하다. 없으면 앱만 앞으로 온다. 앱을 다시 빌드하면 권한을 다시 줘야 한다.
// ponytail: 창 제목만 견준다. 한 창을 여러 칸으로 나눠 쓰면 제목이 지금 고른 칸의 것이라서, 다른 칸의 세션은 못 찾고 앱만 앞으로 온다
func raiseWindow(_ bundle: String, titled title: String) -> Bool {
    if !AXIsProcessTrusted() {                 // 권한은 처음 한 번만 묻는다. 누를 때마다 물으면 창이 계속 뜬다
        if setting("askedAccess") == nil { setSetting("askedAccess", true); _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
        return false
    }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return false }
    func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v }
    func kids(_ e: AXUIElement) -> [AXUIElement] { attr(e, "AXChildren") as? [AXUIElement] ?? [] }
    guard let bar = attr(AXUIElementCreateApplication(app.processIdentifier), "AXMenuBar"),
          let item = kids(bar as! AXUIElement).flatMap(kids).flatMap(kids).first(where: { sameTitle(attr($0, "AXTitle") as? String ?? "", title) }) else { return false }
    AXUIElementPerformAction(item, "AXPress" as CFString)
    app.activate()
    return true
}
// Claude Code 는 터미널 창 제목을 "✳ 세션 제목" 처럼 기호 하나와 빈칸을 앞에 붙여서 적는다 (2.1.301, Ghostty 1.3.1 에서 확인)
func sameTitle(_ window: String, _ title: String) -> Bool { !title.isEmpty && (window == title || window.dropFirst(2) == title) }

// 끝난 세션을 확인했으면(펫을 눌렀거나 Claude Desktop에서 열어 봤으면) 평소 행동으로 돌려보낸다.
// 파일에 적어 두므로 펫 앱을 다시 띄워도 다시 알리지 않는다.
func acknowledge(_ id: String) {
    guard let f = file(id), var l = readSession(f), l[0] == "done" else { return }
    l[0] = "idle"
    writeSession(f, l)
}

// Claude Desktop은 세션마다 파일 하나에 제목과 마지막으로 연 시각을 적어 둔다.
// 문서에 없는 형식이다(4.23118.1 에서 확인). 못 읽으면 제목은 폴더 이름으로, 확인은 펫 클릭과 다음 프롬프트로만 된다.
let desktopDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")

func desktopFiles() -> [URL] {      // <계정>/<조직>/local_….json
    let children = { (u: URL) in (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }
    return children(desktopDir).flatMap(children).flatMap(children).filter { $0.pathExtension == "json" }
}
func modified(_ u: URL) -> Date {
    (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
}

final class Sessions: NSObject {
    var pets: [String: PetView] = [:]
    var shown: [String: [String]] = [:]   // 펫에 반영해 둔 세션 파일 내용
    var titles: [String: String] = [:]    // Claude Desktop의 세션 제목
    var names: [String: String] = [:]     // 자르지 않은 세션 이름. 판과 띄운 창의 목록이 쓴다
    var gone: [String: Int] = [:]         // 데스크톱 세션 파일이 연달아 안 보인 횟수
    var transcripts: [String: (path: String, at: Date, title: String?)] = [:]   // 터미널 세션의 기록 파일과 거기서 읽어 둔 제목

    // 터미널(CLI) 세션의 제목. Claude Code 는 세션 기록(~/.claude/projects/<폴더>/<세션 id>.jsonl)에 /rename 으로 붙인 이름(custom-title)과
    // 스스로 붙인 이름(ai-title)을 한 줄씩 적어 둔다. 문서에 없는 형식이다 (2.1.301 에서 확인). 못 읽으면 이름표는 폴더 이름이 된다.
    // 기록은 수백 MB 가 되기도 해서 끝의 256KB 만 읽는다. 제목 줄은 자주 다시 적혀서 끝에 있다. 파일이 바뀌었을 때만 다시 읽는다
    func transcriptTitle(_ id: String, _ l: [String]) -> String? {
        // 기록 파일의 경로는 훅이 세션 파일 일곱째 줄에 적어 준다. 아직 훅이 한 번도 안 돌았으면 기본 위치에서 찾아본다
        let known = l.count > 6 && !l[6].isEmpty ? l[6] : nil
        if transcripts[id] == nil || (known != nil && transcripts[id]!.path != known) {
            let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            let found = known ?? ((try? fm.contentsOfDirectory(atPath: projects.path)) ?? []).map { projects.appendingPathComponent($0).appendingPathComponent(id + ".jsonl").path }.first { fm.fileExists(atPath: $0) }
            guard let path = found else { return nil }
            transcripts[id] = (path, .distantPast, nil)
        }
        let t = transcripts[id]!, at = (try? fm.attributesOfItem(atPath: t.path))?[.modificationDate] as? Date ?? .distantPast
        guard at != t.at, let h = FileHandle(forReadingAtPath: t.path) else { return t.title }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        var custom: String?, ai: String?
        for line in String(decoding: h.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n") where line.contains("-title\"") {
            guard let j = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if let c = j["customTitle"] as? String, !c.isEmpty { custom = c }
            if let a = j["aiTitle"] as? String, !a.isEmpty { ai = a }
        }
        let title = custom ?? ai ?? t.title      // 끝에서 못 찾았으면 전에 읽은 제목을 그대로 둔다
        transcripts[id] = (t.path, at, title)
        return title
    }
    var front: (app: String?, since: Date) = (nil, .distantPast)   // 지금 맨 앞에 있는 앱과 그 앱이 앞으로 온 시각
    var desktop: [URL: (at: Date, title: String?, focused: Date, archived: Bool)] = [:]   // 읽어 둔 데스크톱 세션 파일. 파일이 바뀌면 다시 읽는다

    // 데스크톱 세션 파일은 수백 KB 라서 바뀌었을 때만 다시 읽는다.
    func readDesktop(_ u: URL) -> (title: String?, focused: Date, archived: Bool)? {
        let at = modified(u)
        if let c = desktop[u], c.at == at { return (c.title, c.focused, c.archived) }
        guard let d = try? Data(contentsOf: u), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        let focused = (j["lastFocusedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        let archived = j["isArchived"] as? Bool ?? false
        desktop[u] = (at, j["title"] as? String, focused, archived)
        return (j["title"] as? String, focused, archived)
    }

    // 가장 최근에 연 세션의 파일. 세션을 열면 그 파일이 다시 쓰이므로, 최근에 바뀐 파일부터 보면 몇 개 안에 끝난다.
    func lastFocused(_ files: [URL]) -> URL? {
        var best: (file: URL, at: Date)?
        for (u, changed) in files.map({ ($0, modified($0)) }).sorted(by: { $0.1 > $1.1 }) {   // 바뀐 시각은 파일마다 한 번만 묻는다
            if let b = best, changed < b.at { break }
            if let at = readDesktop(u)?.focused, at > best?.at ?? .distantPast { best = (u, at) }
        }
        return best?.file
    }

    // ponytail: 0.5초마다 폴더를 다시 읽는다. 세션이 수십 개가 되면 FSEvents 로 바꾼다.
    @objc func sync() {
        let ids = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter(safe)
        for id in ids {
            guard let l = readSession(dir.appendingPathComponent(id)) else { continue }
            if pets[id] == nil {
                let v = makePet()
                v.onClick = { [weak self] in openChat(l[2], title: self?.titles[id]); acknowledge(id) }
                v.onMenu = { [weak v] in if let v = v { card.show(id, at: v) } }
                pets[id] = v
            }
            guard let v = pets[id] else { continue }
            // 이름표: /pet name 으로 정한 이름, 없으면 세션 제목(Claude Desktop 의 제목이나 터미널에서 /rename 으로 붙인 이름), 그것도 없으면 폴더 이름
            let full = !l[4].isEmpty ? l[4] : titles[id] ?? (l[1] as NSString).lastPathComponent
            let label = full.count > 24 ? full.prefix(23) + "…" : full     // 이름표는 24자에서 자른다. 목록은 자르지 않은 이름을 쓴다
            names[id] = full
            if v.label != label { v.label = label }
            guard shown[id] != l else { continue }
            if shown[id]?[0] != l[0] { v.setMood(l[0]) }
            let hue = Double(l[3]).map { CGFloat($0) }
            if v.hue != hue { v.hue = hue }
            let coat = hue == nil ? l[3] : ""                       // 색 줄이 숫자가 아니면 무늬 이름이다
            if v.coat != coat { v.coat = coat }
            let kind = l[5].isEmpty ? defaultKind : l[5]
            if v.kind != kind { v.kind = kind }
            shown[id] = l
        }
        for (id, v) in pets where !ids.contains(id) { v.close(); pets[id] = nil; shown[id] = nil; titles[id] = nil; names[id] = nil; gone[id] = nil; transcripts[id] = nil }
        if pets.isEmpty { NSApp.terminate(nil) }
    }

    // 2초마다: 세션 제목을 가져오고, 끝난 세션을 Claude Desktop에서 열어 봤으면 확인한 것으로 처리한다.
    // 세션을 보관했거나 지웠으면 펫을 끄고 세션 파일을 지운다. 그래야 데이터 폴더에 끝난 세션의 파일이 쌓이지 않는다.
    // 보관 표시(isArchived)도 문서에 없는 값이다 (4.23118.1 에서 확인).
    var deskFiles: [URL] = []             // 지난번에 읽어 둔 Claude Desktop 세션 파일 목록
    @objc func watchDesktop() {
        // 세 겹 폴더를 읽는 데 10ms 넘게 걸려서 뒤쪽 스레드에서 읽고, 이번에는 지난번(2초 전) 목록을 쓴다
        let files = deskFiles
        DispatchQueue.global(qos: .utility).async { let found = desktopFiles(); DispatchQueue.main.async { self.deskFiles = found } }
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if app != front.app { front = (app, Date()) }
        let claudeInFront = app == claudeApp
        for (id, l) in shown {
            guard let u = files.first(where: { $0.lastPathComponent == l[2] + ".json" }) else {
                // 데스크톱에서 연 세션인데 그 파일이 없으면 세션을 지운 것이다. 쓰는 도중이라 잠깐 안 보이는 것일 수 있어서
                // 다섯 번(10초) 연달아 없을 때 끈다. 폴더를 아예 못 읽었을 때(files 가 비었을 때)는 건드리지 않는다
                if l[2].hasPrefix("local_"), !files.isEmpty {
                    gone[id, default: 0] += 1
                    if gone[id]! >= 5, let f = file(id) { try? fm.removeItem(at: f) }
                }
                // 터미널에서 켠 펫: 끝난 뒤에 그 터미널 앱으로 넘어왔으면 본 것이다. 끝날 때 이미 그 앱에 있었으면 펫을 누르거나 다음 프롬프트를 보낼 때까지 축하한다
                if !l[2].hasPrefix("local_") { titles[id] = transcriptTitle(id, l) }
                if l[0] == "done", l[2] == app, let f = file(id), front.since > modified(f) { acknowledge(id) }
                continue
            }
            gone[id] = nil
            guard let me = readDesktop(u) else { continue }
            if me.archived, let f = file(id) { try? fm.removeItem(at: f); continue }   // 다음 sync 에서 펫이 사라진다
            titles[id] = me.title
            guard l[0] == "done", let f = file(id) else { continue }
            let doneAt = modified(f)
            guard Date().timeIntervalSince(doneAt) > 3 else { continue }   // 축하를 한 번은 보여 준다
            // 끝난 뒤에 이 세션을 열었거나, 지금 Claude 가 맨 앞이고 마지막으로 연 세션이 이 세션이면 본 것이다
            if me.focused > doneAt || (claudeInFront && lastFocused(files) == u) { acknowledge(id) }
        }
    }
}

// 펫 한 마리를 바꾸는 일들. 우클릭 판(Card)과 메뉴 막대 판(Bar)이 같이 쓴다. 세션 파일에 적으면 다음 sync 에서 펫에 입혀진다
// 색 줄에 적을 값을 적는다 (우클릭 판의 칸을 눌렀을 때). line 을 안 주면 무작위로 뽑는다 (색 섞기)
func setLook(_ id: String, _ line: String? = nil) {
    guard let f = file(id), var now = readSession(f), let to = line ?? hueLine(nil, kind: now[5], except: f) else { return }
    now[3] = to; writeSession(f, now)
}
func setKind(_ id: String, _ k: String) { if let f = file(id), let now = readSession(f) { writeSession(f, kinded(now, k)) } }
func petOff(_ id: String) { if let f = file(id) { try? fm.removeItem(at: f) } }

// 펫 그림에서 빈 둘레를 잘라 낸 얼굴 그림. 목록과 색 고르는 칸에서 칸 가운데에 꽉 차게 보이게 한다
func portrait(kind: String, coat: String, hue: CGFloat?) -> NSImage {
    let key = "\(kind)|\(coat)|\(hue ?? -1)"
    if let p = portraits[key] { return p }
    let img = drawn("idle_0", hue: hue, kind: kind, coat: coat)
    guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return img }
    // 알파만 8비트로 다시 그려서 바이트를 바로 읽는다. 픽셀마다 색을 묻는 것보다 훨씬 빠르다
    let w = cg.width, h = cg.height
    var alpha = [UInt8](repeating: 0, count: w * h)
    guard let ctx = CGContext(data: &alpha, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return img }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var x0 = w, x1 = -1, y0 = h, y1 = -1
    for y in 0..<h { for x in 0..<w where alpha[y * w + x] > 12 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
    guard x1 >= x0, let cut = cg.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)) else { return img }
    let p = NSImage(cgImage: cut, size: NSSize(width: cut.width, height: cut.height))
    portraits[key] = p
    return p
}

// 앱 아이콘: 연한 분홍 둥근 네모 안에서 아이보리 토끼가 아래에서 빼꼼 내다본다. 메뉴 막대 판의 머리말과 README 에 쓴다
func appIcon(_ side: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: side, height: side), flipped: false) { box in
        NSBezierPath(roundedRect: box, xRadius: side * 0.23, yRadius: side * 0.23).addClip()
        backdrop.setFill(); box.fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        drawn("idle_0", kind: "bunny", coat: "ivory").draw(in: NSRect(x: -0.16 * side, y: -0.254 * side, width: 1.32 * side, height: 1.32 * side))
        return true
    }
}

// 펫 우클릭 판: 머리말(얼굴, 이름, 상태), 종류, 무늬, 컬러, 색 섞기, 이 펫 끄기. 메뉴 막대 판과 같은 모양으로 그린다
final class Card: NSObject, NSPopoverDelegate {
    let pop = NSPopover()
    var id = ""

    // 판을 그 펫의 지금 상태로 만든다. 무늬는 그 종류가 쓰는 것만 그 종류의 얼굴로 보여 준다
    func view(for r: Row) -> NSView {
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(equalToConstant: 300).isActive = true
        func add(_ v: NSView) { root.addArrangedSubview(v); v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28).isActive = true }
        func rule() { let b = NSBox(); b.boxType = .separator; add(b) }
        func face(_ pt: CGFloat, coat: String, hue: CGFloat?) -> NSImageView {
            let v = NSImageView(image: portrait(kind: r.kind, coat: coat, hue: hue))
            NSLayoutConstraint.activate([v.widthAnchor.constraint(equalToConstant: pt), v.heightAnchor.constraint(equalToConstant: pt)])
            return v
        }

        let state = bar.text(stateName(r.state) + " · " + ago(r.since), 12, gray: true)
        let names = NSStackView(views: [bar.text(r.name, 14, .bold), state]); names.orientation = .vertical; names.alignment = .leading; names.spacing = 1
        let head = NSStackView(views: [face(40, coat: r.coat, hue: r.hue), names]); head.spacing = 10
        add(head); rule()

        let kinds = NSSegmentedControl(labels: [L("토끼", "Bunny"), L("강아지", "Dog"), L("고양이", "Cat")], trackingMode: .selectOne, target: self, action: #selector(pickKind(_:)))
        kinds.selectedSegment = builtinKinds.firstIndex(of: r.kind) ?? 0
        add(bar.line(bar.text(L("종류", "Kind")), kinds))

        // 한 줄에 다섯 칸. 칸마다 얼굴과 이름을 두고, 지금 색인 칸에 테두리를 두른다
        func grid(_ title: String, _ items: [(name: String, line: String)]) {     // line 은 세션 파일의 색 줄에 적을 값이다
            add(bar.text(title, 11.5, gray: true))
            for start in stride(from: 0, to: items.count, by: 5) {
                let cells: [NSView] = (start..<start + 5).map { i in
                    guard i < items.count else { return NSView() }
                    let it = items[i], on = lookName(r.look, kind: r.kind) == it.line
                    let name = bar.text(it.name, 10, gray: true); name.alignment = .center
                    if on { name.textColor = .controlAccentColor }
                    let col = NSStackView(views: [face(46, coat: Double(it.line) == nil ? it.line : "", hue: Double(it.line).map { CGFloat($0) }), name]); col.orientation = .vertical; col.spacing = 4
                    let cell = RowView(); cell.wantsLayer = true; cell.layer?.cornerRadius = 8
                    if on { cell.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.13).cgColor; cell.layer?.borderColor = NSColor.controlAccentColor.cgColor; cell.layer?.borderWidth = 1.5 }
                    cell.addSubview(col); col.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([col.centerXAnchor.constraint(equalTo: cell.centerXAnchor), col.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
                                                 col.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -5)])
                    cell.onClick = { [weak self] in setLook(r.id, it.line); self?.reload() }
                    return cell
                }
                let row = NSStackView(views: cells); row.distribution = .fillEqually; row.spacing = 2
                add(row)
            }
        }
        // README 의 색상 그림과 같은 순서다. 무늬는 그 종류가 쓰는 것만, 컬러는 흰색, 색상환 색, 크림 순이다
        grid(L("무늬", "Patterns"), coats.filter { wears(r.kind, $0) }.map { (L($0.ko, $0.en.capitalized), $0.en) })
        grid(L("컬러", "Colors"), [(L("흰색", "White"), "plain")] + colors.map { (L($0.ko, $0.en.capitalized), String($0.degrees / 360)) } + [(L("크림", "Cream"), String(creamHue))])
        rule()

        let mix = NSButton(title: L("색 섞기", "Shuffle"), image: bar.symbol("shuffle"), target: self, action: #selector(shuffle))
        let off = NSButton(title: L("이 펫 끄기", "Turn off"), image: bar.symbol("power"), target: self, action: #selector(dismiss))
        for b in [mix, off] { b.imagePosition = .imageLeading; b.bezelStyle = .rounded }
        let buttons = NSStackView(views: [mix, off]); buttons.distribution = .fillEqually; buttons.spacing = 8
        add(buttons)
        return root
    }

    // 판은 펫 자리에 깔아 둔 투명한 창에 붙인다. 펫 창에 바로 붙이면 펫이 걸어갈 때 판이 따라 움직이거나 저절로 닫힌다
    func show(_ id: String, at v: NSView) {
        guard let from = v.window?.frame else { return }
        self.id = id
        guard let r = current() else { return }
        // 펫 창과 똑같은 정사각형이면 다른 펫으로 잘못 알고 이 펫이 옆으로 밀려나므로(screenWindows) 높이를 조금 줄인다
        spot.setFrame(NSRect(x: from.minX, y: from.minY, width: from.width, height: from.height - 2), display: false); spot.orderFrontRegardless()
        held?.paused = false; held = v as? PetView; held?.paused = true
        if pop.contentViewController == nil { let vc = NSViewController(); vc.view = box; pop.contentViewController = vc; pop.animates = false; pop.delegate = self }
        put(r)
        pop.show(relativeTo: spot.contentView!.bounds, of: spot.contentView!, preferredEdge: .maxX)
        NSApp.activate(ignoringOtherApps: true)
        watch()
    }
    lazy var spot: NSPanel = {
        let w = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.ignoresMouseEvents = true; w.level = .floating; w.contentView = NSView()
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]   // 없으면 전체화면 창 위에서는 이 창이 다른 화면에 깔려서 판이 안 보인다
        return w
    }()

    // 판 밖을 누르면 닫는다. 펫 앱은 Dock 에 없는 앱이라 판이 알아서 닫히지 않을 때가 있어서 직접 지켜본다
    var watchers: [Any] = []
    func watch() {
        unwatch()
        let downs: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: downs, handler: { [weak self] _ in self?.pop.close() }) { watchers.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: downs, handler: { [weak self] e in
            if let me = self, e.window != me.pop.contentViewController?.view.window { me.pop.close() }
            return e
        }) { watchers.append(l) }
    }
    func unwatch() { watchers.forEach(NSEvent.removeMonitor); watchers = [] }
    weak var held: PetView?           // 판이 열려 있는 동안 멈춰 둔 펫
    func popoverDidClose(_ n: Notification) { if !pop.isShown { unwatch(); held?.paused = false; held = nil } }

    // 이 펫의 지금 모습을 세션 파일에서 바로 읽는다. 다음 sync 를 기다리지 않아서 누르자마자 판이 바뀐다
    func current() -> Row? { file(id).flatMap(readSession).map { bar.row(id, $0) } }
    func reload() { bar.catchUp(); if pop.isShown, let r = current() { put(r) } }
    // 판의 틀(box)은 그대로 두고 내용만 갈아 끼운다. 판에 얹은 뷰를 통째로 바꾸면 판이 쪼그라든 채로 남는다
    let box = NSView()
    func put(_ r: Row) {
        box.subviews.forEach { $0.removeFromSuperview() }
        let v = view(for: r)
        box.addSubview(v)
        NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: box.topAnchor), v.leadingAnchor.constraint(equalTo: box.leadingAnchor)])
        pop.contentSize = v.fittingSize
    }
    @objc func pickKind(_ c: NSSegmentedControl) { setKind(id, builtinKinds[c.selectedSegment]); reload() }
    @objc func shuffle() { setLook(id); reload() }
    @objc func dismiss() { petOff(id); pop.close(); bar.catchUp() }
}

// 메뉴 막대 아이콘. 누르면 판이 열린다: 세션 목록, 모으기·색 섞기, 날지 않기·모두 숨기기·랜덤, 투명도·크기.
// 투명도, 크기, 날지 않기는 settings.plist 에 남기고, 숨김은 남기지 않는다. 펫이 하나도 없으면 앱이 끝나므로 아이콘도 사라진다.
// 판의 세션 한 줄. since 는 지금 상태가 된 시각이고, host 는 눌렀을 때 열 곳이다 (세션 파일 셋째 줄)
struct Row { var id, name, state: String, since: Date, kind, look: String, host: String    // look 은 세션 파일의 색 줄 (무늬 이름이나 색상환 위치)
    var coat: String { Double(look) == nil ? look : "" }
    var hue: CGFloat? { Double(look).map { CGFloat($0) } }
}
func ago(_ since: Date, now: Date = Date()) -> String {
    let s = max(Int(now.timeIntervalSince(since)), 0)
    return s < 60 ? "\(s)" + L("초", "s") : s < 3600 ? "\(s / 60)" + L("분", "m") : "\(s / 3600)" + L("시간", "h")
}
func stateName(_ s: String) -> String {
    ["waiting": L("승인을 기다리는 중", "Waiting for approval"), "working": L("진행 중", "Working"), "done": L("완료", "Done")][s] ?? L("노는 중", "Idle")
}
func sorted(_ rows: [Row]) -> [Row] {
    let stateOrder = ["waiting", "working", "done"]     // 급한 것부터. 나머지(노는 중)는 맨 아래
    return rows.sorted { a, b in
        let x = stateOrder.firstIndex(of: a.state) ?? stateOrder.count, y = stateOrder.firstIndex(of: b.state) ?? stateOrder.count
        return x != y ? x < y : a.name < b.name
    }
}
final class RowView: NSView {          // 누르면 그 세션을 여는 줄
    var onClick: (() -> Void)?
    override func mouseUp(with e: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }     // 띄운 창은 앱이 앞에 없어도 첫 클릭에 눌린다
    override var mouseDownCanMoveWindow: Bool { false }                   // 띄운 창에서 줄을 누른 것이 창 끌기로 먹히지 않게 한다
}
// 판과 띄운 창의 바탕. macOS 의 흐린 배경 위에 연분홍에서 연파랑으로 가는 그라데이션을 40% 로 입힌다. 어두운 모드에서는 같은 색조를 어둡게 쓴다
final class Skin: NSView {
    var inMenu = false                                       // 메뉴 막대의 판에 깔렸는지
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    // 메뉴는 항목의 뷰(NSMenuItemViewer) 밖을 잘라내서 메뉴의 위아래 여백 5pt 에는 바탕이 안 칠해진다
    // 메뉴가 열 때마다 잘라내기를 다시 켜므로, 판의 바탕은 그리기 직전마다 위쪽 뷰들의 잘라내기를 푼다
    override func viewWillDraw() {
        super.viewWillDraw()
        var v = inMenu ? superview : nil
        while let up = v { if up.clipsToBounds { up.clipsToBounds = false }; up.layer?.masksToBounds = false; v = up.superview }
    }
    override func draw(_ d: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 0.4) }
        NSGradient(starting: dark ? c(84, 56, 66) : c(255, 225, 231), ending: dark ? c(52, 62, 92) : c(222, 232, 250))!.draw(in: bounds, angle: 0)
    }
}
final class TopDown: NSStackView { override var isFlipped: Bool { true } }   // 스크롤 안에서 위부터 쌓이게 한다

// 머리말과 세션 목록 한 벌. 메뉴 막대의 판과 띄운 창이 한 벌씩 갖는다
final class Listing: NSObject {
    unowned let owner: Bar
    let list = TopDown(), scroll = NSScrollView(), subtitle = NSTextField(labelWithString: ""), more = NSTextField(labelWithString: "")
    var times: [(since: Date, text: NSTextField)] = []      // 줄마다의 지난 시간. 줄을 다시 만들지 않고 글자만 고친다
    var listed = "", picked: () -> Void = {}                // picked: 줄을 눌러 세션을 연 뒤에 할 일
    let rowHeight: CGFloat = 46, maxRows: Int               // maxRows 줄까지 보이고 그 뒤로는 목록 안에서 스크롤한다. 0 이면 놓인 자리의 높이를 따른다
    lazy var listHeight = scroll.heightAnchor.constraint(equalToConstant: rowHeight)

    init(_ owner: Bar, maxRows: Int) {
        self.owner = owner; self.maxRows = maxRows
        super.init()
        subtitle.font = .systemFont(ofSize: 12); subtitle.textColor = .secondaryLabelColor
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 0; list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list; scroll.drawsBackground = false; scroll.hasVerticalScroller = false   // 막대가 자리를 차지하면 줄이 밀려서 뺐다. 휠로 넘긴다
        list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        listHeight.isActive = maxRows > 0
        more.font = .systemFont(ofSize: 11.5); more.textColor = .secondaryLabelColor; more.alignment = .center
    }
    // 머리말 줄: 앱 아이콘, 이름, 펫 수. 오른쪽에 버튼을 붙인다
    func head(_ right: NSView...) -> NSStackView {
        let names = NSStackView(views: [owner.text("MochiPet", 15, .bold), subtitle]); names.orientation = .vertical; names.alignment = .leading; names.spacing = 1
        let left = NSStackView(views: [NSImageView(image: appIcon(34)), names]); left.spacing = 10
        let gap = NSView(); gap.setContentHuggingPriority(.init(1), for: .horizontal)
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let h = NSStackView(views: [left, gap] + right); h.spacing = 12
        return h
    }

    // 세션 목록과 머리말을 채운다. 줄의 내용이 그대로면 지난 시간만 고친다 (스크롤 자리가 유지된다)
    func fill(_ all: [Row]) {
        let rows = sorted(all), waiting = rows.filter { $0.state == "waiting" }.count
        // 머리말: 펫 수, 승인을 기다리는 수, 끝난 수. 0 인 것은 적지 않는다
        let done = rows.filter { $0.state == "done" }.count
        subtitle.stringValue = L("펫 \(rows.count)마리", rows.count == 1 ? "1 pet" : "\(rows.count) pets")
            + (waiting > 0 ? L(" · 승인 대기 \(waiting)", " · \(waiting) waiting") : "") + (done > 0 ? L(" · 완료 \(done)", " · \(done) done") : "")
        let now = rows.map { "\($0.id)|\($0.name)|\($0.state)|\($0.kind)|\($0.coat)|\($0.hue ?? -1)" }.joined(separator: "\n")
        if now != listed {
            listed = now; times = []
            list.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for r in rows {
                let dot = NSView(); dot.wantsLayer = true; dot.layer?.cornerRadius = 4
                dot.layer?.backgroundColor = (stateDots[r.state] ?? NSColor.systemGray.withAlphaComponent(0.5)).cgColor
                let face = NSImageView(image: portrait(kind: r.kind, coat: r.coat, hue: r.hue))
                let label = NSStackView(views: [owner.text(r.name, 13, .semibold), owner.text(stateName(r.state), 11, gray: true)])
                label.orientation = .vertical; label.alignment = .leading; label.spacing = 0
                for t in label.arrangedSubviews { t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }   // 긴 이름은 창을 넓히지 않고 줄인다
                let time = owner.text(ago(r.since), 12, gray: true); times.append((r.since, time))
                let off = NSButton(image: owner.symbol("xmark.circle.fill"), target: self, action: #selector(turnOff(_:)))   // 이 펫만 끈다
                off.isBordered = false; off.contentTintColor = .tertiaryLabelColor; off.identifier = .init(r.id); off.toolTip = L("이 펫 끄기", "Turn off")
                let left = NSStackView(views: [dot, face, label]); left.spacing = 8
                let row = owner.line(left, time, off), v = RowView()
                v.onClick = { [weak self] in openChat(r.host, title: sessions.titles[r.id]); acknowledge(r.id); self?.picked() }
                v.addSubview(row); row.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8),
                                             face.widthAnchor.constraint(equalToConstant: 36), face.heightAnchor.constraint(equalToConstant: 34),
                                             v.heightAnchor.constraint(equalToConstant: rowHeight), row.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                                             row.leadingAnchor.constraint(equalTo: v.leadingAnchor), row.trailingAnchor.constraint(equalTo: v.trailingAnchor)])
                list.addArrangedSubview(v); v.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            listHeight.constant = rowHeight * CGFloat(min(max(rows.count, 1), maxRows))
            more.stringValue = "⌄ " + L("\(rows.count - maxRows)마리 더 (스크롤)", "\(rows.count - maxRows) more (scroll)"); more.isHidden = maxRows == 0 || rows.count <= maxRows   // 목록에 다 안 보일 때만 알린다
        }
        for t in times { t.text.stringValue = ago(t.since) }
    }

    @objc func turnOff(_ b: NSButton) { if let id = b.identifier?.rawValue { petOff(id); owner.catchUp() } }
}

final class Bar: NSObject, NSWindowDelegate, NSMenuDelegate {
    lazy var item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var sliders: [(view: NSSlider, now: () -> Double, text: NSTextField, say: () -> String)] = []   // 슬라이더, 지금 값, 값을 적는 글자
    let drop = NSMenu()                                     // 아이콘을 누르면 열리는 메뉴. 항목은 판 하나다
    var open = false                                        // 메뉴가 열려 있는지
    lazy var menu = Listing(self, maxRows: 5)               // 판의 목록
    lazy var float = Listing(self, maxRows: 0)              // 띄운 창의 목록. 창 높이만큼 보인다
    let floatPad: CGFloat = 62                              // 띄운 창에서 목록 말고 위아래가 차지하는 높이: 제목 막대 쪽 48 + 아래 여백 14
    var floating = false                                    // 띄운 창이 떠 있는지
    lazy var floatButton = NSButton(image: symbol("pip.exit"), target: self, action: #selector(toggleFloat))
    let ground = NSSwitch(), hide = NSSwitch(), auto = NSSwitch(), random = NSSegmentedControl(labels: [L("무늬", "Patterns"), L("컬러", "Colors")], trackingMode: .selectOne, target: nil, action: nil)

    override init() {
        super.init()
        scale = min(max(setting("scale") as? Double ?? 1, 0.5), 1.5)      // 범위를 벗어난 값이 남아 있어도 펫이 사라지지 않게 자른다
        opacity = min(max(setting("opacity") as? Double ?? 1, 0.3), 1)
        grounded = setting("grounded") as? Bool ?? false
    }

    // 메뉴 막대에 아이콘을 단다. 그림만 뽑을 때(gallery)는 부르지 않는다
    func install() {
        item.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "MochiPet")
        // 판을 macOS 메뉴의 항목으로 넣는다. 열고 닫기, 밖을 눌렀을 때 닫기, 다른 메뉴 막대 아이콘으로 넘어가기는 macOS 가 한다
        let entry = NSMenuItem(); entry.view = panel; drop.addItem(entry); drop.delegate = self
        item.button?.target = self; item.button?.action = #selector(clicked)
        RunLoop.main.add(Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(poll), userInfo: nil, repeats: true), forMode: .common)   // 메뉴가 열려 있는 동안에도 돈다
        if setting("floating") as? Bool == true { toggleFloat() }   // 띄워 둔 채로 끝났으면 다시 띄운다
    }

    func symbol(_ name: String) -> NSImage { NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage() }
    func text(_ s: String, _ pt: CGFloat = 13, _ weight: NSFont.Weight = .regular, gray: Bool = false) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: pt, weight: weight); t.textColor = gray ? .secondaryLabelColor : .labelColor; t.lineBreakMode = .byTruncatingTail
        return t
    }
    // 왼쪽 것은 왼쪽 끝에, 오른쪽 것들은 오른쪽 끝에 붙인 한 줄
    func line(_ left: NSView, _ right: NSView...) -> NSStackView {
        let gap = NSView(); gap.setContentHuggingPriority(.init(1), for: .horizontal)
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let h = NSStackView(views: [left, gap] + right); h.spacing = 8
        return h
    }

    // 판을 한 번 만든다. 세션 목록은 fill 이 채운다. 항목을 바꾸면 README 의 메뉴 그림도 다시 뽑는다 (./build.sh gallery)
    lazy var panel: NSView = {
        let quit = NSButton(image: symbol("power"), target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.isBordered = false; quit.toolTip = L("종료", "Quit")
        floatButton.isBordered = false; floatButton.toolTip = L("목록 띄워 놓기", "Float the list")
        menu.picked = { [weak self] in self?.drop.cancelTracking() }
        let root = column(menu.head(floatButton, quit), rule(), menu.scroll, menu.more, rule())
        root.edgeInsets.top = 8; root.edgeInsets.bottom = 10      // 메뉴가 위아래에 자기 여백을 두므로 판의 여백은 줄인다
        // 띄운 창과 같은 바탕. 메뉴의 위아래 여백까지 덮게 위아래로 10pt 넓힌다
        let skin = Skin(frame: root.bounds.insetBy(dx: 0, dy: -10)); skin.inMenu = true; skin.autoresizingMask = [.width, .height]; root.addSubview(skin, positioned: .below, relativeTo: nil)
        func add(_ v: NSView) { root.addArrangedSubview(v); v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true }
        func rule() -> NSBox { let b = NSBox(); b.boxType = .separator; return b }

        let gatherAll = NSButton(title: L("모으기", "Gather"), image: symbol("display"), target: self, action: #selector(gather))
        let mix = NSButton(title: L("색 섞기", "Shuffle"), image: symbol("shuffle"), target: self, action: #selector(shuffleAll))
        for b in [gatherAll, mix] { b.imagePosition = .imageLeading; b.bezelStyle = .rounded }
        let buttons = NSStackView(views: [gatherAll, mix]); buttons.distribution = .fillEqually; buttons.spacing = 8
        add(buttons)
        ground.target = self; ground.action = #selector(toggleGrounded); hide.target = self; hide.action = #selector(toggleHidden)
        auto.target = self; auto.action = #selector(toggleAuto)
        random.target = self; random.action = #selector(setRandom(_:))
        for c in [ground, hide, auto] as [NSControl] { c.controlSize = .small }
        add(line(text(L("날지 않기", "No flying")), ground)); add(line(text(L("모두 숨기기", "Hide all")), hide)); add(line(text(L("자동 켜기", "Auto-on")), auto)); add(line(text(L("랜덤", "Random")), random)); add(rule())

        // 투명도와 크기. steps 를 주면 그 수만큼의 눈금에만 멈춘다
        func bar(_ title: String, _ range: ClosedRange<Double>, _ action: Selector, steps: Int = 0, now: @escaping () -> Double, say: @escaping () -> String) {
            let s = NSSlider(value: now(), minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: action)
            if steps > 0 { s.numberOfTickMarks = steps; s.allowsTickMarkValuesOnly = true }
            let value = text("", 11.5, gray: true)
            sliders.append((s, now, value, say)); add(line(text(title, 11.5, gray: true), value)); add(s)
        }
        bar(L("투명도", "Opacity"), 0.3...1, #selector(setOpacity(_:)), now: { Double(opacity) }, say: { "\(Int((opacity * 100).rounded()))%" })
        bar(L("크기", "Size"), 0.5...1.5, #selector(setSize(_:)), steps: Int((1 / sizeUnit).rounded()) + 1, now: { Double(scale) }, say: { "\(Int(side))pt" })   // 60 ~ 180pt. 레티나에서는 15pt 씩 아홉 단계
        return root
    }()

    // 떠 있는 펫을 판에 올릴 줄로 바꾼다. 지난 시간은 세션 파일이 마지막으로 바뀐 시각부터 센다
    func rows() -> [Row] {
        sessions.shown.map { row($0, $1) }
    }
    func row(_ id: String, _ l: [String]) -> Row {
        Row(id: id, name: sessions.names[id] ?? "", state: l[0], since: file(id).map(modified) ?? Date(),
            kind: l[5].isEmpty ? defaultKind : l[5], look: l[3], host: l[2])
    }

    func fill(_ all: [Row]) { _ = panel; menu.fill(all) }   // 판을 먼저 만들어 둔다 (목록 높이를 거기서 정한다)

    // 폭 304, 좌우 여백 20 · 위아래 여백 16 의 세로 한 줄. 판과 띄운 창이 같이 쓴다
    func column(_ views: NSView...) -> NSStackView {
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)   // 좌우 20pt 는 창 버튼의 왼쪽 여백과 같다
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(equalToConstant: 304).isActive = true
        for v in views { root.addArrangedSubview(v); v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true }
        return root
    }

    // 띄운 창: 판의 머리말과 목록만 따로 떠 있는다. 모든 화면과 전체화면 위에 보이고, 옮긴 자리와 바꾼 크기를 기억한다
    // 제목 막대를 투명하게 둔 보통 창이라 닫기·최소화·확대 버튼과 가장자리 크기 조절은 macOS 것을 그대로 쓴다
    lazy var floatWin: NSPanel = {
        let w = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.minSize = NSSize(width: 240, height: floatPad + float.rowHeight)   // 가장 작게는 한 줄이 보이는 크기
        w.toolbar = NSToolbar(); w.toolbarStyle = .unified; w.titlebarSeparatorStyle = .none   // 빈 도구 막대를 달면 제목 막대가 52pt 로 높아지고 창 버튼 둘레가 넓어진다
        w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)   // 펫(.floating)보다 한 칸 아래. 펫이 늘 이 창 앞에 보인다
        w.isOpaque = false; w.backgroundColor = .clear; w.hidesOnDeactivate = false; w.delegate = self
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; w.isMovableByWindowBackground = true
        let glass = NSVisualEffectView(); glass.material = .fullScreenUI; glass.state = .active   // .popover 보다 뒤가 더 비친다
        let root = column(float.scroll); root.edgeInsets.top = 0; root.edgeInsets.bottom = 14   // 줄 안의 여백 6pt 와 더해 위아래가 20pt 로 같다
        float.scroll.automaticallyAdjustsContentInsets = false   // 제목 막대 아래라고 목록 위에 여백이 저절로 붙는 것을 끈다
        // 폭과 높이는 창을 따른다: 고정 폭을 풀고, 남는 높이는 목록이 차지한다
        root.constraints.first { $0.firstItem === root && $0.firstAttribute == .width && $0.secondItem == nil }?.isActive = false
        root.distribution = .fill; float.scroll.setContentHuggingPriority(.init(1), for: .vertical)
        let bar: CGFloat = 52, skin = Skin(frame: glass.bounds); skin.autoresizingMask = [.width, .height]; glass.addSubview(skin)
        glass.addSubview(root)
        // 펫 수는 제목 막대의 창 버튼 옆에 적는다. 이름과 아이콘은 띄운 창에서는 뺀다
        float.subtitle.translatesAutoresizingMaskIntoConstraints = false; glass.addSubview(float.subtitle)
        float.subtitle.lineBreakMode = .byTruncatingTail; float.subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)   // 좁은 창에서는 줄여 적는다
        NSLayoutConstraint.activate([float.subtitle.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 92), float.subtitle.centerYAnchor.constraint(equalTo: glass.topAnchor, constant: bar / 2),
                                     float.subtitle.trailingAnchor.constraint(lessThanOrEqualTo: glass.trailingAnchor, constant: -16)])
        NSLayoutConstraint.activate([root.topAnchor.constraint(equalTo: glass.topAnchor, constant: bar - 4), root.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
                                     root.leadingAnchor.constraint(equalTo: glass.leadingAnchor), root.trailingAnchor.constraint(equalTo: glass.trailingAnchor)])
        w.contentView = glass
        perch = w.windowNumber                               // 펫이 이 창 위에도 올라선다 (Pet.swift 의 screenWindows)
        NotificationCenter.default.addObserver(self, selector: #selector(floatMoved), name: NSWindow.didMoveNotification, object: w)
        NotificationCenter.default.addObserver(self, selector: #selector(floatResized), name: NSWindow.didEndLiveResizeNotification, object: w)
        return w
    }()
    // 옮기거나 크기를 바꾼 뒤의 자리와 크기를 남긴다
    // 높이를 위아래 몫 + 줄 수로 맞춘 창. 목록 아래에 반쯤 잘린 줄이나 남는 여백이 안 생긴다. 윗변은 제자리에 둔다
    func wholeRows(_ r: NSRect) -> NSRect {
        let h = floatPad + max(1, ((r.height - floatPad) / float.rowHeight).rounded()) * float.rowHeight
        return NSRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)
    }
    // 끄는 동안에는 높이가 그대로 따라오고, 놓으면 가까운 줄 수로 맞춘 뒤 한 번 저장한다 (저장할 때마다 설정 파일을 통째로 다시 쓴다)
    @objc func floatResized() { floatWin.setFrame(wholeRows(floatWin.frame), display: true, animate: true); floatMoved() }
    @objc func floatMoved() { guard floating else { return }; let f = floatWin.frame; setSetting("floatFrame", [f.minX, f.minY, f.width, f.height].map { Double($0) }) }
    func windowShouldClose(_ w: NSWindow) -> Bool { toggleFloat(); return false }   // 빨강 버튼은 창을 없애지 않고 띄우기를 끈다
    @objc func toggleFloat() {
        floating.toggle(); setSetting("floating", floating)
        if floating {
            float.fill(rows())
            let v = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let saved = (setting("floatFrame") as? [Double]).flatMap { $0.count == 4 ? NSRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
            let f = saved.flatMap { r in NSScreen.screens.contains { $0.frame.intersects(r) } ? r : nil }      // 그 화면이 없어졌으면 처음 자리로
            floatWin.setFrame(wholeRows(f ?? NSRect(x: v.maxX - 324, y: v.maxY - 460, width: 304, height: 440)), display: true)
            floatWin.orderFrontRegardless()
        } else { floatWin.orderOut(nil) }
        refresh()
    }

    func menuWillOpen(_ m: NSMenu) {
        open = true; fill(rows()); refresh(); panel.setFrameSize(panel.fittingSize)
    }
    // 아이콘을 누르면 앱을 먼저 앞으로 가져온 뒤에 메뉴를 연다. 앱이 앞에 없으면 스위치와 슬라이더가 꺼진 것처럼 회색으로 그려지고,
    // 메뉴가 열린 뒤에 앞으로 가져오면 그 바람에 메뉴가 닫힌다. 0.3초 안에 못 나오면(macOS 가 막으면) 그냥 연다
    var opening: NSObjectProtocol?
    @objc func clicked() {
        guard opening == nil else { return }
        if NSApp.isActive { return popMenu() }
        opening = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.popMenu() }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in if self?.opening != nil { self?.popMenu() } }
    }
    func popMenu() {
        if let o = opening { NotificationCenter.default.removeObserver(o); opening = nil }
        item.menu = drop; item.button?.performClick(nil); item.menu = nil    // 메뉴를 달아 둔 동안의 클릭은 macOS 가 메뉴를 연다
    }
    func menuDidClose(_ m: NSMenu) { open = false }

    // 1초마다: 판이 열려 있으면 목록을 고친다
    @objc func poll() {
        guard open || floating else { return }
        let now = rows()
        if open { fill(now) }
        if floating { float.fill(now) }
    }

    func refresh() {
        for s in sliders { s.view.doubleValue = s.now(); s.text.stringValue = s.say() }
        ground.state = grounded ? .on : .off; hide.state = hidden ? .on : .off; auto.state = setting("autoOn") as? Bool == true ? .on : .off; random.selectedSegment = colorFirst ? 1 : 0
        item.button?.appearsDisabled = hidden                // 숨긴 동안은 아이콘이 흐리다
        floatButton.contentTintColor = floating ? .controlAccentColor : nil
        allPets.forEach { $0.applyLook() }
    }

    @objc func setOpacity(_ s: NSSlider) {
        opacity = s.doubleValue; setSetting("opacity", s.doubleValue); refresh()
    }
    // 도트 한 칸(배율 1 에서 4pt)이 화면 픽셀 정수 개가 되는 배율로 맞춘다. 그래야 칸 크기가 고르다. 레티나에서는 15pt 단위가 된다.
    var sizeUnit: Double { 1 / (4 * (NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)) }
    @objc func setSize(_ s: NSSlider) {
        let unit = sizeUnit
        scale = (s.doubleValue / unit).rounded() * unit
        setSetting("scale", Double(scale)); refresh()
    }
    @objc func setRandom(_ c: NSSegmentedControl) {     // 무작위로 색을 뽑을 때 어느 줄을 먼저 볼지 (randomLook)
        setSetting("colorFirst", c.selectedSegment == 1); refresh()
    }
    // 이 화면으로 모으기: 마우스가 있는 화면(메뉴를 연 화면)의 꼭대기로 모든 펫을 옮긴다. 거기서 떨어져 내려온다
    @objc func gather() {
        let at = NSEvent.mouseLocation
        guard let v = (NSScreen.screens.first { $0.frame.contains(at) } ?? NSScreen.main)?.visibleFrame else { return }
        for p in sessions.pets.values {
            p.pet.pos = CGPoint(x: .random(in: v.minX...max(v.minX, v.maxX - side)), y: v.maxY - side)
            p.pet.start("fall"); p.slide(over: 0)   // 미끄러지던 중이어도 바로 새 자리에 놓는다
        }
    }

    // 모두 색 섞기: 떠 있는 펫 전부의 색을 다시 뽑아 세션 파일에 적는다
    @objc func shuffleAll() {
        let files = sessionFiles().shuffled()
        let now = files.compactMap { f in readSession(f).map { (f, $0) } }
        for (old, new) in zip(now, reshuffled(now.map(\.1), colorFirst: colorFirst)) { writeSession(old.0, new) }
        catchUp()
    }
    // 세션 파일을 고친 뒤에 부른다. 다음 틱을 기다리지 않고 펫과 판의 목록에 바로 반영한다 (기다리면 최대 1.5초 늦다)
    func catchUp() { sessions.sync(); poll() }
    @objc func toggleHidden() { hidden.toggle(); refresh() }
    // 자동으로 켜기: 켜 두면 펫이 없는 세션에 첫 프롬프트가 들어올 때 펫이 켜진다 (--hook working)
    @objc func toggleAuto() { setSetting("autoOn", auto.state == .on) }
    // 날지 않기: 펫이 바닥에만 있는다. 날기, 날아 내려오기, 풍선 타기, 창 타고 오르기를 고르지 않고 창 위에도 서지 않는다 (Pet.swift 의 grounded).
    // 켜는 순간 떠 있거나 매달려 있던 펫은 바로 떨어지고, 창 위에 서 있던 펫은 다음 틱에 떨어진다
    @objc func toggleGrounded() {
        grounded.toggle(); setSetting("grounded", grounded)
        for p in sessions.pets.values where grounded && (flying.contains(p.pet.name) || ["hang", "dangle", "pop"].contains(p.pet.name)) { p.pet.start("fall") }
        refresh()
    }
}

// 펫 앱은 하나만 뜬다. 플러그인을 업데이트하면 버전 폴더가 달라져서, 예전 앱이 떠 있어도 open 이 새 앱을 하나 더 띄운다.
// 더 새 버전이 남는다. 버전이 같으면 나중에 뜬 쪽이 남는다 (저장소에서 빌드한 앱으로 바꿔 띄울 때)
func appVersion(_ b: Bundle?) -> String { b?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "") where other.processIdentifier != getpid() {
    if appVersion(other.bundleURL.flatMap(Bundle.init(url:))).compare(appVersion(.main), options: .numeric) == .orderedDescending { exit(0) }
    other.terminate()
}

let app = NSApplication.shared
let bar = Bar()                     // 펫을 만들기 전에 크기와 투명도를 읽어 둔다
let sessions = Sessions()
let card = Card()
bar.install()
sessions.sync()
RunLoop.main.add(Timer.scheduledTimer(timeInterval: 0.5, target: sessions, selector: #selector(Sessions.sync), userInfo: nil, repeats: true), forMode: .common)   // 메뉴가 열려 있는 동안에도 돈다
RunLoop.main.add(Timer.scheduledTimer(timeInterval: 2, target: sessions, selector: #selector(Sessions.watchDesktop), userInfo: nil, repeats: true), forMode: .common)   // 메뉴가 열려 있는 동안에도 돈다
app.run()
