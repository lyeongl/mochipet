import AppKit

// MochiPet: Claude Code 세션마다 펫 하나를 띄운다.
// 세션 파일 ~/.claude/mochipet/<세션 id> 는 여섯 줄이다:
//   상태(idle·working·waiting·done), 작업 폴더, 데스크탑 세션 id(터미널에서 켰으면 그 터미널 앱의 번들 id), 색(색상환 위치 0~1. 비어 있으면 그 종류의 기본 색), 이름, 종류
//
//   --on [--name 이름]   펫을 켠다                 (이 넷은 /pet 스킬이 부른다.
//   --off                펫을 끈다                  세션 id 는 Claude Code 가 주는 환경변수에서 읽는다)
//   --color [색]         색을 바꾼다. 색을 안 주면 다른 펫과 덜 겹치는 색을 고르고, default 를 주면 기본 색으로 돌아간다
//   --name 이름          이름표를 바꾼다
//   --kind 종류          펫 종류를 바꾼다 (bunny, dog, cat)
//   --hook <상태>        Claude Code 훅이 부른다. 훅 JSON 을 stdin 으로 받는다
//                        (end 는 세션 파일을 지우고, resume 은 waiting 일 때만 working 으로 되돌린다)
//   --gallery <폴더>     문서에 넣을 그림과 GIF 를 뽑는다 (./build.sh gallery 가 부른다)
//   인자 없음             펫 앱으로 뜬다. 세션 파일이 하나도 없으면 바로 끝난다

