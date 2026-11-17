import AppKit
import ImageIO
import UniformTypeIdentifiers

// 문서에 넣을 그림을 펫을 그리는 코드에서 그대로 뽑는다 (./build.sh gallery).
//   <dir>/<종류>.png                           종류마다 모든 프레임을 모은 한 장. 프레임 이름을 그 그림 바로 아래에 적는다
//   <dir>/hero.gif                             여러 상태의 펫을 한 줄로 세운 움직이는 그림
//   <dir>/working.gif, waiting.gif, done.gif   세션 상태별 동작
//   <dir>/idle.gif                             할 일이 없을 때 혼자 노는 동작 몇 가지
//   <dir>/menu.png                             메뉴 막대 아이콘과 거기서 열리는 메뉴
//   <dir>/colors.png                           색마다 종류별로 한 마리씩 세운 한 장. 몸 색과 품종 색 두 묶음이다

// scale 은 1pt 를 몇 픽셀로 찍을지다. 마크다운 그림은 픽셀 크기대로 보여서, 작게 보여야 하는 그림은 scale 을 낮춘다
private func bitmap(_ w: CGFloat, _ h: CGFloat, scale: CGFloat = 2, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// 그림 바로 아래, 가운데에 작은 글씨로 이름을 적는다
private func caption(_ text: String, under r: NSRect) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.gray]
    let width = (text as NSString).size(withAttributes: attrs).width
    (text as NSString).draw(at: NSPoint(x: r.midX - width / 2, y: r.minY - 15), withAttributes: attrs)
}

