import AppKit

// MochiPet: Claude Code 세션마다 펫 하나를 띄운다.
// 세션 파일 ~/.claude/mochipet/<세션 id> 는 여섯 줄이다:
//   상태(idle·working·waiting·done), 작업 폴더, 데스크탑 세션 id(터미널에서 켰으면 그 터미널 앱의 번들 id), 색(색상환 위치 0~1. 비어 있으면 그 종류의 기본 색), 이름, 종류
//
//   --on [--name 이름]   펫을 켠다                 (이 넷은 /pet 스킬이 부른다.
//   --off                펫을 끈다                  세션 id 는 Claude Code 가 주는 환경변수에서 읽는다)
//   --color [색]         색을 바꾼다. 색을 안 주면 다른 펫과 덜 겹치는 색을 고르고, default 를 주면 기본 색으로 돌아간다
//   --name 이름          이름표를 바꾼다
//   --kind 종류          펫 종류를 바꾼다 (bunny, dog, 또는 sprites/<종류>/ 폴더 이름)
//   --hook <상태>        Claude Code 훅이 부른다. 훅 JSON 을 stdin 으로 받는다
//                        (end 는 세션 파일을 지우고, resume 은 waiting 일 때만 working 으로 되돌린다)
//   --gallery <폴더>     문서에 넣을 그림과 GIF 를 뽑는다 (./build.sh gallery 가 부른다)
//   인자 없음             펫 앱으로 뜬다. 세션 파일이 하나도 없으면 바로 끝난다

let fm = FileManager.default
let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/mochipet")
let args = CommandLine.arguments
let env = ProcessInfo.processInfo.environment

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
// 무작위로 뽑을 때 컬러 줄을 먼저 볼지. 메뉴바 아이콘의 "랜덤" 에서 고른다. 펫 앱과 /pet 명령이 같은 설정을 읽는다
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