let fm = FileManager.default
let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/mochipet")
let args = CommandLine.arguments
let env = ProcessInfo.processInfo.environment
var portraits: [String: NSImage] = [:]              // 잘라 둔 얼굴 그림 (portrait)
// 아래 둘은 메뉴 막대 판(Bar)이 쓴다. 그림만 뽑을 때(--gallery)와 selftest 가 앱이 뜨기 전에 쓰므로 맨 위에 둔다
let stateOrder = ["waiting", "working", "done"]     // 급한 것부터. 나머지(평소)는 맨 아래
let stateLooks: [String: (name: String, dot: NSColor)] = ["waiting": ("승인을 기다리는 중", .systemOrange), "working": ("진행 중", .systemBlue), "done": ("끝남", .systemGreen)]

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
func writeSession(_ f: URL, _ lines: [String]) {
    try? lines.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
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
var colorFirst: Bool { UserDefaults.standard.bool(forKey: "colorFirst") }

// 떠 있는 펫들이 입고 있는 색. 색 줄이 비어 있으면(기본 색) 그 종류의 기본 무늬 이름으로, 옛 이름은 지금 이름으로 바꿔서 돌려준다.
// 기본 색은 종류마다 다른 무늬라서, 빈 줄끼리 같다고 보면 샴 고양이가 있다고 흰 토끼를 못 뽑는다
func usedLooks() -> [String] {
    ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .compactMap(readSession)
        .map { lookName($0[3], kind: $0[5]) }
}

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

// 색 메뉴의 한 줄(want)이 지금 색 줄(line)과 같은 색인지. 기본은 빈 줄, 색상환 색은 그 각도, 나머지는 색 이름으로 견준다. 무작위(빈 want)는 늘 아니다
func picked(_ want: String, line: String) -> Bool {
    if want == "default" { return line.isEmpty }
    if let degrees = colorNames[want] { return line == String(degrees / 360) }
    return !want.isEmpty && (coatAlias[line] ?? line) == want
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
    let t0 = Date(timeIntervalSince1970: 0), rs = ["idle", "done", "waiting", "working"].map { Row(id: $0, name: "a", state: $0, since: t0, kind: "", look: "", host: "") }
    precondition(ago(t0, now: t0 + 45) == "45초" && ago(t0, now: t0 + 125) == "2분" && ago(t0, now: t0 + 7300) == "2시간" && ago(t0, now: t0 - 5) == "0초"
                 && sorted(rs).map(\.state) == ["waiting", "working", "done", "idle"], "메뉴 막대 판의 지난 시간이나 줄 순서가 틀림")
    precondition(hueLine("default", except: dir) == "" && hueLine("분홍", except: dir) == String(350.0 / 360) && hueLine("-90", except: dir) == "0.75"
                 && hueLine("nope", except: dir) == nil && hueLine(nil, except: dir) != nil, "색 줄이 틀림")
    var flier = Pet(pos: .zero); grounded = true; flier.start("fly"); let stayed = flier.name; flier.start("climb"); let low = flier.name; grounded = false; flier.start("balloon")
    precondition(stayed == "idle" && low == "idle" && flier.name == "balloon" && flying.allSatisfy { actions[$0] != nil }, "날지 않기가 틀림")
    let breeds = ["golden", "white", "ivory", "cream", "gray", "silver", "patch", "pug", "shiba"], hues = ["plain"] + colors.map { String($0.degrees / 360) } + [String(creamHue)]
    func dogLook(_ used: [String], _ colorFirst: Bool) -> String { lookName(randomLook(kind: "dog", used: used, colorFirst: colorFirst), kind: "dog") }
    precondition(breeds.contains(dogLook([], false)) && hues.contains(dogLook([], true))
                 && breeds.contains(dogLook(breeds, false)) && hues.contains(dogLook(hues, true))                  // 줄이 다 쓰여도 다른 줄로 넘어가지 않는다
                 && dogLook(breeds + breeds.dropLast(), false) == "shiba" && dogLook(hues.dropLast(), true) == hues.last!   // 가장 덜 쓰인 것이 먼저다
                 && randomLook(kind: "", used: ["white", "ivory", "cream", "patch", "gray", "golden"], colorFirst: false) == "silver" && randomLook(kind: "cat", used: ["white", "ivory", "cream", "gray", "silver", "golden", "patch"], colorFirst: false) == "", "무작위 색이 틀림")
    precondition(picked("default", line: "") && picked("pink", line: String(350.0 / 360)) && picked("patch", line: "calico") && picked("gray", line: "gray")
                 && !picked("", line: "") && !picked("golden", line: "") && !picked("red", line: "gray"), "색 메뉴의 체크 표시가 틀림")
    precondition(randomKind(used: ["bunny", "", "dog"]) == "cat" && builtinKinds.contains(randomKind(used: [])) && randomKind(used: ["dog", "cat", "cat", "dog"]) == "bunny", "무작위 종류가 틀림")
    let before = Array(repeating: ["working", "/", "", "0.5", "이름", "dog"], count: 9), after = reshuffled(before, colorFirst: false)
    precondition(zip(before, after).allSatisfy { $0[5] == $1[5] && $0[4] == $1[4] } && Set(after.map { lookName($0[3], kind: "dog") }) == Set(breeds)
                 && reshuffled(before + before, colorFirst: true).allSatisfy { hues.contains($0[3]) }, "모두 색 섞기가 틀림")
    exit(0)
}
if let out = value(after: "--gallery") { try exportGallery(to: URL(fileURLWithPath: out)); exit(0) }

if let cmd = args.dropFirst().first, ["--on", "--off", "--color", "--name", "--kind"].contains(cmd) {
    guard let f = file(env["CLAUDE_CODE_SESSION_ID"] ?? "") else {
        print("CLAUDE_CODE_SESSION_ID 가 없어서 어느 세션인지 알 수 없음"); exit(1)
    }
    if cmd == "--off" { try? fm.removeItem(at: f); print("펫 끔"); exit(0) }
    let name = value(after: "--name").map { String($0.replacingOccurrences(of: "\n", with: " ").prefix(30)) }
    var l = readSession(f)
    if l == nil {
        guard cmd == "--on" else { print("이 세션은 펫이 꺼져 있음. /pet on 을 먼저 해야 함"); exit(1) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 스킬은 턴 도중에 불리므로 working 으로 시작한다
        // 종류와 색을 무작위로 정한다. 종류를 먼저 뽑고, 그 종류가 쓰는 색 중에서 색을 뽑는다
        let kind = randomKind(used: ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).compactMap(readSession).map { $0[5] })
        l = ["working", fm.currentDirectoryPath, host(env), randomLook(kind: kind, used: usedLooks(), colorFirst: colorFirst), "", kind]
    }
    if cmd == "--color" {
        let want = value(after: "--color")?.lowercased()
        guard let line = coatName(want, kind: l![5]) ?? hueLine(want, kind: l![5], except: f) else {
            let mine = coats.filter { wears(l![5].isEmpty ? defaultKind : l![5], $0) }.flatMap { [$0.en, $0.ko] }
            print("모르는 색: \(want!). 이름(\((colorNames.keys.sorted() + mine).joined(separator: ", ")), default)이나 0~360 숫자를 쓴다"); exit(1)
        }
        l![3] = line
    }
    if cmd == "--kind" {
        guard let k = value(after: "--kind"), builtinKinds.contains(k) else {
            print("모르는 종류. 쓸 수 있는 것: \(builtinKinds.joined(separator: ", "))"); exit(1)
        }
        l![5] = k
        if Double(l![3]) == nil, coatName(l![3], kind: k) == nil { l![3] = "" }      // 새 종류에 없는 무늬였으면 기본 색으로 돌린다
    }
    if let n = name { l![4] = n }
    writeSession(f, l!)
    if cmd == "--on" {              // 펫 앱이 안 떠 있으면 띄운다 (-g: 앞으로 가져오지 않는다)
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", Bundle.main.bundleURL.path]
        try open.run(); open.waitUntilExit()
    }
    print(["--on": "펫 켬", "--color": "색 바꿈", "--name": "이름 바꿈", "--kind": "종류 바꿈"][cmd]!); exit(0)
}

if args.count >= 3, args[1] == "--hook" {
    let j = (try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())) as? [String: Any]
    // 펫을 켠 세션만 건드린다. 훅은 stdout 이 대화에 섞일 수 있어서 아무것도 찍지 않는다.
    guard let f = file(j?["session_id"] as? String ?? ""), var l = readSession(f) else { exit(0) }
    if args[2] == "end" { try? fm.removeItem(at: f); exit(0) }
    // resume 은 도구가 끝날 때마다 불린다. 승인을 기다리던 중이었을 때만 working 으로 되돌린다.
    if args[2] == "resume" && l[0] != "waiting" { exit(0) }
    l[0] = args[2] == "resume" ? "working" : args[2]
    writeSession(f, l); exit(0)
}