func exportGallery(to dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let names = looks.keys.sorted(), cols = 8, label: CGFloat = 16
    let rows = (names.count + cols - 1) / cols, w = size * CGFloat(cols), h = (size + label) * CGFloat(rows)
    for kind in builtinKinds {
        try bitmap(w, h) {
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
            for (i, n) in names.enumerated() {
                // 이름은 그 그림의 발 바로 아래, 가운데에 적는다. 위에 적으면 윗줄 그림의 이름으로 읽힌다
                let r = NSRect(x: size * CGFloat(i % cols), y: h - CGFloat(i / cols + 1) * (size + label) + label, width: size, height: size)
                drawn(n, kind: kind).draw(in: r)
                caption(n, under: r)
            }
        }.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(kind + ".png"))
    }

    // 색을 한 장에 모두. 위 묶음은 무늬(기본 색과 이름 있는 색. Pet.swift 의 coats), 아래 묶음은 컬러(흰색, 색상환 색, 크림)다. 흰색과 크림은 두 묶음에 다 있다.
    // 묶음마다 왼쪽 위에 소제목(무늬, 컬러)을 적는다.
    // 묶음마다 색 이름을 맨 위에 적고 종류별로 한 줄씩 세운다. 몇몇 종류만 쓰는 색의 열에는 그 종류들만 그린다
    let named = coats.map { (name: "\($0.ko) \($0.en)", hue: CGFloat?.none, coat: $0.en) }
    let groups = [[("기본 default", nil, "")] + named, [("흰색 white", nil, "plain")] + colors.map { ("\($0.ko) \($0.en)", CGFloat($0.degrees / 360), "") } + [("크림 cream", CGFloat(creamHue), "")]]
    let titles = ["무늬", "컬러"]
    func worn(_ kind: String, _ coat: String) -> Bool { coat.isEmpty || coat == "plain" || coats.contains { $0.en == coat && wears(kind, $0) } }
    let margin: CGFloat = 20, head: CGFloat = 60, block = head + size * CGFloat(builtinKinds.count)
    let cw = margin * 2 + size * CGFloat(groups.map(\.count).max()!), ch = block * CGFloat(groups.count)
    try bitmap(cw, ch) {
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: cw, height: ch).fill()
        for (g, tints) in groups.enumerated() {
            let top = ch - block * CGFloat(g)                // 이 묶음의 윗변
            if g > 0 { NSColor(white: 0.9, alpha: 1).setFill(); NSRect(x: 0, y: top, width: cw, height: 1).fill() }
            (titles[g] as NSString).draw(at: NSPoint(x: margin, y: top - 30), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor(white: 0.2, alpha: 1)])
            for (i, c) in tints.enumerated() {
                caption(c.0, under: NSRect(x: margin + size * CGFloat(i), y: top - head + 19, width: size, height: 0))
                for (row, kind) in builtinKinds.enumerated() where worn(kind, c.2) {
                    drawn("idle_0", hue: c.1, kind: kind, coat: c.2).draw(in: NSRect(x: margin + size * CGFloat(i), y: top - head - size * CGFloat(row + 1), width: size, height: size))
                }
            }
        }
    }.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("colors.png"))

    // 틱마다 한 장씩 그려서 끝없이 도는 GIF 로 묶는다
    let sky = NSColor(srgbRed: 0.80, green: 0.90, blue: 0.97, alpha: 1)
    func gif(_ name: String, _ w: CGFloat, _ h: CGFloat, ticks: Int, clear: Bool = false, _ draw: (Int) -> Void) throws {   // clear 면 하늘색 바탕을 칠하지 않는다
        let url = dir.appendingPathComponent(name + ".gif")
        guard let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, ticks, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationSetProperties(out, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for t in 0..<ticks {
            let frame = bitmap(w, h) { if !clear { sky.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill() }; draw(t) }
            CGImageDestinationAddImage(out, frame.cgImage!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.18]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(out) else { throw CocoaError(.fileWriteUnknown) }
    }
    // 펫 한 마리: 그 동작의 프레임을 틱에 맞춰 돌리고, 이름표가 있으면 머리 위에 붙인다
    func pet(_ action: String, hue: CGFloat? = nil, kind: String = defaultKind, coat: String = "", at x: CGFloat, y: CGFloat = 10, tick: Int, tag: String = "") {   // hue 를 안 주면 그 종류의 기본 색이다
        let frames = actions[action]!.frames
        drawn(frames[tick % frames.count], hue: hue, kind: kind, coat: coat).draw(in: NSRect(x: x, y: y, width: size, height: size))
        guard !tag.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white]
        let width = (tag as NSString).size(withAttributes: attrs).width + 16
        let r = NSRect(x: x + size / 2 - width / 2, y: y + size + 2, width: width, height: 18)
        NSColor(white: 0.15, alpha: 0.85).setFill(); NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
        (tag as NSString).draw(at: NSPoint(x: r.minX + 8, y: r.minY + 2), withAttributes: attrs)
    }
    try menuPicture().representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("menu.png"))
    try contextPicture().representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("context.png"))
    try bitmap(200, 200) { appIcon(200).draw(in: NSRect(x: 0, y: 0, width: 200, height: 200)) }.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("icon.png"))
    try gif("working", 160, 140, ticks: 2, clear: true) { t in pet("work", kind: "dog", at: 26, tick: t) }
    try gif("waiting", 160, 140, ticks: 4, clear: true) { t in pet("call", at: 20, tick: t) }
    try gif("done", 160, 140, ticks: 8, clear: true) { t in pet("cheer", kind: "cat", at: 20, tick: t) }
    // 할 일이 없을 때 하는 놀이를 하나씩 세운다. 걷기, 달리기, 오르기, 떨어지기 같은 이동 동작은 뺀다
    let play = ["sleep", "munch", "fish", "ball", "flower", "box", "bubble", "balloon", "rope", "dance"]
    let looks: [(String, String)] = [("bunny", ""), ("dog", ""), ("cat", ""), ("bunny", "ivory"), ("dog", "shiba"), ("cat", "golden"), ("bunny", "cream"), ("dog", "pug"), ("cat", "gray"), ("bunny", "patch")]
    let perRow = 5                    // 상태 그림과 같은 크기로 보이게 다섯 마리씩 두 줄로 세운다
    try gif("idle", 30 + CGFloat(perRow) * 110, 280, ticks: 24, clear: true) { t in
        for (i, a) in play.enumerated() { pet(a, kind: looks[i].0, coat: looks[i].1, at: 10 + CGFloat(i % perRow) * 110, y: i < perRow ? 150 : 10, tick: t) }
    }
    // 가운데에 창 하나를 세우고, 그 윗변에 올라앉은 펫, 윗변에 뒷모습으로 매달린 펫, 창 앞에서 풍선을 들고 뜬 펫을 같이 보여 준다
    let win = NSRect(x: 280, y: 10, width: 250, height: 150)
    try gif("hero", 670, 285, ticks: 8) { t in
        NSColor.white.setFill(); NSBezierPath(roundedRect: win, xRadius: 10, yRadius: 10).fill()
        NSColor(white: 0.93, alpha: 1).setFill(); NSBezierPath(roundedRect: NSRect(x: win.minX, y: win.maxY - 24, width: win.width, height: 24), xRadius: 10, yRadius: 10).fill()
        NSRect(x: win.minX, y: win.maxY - 24, width: win.width, height: 10).fill()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() { c.withAlphaComponent(0.7).setFill(); NSBezierPath(ovalIn: NSRect(x: win.minX + 10 + CGFloat(i) * 15, y: win.maxY - 17, width: 10, height: 10)).fill() }
        NSColor(white: 0.90, alpha: 1).setFill()
        for (i, w) in [150, 190, 110, 170].enumerated() { NSBezierPath(roundedRect: NSRect(x: win.minX + 20, y: win.maxY - 50 - CGFloat(i) * 22, width: CGFloat(w), height: 8), xRadius: 4, yRadius: 4).fill() }
        pet("bubble", coat: "ivory", at: 10, tick: t)
        pet("call", kind: "dog", coat: "cream", at: 145, tick: t, tag: "결제 버그 수정")
        pet("balloon", kind: "cat", at: win.minX + 4, y: 18 + [0, 2, 4, 2, 0, -2, -4, -2][t], tick: t)   // 풍선에 매달려 떠 있는 것처럼 여덟 틱에 한 번 위아래로 흔들린다
        pet("work", coat: "white", at: win.minX + 30, y: win.maxY, tick: t)
        pet("hang", kind: "dog", at: win.maxX - size - 2, y: win.maxY - actions["dangle"]!.drop, tick: t)
        pet("cheer", kind: "cat", coat: "ivory", at: 530, tick: t, tag: "문서 정리")
    }
}