// 세션들의 색을 모두 다시 뽑는다 (메뉴바 아이콘의 "모두 색 섞기"). 종류는 그대로 두고, 앞에서 뽑은 색과 겹치지 않게 차례로 뽑는다
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
        guard let k = value(after: "--kind"), safe(k),
              builtinKinds.contains(k) || fm.fileExists(atPath: spriteDir.appendingPathComponent(k).path) else {
            print("모르는 종류. 쓸 수 있는 것: \(builtinKinds.joined(separator: ", ")), 또는 sprites/<종류>/ 폴더를 만든 이름"); exit(1)
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
                v.onKind = { k in                                   // 우클릭 메뉴에서 고른 종류를 세션 파일에 적는다
                    if let f = file(id), var now = readSession(f) {
                        now[5] = k
                        if Double(now[3]) == nil, coatName(now[3], kind: k) == nil { now[3] = "" }      // 새 종류에 없는 무늬였으면 기본 색으로 돌린다
                        writeSession(f, now)
                    }
                }
                let m = v.menu!
                // 위에서부터: 세션 이름, 모든 펫, 색, 종류(토끼·강아지·고양이), 색 섞기, 이 펫 끄기. 종료는 메뉴바에만 둔다. 여기 있으면 이 펫만 끄려다 앱을 통째로 끄게 된다
                m.insertItem(withTitle: "", action: nil, keyEquivalent: "", at: 0)   // 어느 세션의 펫인지. 아래에서 채운다
                m.insertItem(withTitle: "모든 펫", action: nil, keyEquivalent: "", at: 1).submenu = bar.menu(inBar: false)
                m.insertItem(.separator(), at: 2)
                let color = NSMenu()                                // 색: 기본, 이름 붙은 색, 색상환 색. 모든 펫 바로 아래에 둔다. 하위 메뉴가 있는 둘을 모으고, 아이콘이 있는 둘(색 섞기, 이 펫 끄기)을 맨 아래에 모은다
                // 몇몇 종류만 쓰는 색은 이름 옆에 그 종류들을 적는다. 다른 종류에서 고르면 아무 일도 일어나지 않는다
                let kindNames = ["bunny": "토끼", "dog": "강아지", "cat": "고양이"]
                let named = coats.map { c in (c.kinds.isEmpty || c.kinds.count == builtinKinds.count ? c.ko : "\(c.ko) (\(c.kinds.map { kindNames[$0] ?? $0 }.joined(separator: ", ")))", c.en) }
                // 무늬(기본 색과 이름 있는 색)를 위에, 컬러(색상환 색)를 구분선 아래에 놓는다
                for (title, want) in [("기본", "default")] + named + [("-", "")] + colors.map({ ($0.ko, $0.en) }) {
                    if title == "-" { color.addItem(.separator()); continue }
                    let i = color.addItem(withTitle: title, action: #selector(recolor(_:)), keyEquivalent: "")
                    i.target = self; i.representedObject = [id, want]
                }
                m.insertItem(withTitle: "색", action: nil, keyEquivalent: "", at: 2).submenu = color
                m.addItem(.separator())
                // 색 섞기는 이 펫의 색을 다시 뽑는다. 메뉴바의 "모두 색 섞기" 와 같은 아이콘을 단다
                let mix = m.addItem(withTitle: "색 섞기", action: #selector(recolor(_:)), keyEquivalent: "")
                mix.target = self; mix.representedObject = [id, ""]; mix.image = NSImage(systemSymbolName: "shuffle", accessibilityDescription: nil)
                let off = m.addItem(withTitle: "이 펫 끄기", action: #selector(dismiss(_:)), keyEquivalent: "")
                off.target = self; off.representedObject = id; off.image = NSImage(systemSymbolName: "xmark.rectangle", accessibilityDescription: nil)
                pets[id] = v
            }
            guard let v = pets[id] else { continue }
            // 이름표: /pet name 으로 정한 이름, 없으면 Claude 데스크탑의 세션 제목, 그것도 없으면 폴더 이름
            let full = !l[4].isEmpty ? l[4] : titles[id] ?? (l[1] as NSString).lastPathComponent
            let label = full.count > 24 ? full.prefix(23) + "…" : full
            if v.label != label { v.label = label; v.menu?.item(at: 0)?.title = label }
            guard shown[id] != l else { continue }
            if shown[id]?[0] != l[0] { v.setMood(l[0]) }
            let hue = Double(l[3]).map { CGFloat($0) }
            if v.hue != hue { v.hue = hue }
            let coat = hue == nil ? l[3] : ""                       // 색 줄이 숫자가 아니면 무늬 이름이다
            if v.coat != coat { v.coat = coat }
            let kind = l[5].isEmpty ? defaultKind : l[5]
            if v.kind != kind { v.kind = kind }
            // 우클릭 메뉴에서 지금 종류와 색에 체크 표시를 단다. 종류 줄은 종류 이름을, 색 줄은 [세션 id, 색] 을 달고 있다
            for i in v.menu?.items ?? [] {
                if let k = i.representedObject as? String, builtinKinds.contains(k) { i.state = k == kind ? .on : .off }
                for c in i.submenu?.items ?? [] { if let pick = c.representedObject as? [String], pick.count == 2 { c.state = picked(pick[1], line: l[3]) ? .on : .off } }
            }
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

    // 우클릭 메뉴의 "색": 고른 색을 세션 파일에 적는다. 다음 sync 에서 펫에 입혀진다. 빈 글자는 무작위다
    @objc func recolor(_ i: NSMenuItem) {
        guard let pick = i.representedObject as? [String], let f = file(pick[0]), var now = readSession(f),
              let line = coatName(pick[1], kind: now[5]) ?? (coats.contains { $0.en == pick[1] } ? nil : hueLine(pick[1].isEmpty ? nil : pick[1], kind: now[5], except: f)) else { return }
        now[3] = line; writeSession(f, now)
    }

    @objc func dismiss(_ i: NSMenuItem) {
        if let id = i.representedObject as? String, let f = file(id) { try? fm.removeItem(at: f) }
    }
}

// 메뉴바 아이콘. 모든 펫의 투명도·크기·속도를 바꾸고 한꺼번에 숨긴다.
// 투명도, 크기, 날지 않기는 UserDefaults 에 남기고, 숨김은 남기지 않는다. 펫이 하나도 없으면 앱이 끝나므로 아이콘도 사라진다.
// 메뉴바가 꽉 찬 화면에서는 아이콘이 노치 뒤로 밀려 안 보이므로, 같은 설정을 펫 우클릭 메뉴의 "모든 펫" 에도 둔다.
let speeds = [0.25, 0.15, 0.08]      // 속도 세 단계의 틱 간격(초): 느리게, 보통, 빠르게
final class Bar: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    // ponytail: 꺼진 펫의 슬라이더가 이 배열에 남는다. 펫이 없으면 앱이 끝나므로 쌓여도 몇 개다.
    var sliders: [(view: NSSlider, now: () -> Double)] = []   // 슬라이더와, 지금 값을 묻는 함수
    var checks: [(item: NSMenuItem, on: () -> Bool)] = []     // 체크 표시를 다는 항목과, 지금 그 값인지 묻는 함수

    override init() {
        super.init()
        let saved = UserDefaults.standard                    // 범위를 벗어난 값이 남아 있어도 펫이 사라지지 않게 자른다
        scale = min(max(saved.object(forKey: "scale") as? Double ?? 1, 0.5), 1.5)
        opacity = min(max(saved.object(forKey: "opacity") as? Double ?? 1, 0.3), 1)
        grounded = saved.bool(forKey: "grounded")
        item.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "MochiPet")
        if item.button?.image == nil { item.button?.title = "pet" }
        item.menu = menu(inBar: true)
    }

    // 설정 메뉴 하나를 만든다. 메뉴바 아이콘과 펫마다의 우클릭 메뉴가 하나씩 갖는다.
    // 숨기기는 메뉴바에만 둔다. 우클릭으로 숨기면 아이콘이 안 보이는 화면에서 되돌릴 길이 없다.
    // 메뉴바 쪽 항목을 바꾸면 README 에 넣는 그림(gallery.swift 의 menuPicture)도 같이 고친다.
    func menu(inBar: Bool) -> NSMenu {
        let m = NSMenu()
        // steps 를 주면 그 수만큼의 눈금에만 멈춘다
        func slider(_ title: String, _ range: ClosedRange<Double>, _ action: Selector, steps: Int = 0, now: @escaping () -> Double) {
            m.addItem(withTitle: title, action: nil, keyEquivalent: "")   // 동작이 없는 항목은 흐리게 나와서 제목 구실을 한다
            let s = NSSlider(value: now(), minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: action)
            if steps > 0 { s.numberOfTickMarks = steps; s.allowsTickMarkValuesOnly = true }
            s.frame = NSRect(x: 18, y: 2, width: 164, height: 22)
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 26)); box.addSubview(s)
            let row = NSMenuItem(); row.view = box; m.addItem(row); sliders.append((s, now))
        }
        slider("투명도", 0.3...1, #selector(setOpacity(_:))) { Double(opacity) }
        slider("크기", 0.5...1.5, #selector(setSize(_:)), steps: Int((1 / sizeUnit).rounded()) + 1) { Double(scale) }   // 60 ~ 180pt. 레티나에서는 15pt 씩 아홉 단계
        func choice(_ title: String, _ action: Selector, _ value: Double, on: @escaping () -> Bool) {
            let i = m.addItem(withTitle: title, action: action, keyEquivalent: "")
            i.target = self; i.representedObject = value; checks.append((i, on))
        }
        slider("속도", 0...2, #selector(setSpeed(_:)), steps: 3) { Double(speeds.firstIndex(of: tick) ?? 1) }   // 세 단계(느리게, 보통, 빠르게)에만 멈춘다
        if inBar {                       // 아래는 메뉴바에만 둔다
            m.addItem(withTitle: "랜덤", action: nil, keyEquivalent: "")       // 무작위로 색을 뽑을 때 어느 줄을 먼저 볼지 (randomLook)
            choice("무늬 랜덤", #selector(setRandom(_:)), 0) { !colorFirst }
            choice("컬러 랜덤", #selector(setRandom(_:)), 1) { colorFirst }
            // 아래는 누르면 바로 일어나는 동작들이라 아이콘을 붙인다. 날지 않기와 모두 숨기기는 켜도 아이콘이 남고 그 앞에 체크 표시가 붙는다
            func icon(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }
            m.addItem(.separator())
            let here = m.addItem(withTitle: "이 화면으로 모으기", action: #selector(gather), keyEquivalent: "")
            here.target = self; here.image = icon("display")
            choice("날지 않기", #selector(toggleGrounded), 0) { grounded }
            m.items.last?.image = icon("shoeprints.fill")
            let mix = m.addItem(withTitle: "모두 색 섞기", action: #selector(shuffleAll), keyEquivalent: "")
            mix.target = self; mix.image = icon("shuffle")
            choice("모두 숨기기", #selector(toggleHidden), 0) { hidden }
            m.items.last?.image = icon("eye.slash")
            m.addItem(.separator())
            let quit = m.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            quit.target = NSApp; quit.image = icon("xmark.rectangle")
        }
        refresh()
        return m
    }

    func refresh() {
        for s in sliders { s.view.doubleValue = s.now() }    // 다른 메뉴의 슬라이더도 같은 값으로 맞춘다
        for c in checks { c.item.state = c.on() ? .on : .off }
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
    @objc func setSpeed(_ s: NSSlider) {
        tick = speeds[min(max(Int(s.doubleValue.rounded()), 0), speeds.count - 1)]; refresh()
    }
    @objc func setRandom(_ i: NSMenuItem) {
        if let v = i.representedObject as? Double { UserDefaults.standard.set(v == 1, forKey: "colorFirst"); refresh() }
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
sessions.sync()
Timer.scheduledTimer(timeInterval: 0.5, target: sessions, selector: #selector(Sessions.sync), userInfo: nil, repeats: true)
Timer.scheduledTimer(timeInterval: 2, target: sessions, selector: #selector(Sessions.watchDesktop), userInfo: nil, repeats: true)
app.run()