// 세션 파일 셋째 줄에 적을 값. Claude 데스크탑에서 켰으면 데스크탑 세션 id 이고,
// 터미널에서 켰으면 그 터미널 앱의 번들 id 다 (앱이 띄운 프로세스에는 macOS 가 __CFBundleIdentifier 를 넣어 준다).
func host(_ env: [String: String]) -> String {
    if let s = env["CLAUDE_CODE_HOST_SESSION_ID"] { return s }
    let app = env["__CFBundleIdentifier"] ?? ""
    return app.contains(".") && app.count <= 100 && app.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) } ? app : ""
}

// 펫을 누르면 그 세션의 Claude 데스크탑 채팅을 연다. 터미널에서 켠 펫은 그 터미널 앱을 앞으로 가져온다.
// ponytail: 터미널은 앱까지만 찾는다. 탭이나 창까지 찾으려면 iTerm2·터미널의 AppleScript 로 tty 를 고른다.
// 세션을 지정하는 링크는 문서에 없다. Claude 데스크탑 4.23118.1 의 URL 처리 코드에서 확인한 형식이라 버전이 바뀌면 안 열릴 수 있다.
let claudeApp = "com.anthropic.claudefordesktop"   // Claude 데스크탑의 번들 id
func openChat(_ host: String) {
    if host.hasPrefix("local_"), safe(host), let link = URL(string: "claude://code/continue?session=\(host)") {
        NSWorkspace.shared.open(link)
    } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: host.contains(".") ? host : claudeApp) {   // 설치된 위치가 어디든 찾아서 연다
        NSWorkspace.shared.open(app)
    }
}

// 끝난 세션을 확인했으면(펫을 눌렀거나 Claude 데스크탑에서 열어 봤으면) 평소 행동으로 돌려보낸다.
// 파일에 적어 두므로 펫 앱을 다시 띄워도 다시 알리지 않는다.
func acknowledge(_ id: String) {
    guard let f = file(id), var l = readSession(f), l[0] == "done" else { return }
    l[0] = "idle"
    writeSession(f, l)
}