// 메뉴 막대의 발바닥 아이콘과 거기서 열리는 판을 그린다. 판은 앱이 쓰는 뷰(main.swift 의 Bar.panel)를 그대로 찍는다.
// 화면을 찍은 그림은 다른 아이콘과 뒤 배경이 같이 찍혀서, 예시 세션 일곱을 넣은 판만 따로 찍는다
// 화면 밖 창에 뷰를 얹어서 밝은 모양으로 찍는다
private func snapshot(_ v: NSView) -> NSBitmapImageRep {
    _ = NSApplication.shared
    let win = NSWindow(contentRect: NSRect(origin: .zero, size: v.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: .aqua); win.contentView = v; v.layoutSubtreeIfNeeded()
    let shot = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: shot)
    return shot
}
// 찍어 둔 판을 그림자 깔린 둥근 판 위에 그린다
private func panel(_ shot: NSBitmapImageRep, in r: NSRect) {
    let shape = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor(white: 0, alpha: 0.28); shadow.shadowBlurRadius = 12; shadow.shadowOffset = NSSize(width: 0, height: -3); shadow.set()
    NSColor(white: 0.965, alpha: 1).setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState(); shape.addClip(); shot.draw(in: r); NSGraphicsContext.restoreGraphicsState()
}

// 펫을 우클릭했을 때 뜨는 판. 승인을 기다리는 시바 옆에 그 펫의 판을 그린다 (main.swift 의 Card.view)
private func contextPicture() -> NSBitmapImageRep {
    let shot = snapshot(Card().view(for: Row(id: "a", name: "mochipet", state: "waiting", since: Date() - 182, kind: "dog", look: "shiba", host: "")))
    let w = shot.size.width + 150, h = shot.size.height + 60
    return bitmap(w, h) {
        NSColor(srgbRed: 0.80, green: 0.90, blue: 0.97, alpha: 1).setFill(); NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: 12, yRadius: 12).fill()
        drawn("call_0", kind: "dog", coat: "shiba").draw(in: NSRect(x: 8, y: h - size - 14, width: size, height: size))
        panel(shot, in: NSRect(x: 126, y: 24, width: shot.size.width, height: shot.size.height))
    }
}

private func menuPicture() -> NSBitmapImageRep {
    let b = Bar(), t = Date()
    scale = 1; opacity = 1; grounded = false; hidden = false     // 저장해 둔 설정과 상관없이 같은 그림이 나오게 한다
    let sample: [(String, String, Double, String, String)] = [("결제 버그 수정", "waiting", 182, "bunny", ""), ("배포 스크립트", "waiting", 18, "cat", "golden"), ("mochipet", "working", 41, "dog", ""),
        ("infra-admin", "working", 130, "bunny", "ivory"), ("로그 조사", "working", 420, "dog", "shiba"), ("문서 정리", "done", 720, "cat", ""), ("테스트 추가", "idle", 3700, "bunny", "cream")]
    b.fill(sample.enumerated().map { i, x in Row(id: "\(i)", name: x.0, state: x.1, since: t - x.2, kind: x.3, look: x.4, host: "") })   // 다섯 줄을 넘겨서 "더" 표시가 보이게 한다
    let v = b.panel
    b.refresh(); b.random.selectedSegment = 0
    let shot = snapshot(v)
    let w = v.bounds.width + 24, h = v.bounds.height + 58
    return bitmap(w, h) {
        // 메뉴 막대 한 토막과, 발바닥 아이콘 옆의 승인 대기 수
        NSColor(white: 0.90, alpha: 1).setFill(); NSBezierPath(roundedRect: NSRect(x: 0, y: h - 30, width: w, height: 30), xRadius: 9, yRadius: 9).fill()
        if let paw = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
            paw.draw(in: NSRect(x: w / 2 - 14, y: h - 15 - paw.size.height / 2, width: paw.size.width, height: paw.size.height))
        }
        ("2" as NSString).draw(at: NSPoint(x: w / 2 + 6, y: h - 23), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.systemOrange])
        panel(shot, in: NSRect(x: 12, y: 16, width: v.bounds.width, height: v.bounds.height))
    }
}