// Claude 데스크탑은 세션마다 파일 하나에 제목과 마지막으로 연 시각을 적어 둔다.
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
    var titles: [String: String] = [:]    // Claude 데스크탑의 세션 제목
    var gone: [String: Int] = [:]         // 데스크탑 세션 파일이 연달아 안 보인 횟수
    var front: (app: String?, since: Date) = (nil, .distantPast)   // 지금 맨 앞에 있는 앱과 그 앱이 앞으로 온 시각
    var desktop: [URL: (at: Date, title: String?, focused: Date, archived: Bool)] = [:]   // 읽어 둔 데스크탑 세션 파일. 파일이 바뀌면 다시 읽는다

    // 데스크탑 세션 파일은 수백 KB 라서 바뀌었을 때만 다시 읽는다.
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
        for u in files.sorted(by: { modified($0) > modified($1) }) {
            if let b = best, modified(u) < b.at { break }
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
                v.onClick = { openChat(l[2]); acknowledge(id) }
                v.onMenu = { [weak v] in if let v = v { card.show(id, at: v) } }
                pets[id] = v
            }
            guard let v = pets[id] else { continue }
            // 이름표: /pet name 으로 정한 이름, 없으면 Claude 데스크탑의 세션 제목, 그것도 없으면 폴더 이름
            let full = !l[4].isEmpty ? l[4] : titles[id] ?? (l[1] as NSString).lastPathComponent
            let label = full.count > 24 ? full.prefix(23) + "…" : full
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
        for (id, v) in pets where !ids.contains(id) { v.close(); pets[id] = nil; shown[id] = nil; titles[id] = nil; gone[id] = nil }
        if pets.isEmpty { NSApp.terminate(nil) }
    }

    // 2초마다: 세션 제목을 가져오고, 끝난 세션을 Claude 데스크탑에서 열어 봤으면 확인한 것으로 처리한다.
    // 세션을 보관했거나 지웠으면 펫을 끄고 세션 파일을 지운다. 그래야 ~/.claude/mochipet 에 끝난 세션의 파일이 쌓이지 않는다.
    // 보관 표시(isArchived)도 문서에 없는 값이다 (4.23118.1 에서 확인).
    @objc func watchDesktop() {
        let files = desktopFiles()
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if app != front.app { front = (app, Date()) }
        let claudeInFront = app == claudeApp
        for (id, l) in shown {
            guard let u = files.first(where: { $0.lastPathComponent == l[2] + ".json" }) else {
                // 데스크탑에서 연 세션인데 그 파일이 없으면 세션을 지운 것이다. 쓰는 도중이라 잠깐 안 보이는 것일 수 있어서
                // 다섯 번(10초) 연달아 없을 때 끈다. 폴더를 아예 못 읽었을 때(files 가 비었을 때)는 건드리지 않는다
                if l[2].hasPrefix("local_"), !files.isEmpty {
                    gone[id, default: 0] += 1
                    if gone[id]! >= 5, let f = file(id) { try? fm.removeItem(at: f) }
                }
                // 터미널에서 켠 펫: 끝난 뒤에 그 터미널 앱으로 넘어왔으면 본 것이다. 끝날 때 이미 그 앱에 있었으면 펫을 누르거나 다음 프롬프트를 보낼 때까지 축하한다
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
// 색: 이름(무늬나 컬러)을 주면 그 색으로, 빈 글자를 주면 무작위로 바꾼다
func recolor(_ id: String, _ want: String) {
    guard let f = file(id), var now = readSession(f),
          let line = coatName(want, kind: now[5]) ?? (coats.contains { $0.en == want } ? nil : hueLine(want.isEmpty ? nil : want, kind: now[5], except: f)) else { return }
    now[3] = line; writeSession(f, now)
}
func setKind(_ id: String, _ k: String) {
    guard let f = file(id), var now = readSession(f) else { return }
    now[5] = k
    if Double(now[3]) == nil, coatName(now[3], kind: k) == nil { now[3] = "" }      // 새 종류에 없는 무늬였으면 기본 색으로 돌린다
    writeSession(f, now)
}
func petOff(_ id: String) { if let f = file(id) { try? fm.removeItem(at: f) } }

// 펫 그림에서 빈 둘레를 잘라 낸 얼굴 그림. 목록과 색 고르는 칸에서 칸 가운데에 꽉 차게 보이게 한다
func portrait(kind: String, coat: String, hue: CGFloat?) -> NSImage {
    let key = "\(kind)|\(coat)|\(hue ?? -1)"
    if let p = portraits[key] { return p }
    let img = drawn("idle_0", hue: hue, kind: kind, coat: coat)
    guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return img }
    let rep = NSBitmapImageRep(cgImage: cg)
    var x0 = rep.pixelsWide, x1 = -1, y0 = rep.pixelsHigh, y1 = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) }
    }
    guard x1 >= x0, let cut = cg.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)) else { return img }
    let p = NSImage(cgImage: cut, size: NSSize(width: cut.width, height: cut.height))
    portraits[key] = p
    return p
}

// 앱 아이콘: 분홍 둥근 네모 안에서 아이보리 토끼가 아래에서 빼꼼 내다본다. 메뉴 막대 판의 머리말과 README 에 쓴다
func appIcon(_ side: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: side, height: side), flipped: false) { box in
        NSBezierPath(roundedRect: box, xRadius: side * 0.23, yRadius: side * 0.23).addClip()
        NSColor(srgbRed: 1, green: 0.71, blue: 0.77, alpha: 1).setFill(); box.fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        drawn("idle_0", kind: "bunny", coat: "ivory").draw(in: NSRect(x: -0.16 * side, y: -0.254 * side, width: 1.32 * side, height: 1.32 * side))
        return true
    }
}

// 펫 우클릭 판: 머리말(얼굴, 이름, 상태), 종류, 무늬, 컬러, 색 섞기, 이 펫 끄기. 메뉴 막대 판과 같은 모양으로 그린다
final class Card: NSObject {
    let pop = NSPopover()
    var id = ""
    weak var anchor: NSView?

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

        let state = bar.text((stateLooks[r.state]?.name ?? "평소") + " · " + ago(r.since), 12, gray: true)
        let names = NSStackView(views: [bar.text(r.name, 14, .bold), state]); names.orientation = .vertical; names.alignment = .leading; names.spacing = 1
        let head = NSStackView(views: [face(40, coat: r.coat, hue: r.hue), names]); head.spacing = 10
        add(head); rule()

        let kinds = NSSegmentedControl(labels: ["토끼", "강아지", "고양이"], trackingMode: .selectOne, target: self, action: #selector(pickKind(_:)))
        kinds.selectedSegment = builtinKinds.firstIndex(of: r.kind) ?? 0
        add(bar.line(bar.text("종류"), kinds))

        // 한 줄에 일곱 칸. 칸마다 얼굴과 이름을 두고, 지금 색인 칸에 테두리를 두른다
        func grid(_ title: String, _ items: [(name: String, want: String, coat: String, hue: CGFloat?)]) {
            add(bar.text(title, 11.5, gray: true))
            for start in stride(from: 0, to: items.count, by: 7) {
                let cells: [NSView] = (start..<start + 7).map { i in
                    guard i < items.count else { return NSView() }
                    let it = items[i], on = picked(it.want, line: r.look) || it.want == lookName(r.look, kind: r.kind)
                    let name = bar.text(it.name, 9.5, gray: true); name.alignment = .center
                    if on { name.textColor = .controlAccentColor }
                    let col = NSStackView(views: [face(34, coat: it.coat, hue: it.hue), name]); col.orientation = .vertical; col.spacing = 4
                    let cell = RowView(); cell.wantsLayer = true; cell.layer?.cornerRadius = 8
                    if on { cell.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.13).cgColor; cell.layer?.borderColor = NSColor.controlAccentColor.cgColor; cell.layer?.borderWidth = 1.5 }
                    cell.addSubview(col); col.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([col.centerXAnchor.constraint(equalTo: cell.centerXAnchor), col.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
                                                 col.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -5)])
                    cell.onClick = { [weak self] in recolor(r.id, it.want); self?.reload(soon: true) }
                    return cell
                }
                let row = NSStackView(views: cells); row.distribution = .fillEqually; row.spacing = 2
                add(row)
            }
        }
        grid("무늬", coats.filter { wears(r.kind, $0) }.map { ($0.ko, $0.en, $0.en, nil) })
        grid("컬러", colors.map { ($0.ko, $0.en, "", CGFloat($0.degrees / 360)) })
        rule()

        let mix = NSButton(title: "색 섞기", image: bar.symbol("shuffle"), target: self, action: #selector(shuffle))
        let off = NSButton(title: "이 펫 끄기", image: bar.symbol("power"), target: self, action: #selector(dismiss))
        for b in [mix, off] { b.imagePosition = .imageLeading; b.bezelStyle = .rounded }
        let buttons = NSStackView(views: [mix, off]); buttons.distribution = .fillEqually; buttons.spacing = 8
        add(buttons)
        // 메뉴 막대가 꽉 찬 화면에서는 발바닥 아이콘이 노치 뒤로 밀려 안 보이므로, 모든 펫의 설정을 여기서도 열 수 있게 한다
        let all = NSButton(title: "모든 펫 설정…", target: self, action: #selector(openAll)); all.isBordered = false; all.contentTintColor = .secondaryLabelColor
        all.font = .systemFont(ofSize: 12)
        add(all)
        return root
    }

    func show(_ id: String, at v: NSView) {
        self.id = id; anchor = v
        guard let r = bar.rows().first(where: { $0.id == id }) else { return }
        let vc = NSViewController(); vc.view = view(for: r)
        pop.contentViewController = vc; pop.behavior = .transient; pop.contentSize = vc.view.fittingSize
        pop.show(relativeTo: v.bounds, of: v, preferredEdge: .maxX)
        NSApp.activate(ignoringOtherApps: true)              // 판 밖을 누르면 닫히게 한다
    }
    // 바꾼 것이 세션 파일에서 펫으로 넘어온 뒤(다음 sync)에 판을 다시 그린다
    func reload(soon: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (soon ? 0.6 : 0)) { [weak self] in
            guard let self = self, self.pop.isShown, let r = bar.rows().first(where: { $0.id == self.id }) else { return }
            let v = self.view(for: r); self.pop.contentViewController?.view = v; self.pop.contentSize = v.fittingSize
        }
    }
    @objc func pickKind(_ c: NSSegmentedControl) { setKind(id, builtinKinds[c.selectedSegment]); reload(soon: true) }
    @objc func shuffle() { recolor(id, ""); reload(soon: true) }
    @objc func dismiss() { petOff(id); pop.close() }
    @objc func openAll() { pop.close(); if let v = anchor { bar.open(from: v, edge: .maxX) } }
}

// 메뉴 막대 아이콘. 누르면 판이 열린다: 세션 목록, 모으기·색 섞기, 날지 않기·모두 숨기기·랜덤, 투명도·크기.
// 투명도, 크기, 날지 않기는 UserDefaults 에 남기고, 숨김은 남기지 않는다. 펫이 하나도 없으면 앱이 끝나므로 아이콘도 사라진다.
// 메뉴 막대가 꽉 찬 화면에서는 아이콘이 노치 뒤로 밀려 안 보이므로, 펫 우클릭 판의 "모든 펫 설정" 에서도 이 판을 연다.
// 판의 세션 한 줄. since 는 지금 상태가 된 시각이고, host 는 눌렀을 때 열 곳이다 (세션 파일 셋째 줄)
struct Row { var id, name, state: String, since: Date, kind, look: String, host: String    // look 은 세션 파일의 색 줄 (무늬 이름이나 색상환 위치)
    var coat: String { Double(look) == nil ? look : "" }
    var hue: CGFloat? { Double(look).map { CGFloat($0) } }
}
func ago(_ since: Date, now: Date = Date()) -> String {
    let s = max(Int(now.timeIntervalSince(since)), 0)
    return s < 60 ? "\(s)초" : s < 3600 ? "\(s / 60)분" : "\(s / 3600)시간"
}
func sorted(_ rows: [Row]) -> [Row] {
    rows.sorted { a, b in
        let x = stateOrder.firstIndex(of: a.state) ?? stateOrder.count, y = stateOrder.firstIndex(of: b.state) ?? stateOrder.count
        return x != y ? x < y : a.name < b.name
    }
}
final class RowView: NSView {          // 누르면 그 세션을 여는 줄
    var onClick: (() -> Void)?
    override func mouseUp(with e: NSEvent) { onClick?() }
}
final class TopDown: NSStackView { override var isFlipped: Bool { true } }   // 스크롤 안에서 위부터 쌓이게 한다

final class Bar: NSObject {
    lazy var item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var sliders: [(view: NSSlider, now: () -> Double, text: NSTextField, say: () -> String)] = []   // 슬라이더, 지금 값, 값을 적는 글자
    let pop = NSPopover()
    let list = TopDown(), scroll = NSScrollView(), subtitle = NSTextField(labelWithString: "")
    let ground = NSSwitch(), hide = NSSwitch(), random = NSSegmentedControl(labels: ["무늬", "컬러"], trackingMode: .selectOne, target: nil, action: nil)
    var times: [(since: Date, text: NSTextField)] = []      // 줄마다의 지난 시간. 줄을 다시 만들지 않고 글자만 고친다
    var listed = "", listHeight: NSLayoutConstraint?
    let rowHeight: CGFloat = 40, maxRows = 5                // 다섯 줄까지 보이고 그 뒤로는 목록 안에서 스크롤한다

    override init() {
        super.init()
        let saved = UserDefaults.standard                    // 범위를 벗어난 값이 남아 있어도 펫이 사라지지 않게 자른다
        scale = min(max(saved.object(forKey: "scale") as? Double ?? 1, 0.5), 1.5)
        opacity = min(max(saved.object(forKey: "opacity") as? Double ?? 1, 0.3), 1)
        grounded = saved.bool(forKey: "grounded")
    }

    // 메뉴 막대에 아이콘을 단다. 그림만 뽑을 때(gallery)는 부르지 않는다
    func install() {
        item.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "MochiPet")
        if item.button?.image == nil { item.button?.title = "pet" }
        item.button?.imagePosition = .imageLeading
        item.button?.target = self; item.button?.action = #selector(toggle)
        let vc = NSViewController(); vc.view = panel
        pop.contentViewController = vc; pop.behavior = .transient
        Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
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
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(equalToConstant: 300).isActive = true
        func add(_ v: NSView) { root.addArrangedSubview(v); v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28).isActive = true }
        func rule() { let b = NSBox(); b.boxType = .separator; add(b) }

        let badge = NSImageView(image: appIcon(34))
        let names = NSStackView(views: [text("MochiPet", 15, .bold), subtitle]); names.orientation = .vertical; names.alignment = .leading; names.spacing = 1
        subtitle.font = .systemFont(ofSize: 12); subtitle.textColor = .secondaryLabelColor
        let quit = NSButton(title: "종료", image: symbol("power"), target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.isBordered = false; quit.imagePosition = .imageLeading
        let head = NSStackView(views: [badge, names]); head.spacing = 10
        add(line(head, quit)); rule()

        list.orientation = .vertical; list.alignment = .leading; list.spacing = 0; list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        listHeight = scroll.heightAnchor.constraint(equalToConstant: rowHeight); listHeight?.isActive = true
        add(scroll); rule()

        let gatherAll = NSButton(title: "모으기", image: symbol("display"), target: self, action: #selector(gather))
        let mix = NSButton(title: "색 섞기", image: symbol("shuffle"), target: self, action: #selector(shuffleAll))
        for b in [gatherAll, mix] { b.imagePosition = .imageLeading; b.bezelStyle = .rounded }
        let buttons = NSStackView(views: [gatherAll, mix]); buttons.distribution = .fillEqually; buttons.spacing = 8
        add(buttons)
        ground.target = self; ground.action = #selector(toggleGrounded); hide.target = self; hide.action = #selector(toggleHidden)
        random.target = self; random.action = #selector(setRandom(_:))
        for c in [ground, hide] as [NSControl] { c.controlSize = .small }
        add(line(text("날지 않기"), ground)); add(line(text("모두 숨기기"), hide)); add(line(text("랜덤"), random)); rule()

        // 투명도와 크기. steps 를 주면 그 수만큼의 눈금에만 멈춘다
        func bar(_ title: String, _ range: ClosedRange<Double>, _ action: Selector, steps: Int = 0, now: @escaping () -> Double, say: @escaping () -> String) {
            let s = NSSlider(value: now(), minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: action)
            if steps > 0 { s.numberOfTickMarks = steps; s.allowsTickMarkValuesOnly = true }
            let value = text("", 11.5, gray: true)
            sliders.append((s, now, value, say)); add(line(text(title, 11.5, gray: true), value)); add(s)
        }
        bar("투명도", 0.3...1, #selector(setOpacity(_:)), now: { Double(opacity) }, say: { "\(Int((opacity * 100).rounded()))%" })
        bar("크기", 0.5...1.5, #selector(setSize(_:)), steps: Int((1 / sizeUnit).rounded()) + 1, now: { Double(scale) }, say: { "\(Int(side))pt" })   // 60 ~ 180pt. 레티나에서는 15pt 씩 아홉 단계
        return root
    }()

    // 떠 있는 펫을 판에 올릴 줄로 바꾼다. 지난 시간은 세션 파일이 마지막으로 바뀐 시각부터 센다
    // ponytail: 색이나 이름을 바꿔도 파일이 바뀌어서 시간이 0 으로 돌아간다. 거슬리면 상태가 바뀐 시각을 파일에 따로 적는다
    func rows() -> [Row] {
        sessions.shown.map { id, l in
            Row(id: id, name: sessions.pets[id]?.label ?? "", state: l[0], since: file(id).map(modified) ?? Date(),
                kind: l[5].isEmpty ? defaultKind : l[5], look: l[3], host: l[2])
        }
    }

    // 세션 목록과 머리말을 채운다. 줄의 내용이 그대로면 지난 시간만 고친다 (스크롤 자리가 유지된다)
    func fill(_ all: [Row]) {
        _ = panel                                            // 판을 먼저 만들어 둔다 (목록 높이를 여기서 정한다)
        let rows = sorted(all), waiting = rows.filter { $0.state == "waiting" }.count
        subtitle.stringValue = "펫 \(rows.count)마리" + (waiting > 0 ? " · 승인 대기 \(waiting)" : "")
        let now = rows.map { "\($0.id)|\($0.name)|\($0.state)|\($0.kind)|\($0.coat)|\($0.hue ?? -1)" }.joined(separator: "\n")
        if now != listed {
            listed = now; times = []
            list.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for r in rows {
                let dot = NSView(); dot.wantsLayer = true; dot.layer?.cornerRadius = 4
                dot.layer?.backgroundColor = (stateLooks[r.state]?.dot ?? NSColor.systemGray.withAlphaComponent(0.5)).cgColor
                let face = NSImageView(image: portrait(kind: r.kind, coat: r.coat, hue: r.hue))
                let label = NSStackView(views: [text(r.name, 13, .semibold), text(stateLooks[r.state]?.name ?? "평소", 11, gray: true)])
                label.orientation = .vertical; label.alignment = .leading; label.spacing = 0
                let time = text(ago(r.since), 12, gray: true); times.append((r.since, time))
                let off = NSButton(image: symbol("xmark.circle.fill"), target: self, action: #selector(turnOff(_:)))   // 이 펫만 끈다
                off.isBordered = false; off.contentTintColor = .tertiaryLabelColor; off.identifier = .init(r.id); off.toolTip = "이 펫 끄기"
                let left = NSStackView(views: [dot, face, label]); left.spacing = 8
                let row = line(left, time, off), v = RowView()
                v.onClick = { [weak self] in openChat(r.host); acknowledge(r.id); self?.pop.close() }
                v.addSubview(row); row.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8),
                                             face.widthAnchor.constraint(equalToConstant: 36), face.heightAnchor.constraint(equalToConstant: 34),
                                             v.heightAnchor.constraint(equalToConstant: rowHeight), row.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                                             row.leadingAnchor.constraint(equalTo: v.leadingAnchor), row.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2)])
                list.addArrangedSubview(v); v.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            listHeight?.constant = rowHeight * CGFloat(min(max(rows.count, 1), maxRows))
        }
        for t in times { t.text.stringValue = ago(t.since) }
    }

    @objc func toggle() {
        if pop.isShown { pop.close() } else if let b = item.button { open(from: b, edge: .minY) }
    }
    // 판을 연다. 메뉴 막대 아이콘에서도, 펫 우클릭 판의 "모든 펫 설정" 에서도 연다
    func open(from v: NSView, edge: NSRectEdge) {
        fill(rows()); refresh()
        pop.contentSize = panel.fittingSize
        pop.show(relativeTo: v.bounds, of: v, preferredEdge: edge)
        NSApp.activate(ignoringOtherApps: true)              // 판 밖을 누르면 닫히게 한다
    }

    // 1초마다: 승인을 기다리는 펫 수를 아이콘 옆에 주황색으로 적고, 판이 열려 있으면 목록을 고친다
    @objc func poll() {
        let waiting = sessions.shown.values.filter { $0[0] == "waiting" }.count
        item.button?.attributedTitle = NSAttributedString(string: waiting > 0 ? " \(waiting)" : "",
            attributes: [.foregroundColor: NSColor.systemOrange, .font: NSFont.boldSystemFont(ofSize: 12)])
        if pop.isShown { fill(rows()); pop.contentSize = panel.fittingSize }
    }

    @objc func turnOff(_ b: NSButton) { if let id = b.identifier?.rawValue { petOff(id) } }

    func refresh() {
        for s in sliders { s.view.doubleValue = s.now(); s.text.stringValue = s.say() }
        ground.state = grounded ? .on : .off; hide.state = hidden ? .on : .off; random.selectedSegment = colorFirst ? 1 : 0
        item.button?.appearsDisabled = hidden                // 숨긴 동안은 아이콘이 흐리다
        allPets.forEach { $0.applyLook() }
    }

    @objc func setOpacity(_ s: NSSlider) {
        opacity = s.doubleValue; UserDefaults.standard.set(s.doubleValue, forKey: "opacity"); refresh()
    }
    // 도트 한 칸(배율 1 에서 4pt)이 화면 픽셀 정수 개가 되는 배율로 맞춘다. 그래야 칸 크기가 고르다. 레티나에서는 15pt 단위가 된다.
    var sizeUnit: Double { 1 / (4 * (NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)) }
    @objc func setSize(_ s: NSSlider) {
        let unit = sizeUnit
        scale = (s.doubleValue / unit).rounded() * unit
        UserDefaults.standard.set(Double(scale), forKey: "scale"); refresh()
    }
    @objc func setRandom(_ c: NSSegmentedControl) {     // 무작위로 색을 뽑을 때 어느 줄을 먼저 볼지 (randomLook)
        UserDefaults.standard.set(c.selectedSegment == 1, forKey: "colorFirst"); refresh()
    }
    // 모두 색 섞기: 떠 있는 펫 전부의 색을 다시 뽑아 세션 파일에 적는다. 펫은 다음 sync 에서 새 색으로 바뀐다
    // 이 화면으로 모으기: 마우스가 있는 화면(메뉴를 연 화면)의 꼭대기로 모든 펫을 옮긴다. 거기서 떨어져 내려온다
    @objc func gather() {
        let at = NSEvent.mouseLocation
        guard let v = (NSScreen.screens.first { $0.frame.contains(at) } ?? NSScreen.main)?.visibleFrame else { return }
        for p in sessions.pets.values {
            p.pet.pos = CGPoint(x: .random(in: v.minX...max(v.minX, v.maxX - side)), y: v.maxY - side)
            p.pet.start("fall"); p.slide(over: 0)   // 미끄러지던 중이어도 바로 새 자리에 놓는다
        }
    }

    @objc func shuffleAll() {
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { safe($0.lastPathComponent) }.shuffled()
        let now = files.compactMap { f in readSession(f).map { (f, $0) } }
        for (old, new) in zip(now, reshuffled(now.map(\.1), colorFirst: colorFirst)) { writeSession(old.0, new) }
    }
    @objc func toggleHidden() { hidden.toggle(); refresh() }
    // 날지 않기: 펫이 바닥에만 있는다. 날기, 날아 내려오기, 풍선 타기, 창 타고 오르기를 고르지 않고 창 위에도 서지 않는다 (Pet.swift 의 grounded).
    // 켜는 순간 떠 있거나 매달려 있던 펫은 바로 떨어지고, 창 위에 서 있던 펫은 다음 틱에 떨어진다
    @objc func toggleGrounded() {
        grounded.toggle(); UserDefaults.standard.set(grounded, forKey: "grounded")
        for p in sessions.pets.values where grounded && (flying.contains(p.pet.name) || ["hang", "dangle", "pop"].contains(p.pet.name)) { p.pet.start("fall") }
        refresh()
    }
}

let app = NSApplication.shared
let bar = Bar()                     // 펫을 만들기 전에 크기와 투명도를 읽어 둔다
let sessions = Sessions()
let card = Card()
bar.install()
sessions.sync()
Timer.scheduledTimer(timeInterval: 0.5, target: sessions, selector: #selector(Sessions.sync), userInfo: nil, repeats: true)
Timer.scheduledTimer(timeInterval: 2, target: sessions, selector: #selector(Sessions.watchDesktop), userInfo: nil, repeats: true)
app.run()
