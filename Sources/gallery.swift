import AppKit
import ImageIO
import UniformTypeIdentifiers

// 문서에 넣을 그림을 펫을 그리는 코드에서 그대로 뽑는다 (./build.sh gallery).
//   <dir>/<종류>.png                           종류마다 모든 프레임을 모은 한 장. 프레임 이름을 그 그림 바로 아래에 적는다
//   <dir>/hero.gif                             여러 상태의 펫을 한 줄로 세운 움직이는 그림
//   <dir>/working.gif, waiting.gif, done.gif   세션 상태별 동작
//   <dir>/menu.png                             메뉴바 아이콘과 거기서 열리는 메뉴
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
    func gif(_ name: String, _ w: CGFloat, _ h: CGFloat, ticks: Int, _ draw: (Int) -> Void) throws {
        let url = dir.appendingPathComponent(name + ".gif")
        guard let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, ticks, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationSetProperties(out, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for t in 0..<ticks {
            let frame = bitmap(w, h) { sky.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill(); draw(t) }
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
    try gif("working", 160, 140, ticks: 2) { t in pet("work", kind: "dog", at: 26, tick: t) }
    try gif("waiting", 160, 140, ticks: 4) { t in pet("call", at: 20, tick: t) }
    try gif("done", 160, 140, ticks: 8) { t in pet("cheer", kind: "cat", at: 20, tick: t) }
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

// 메뉴바의 발바닥 아이콘과 거기서 열리는 메뉴를 그린다. 항목과 순서는 main.swift 의 Bar.menu(inBar: true) 와 같게 둔다.
// 화면을 찍은 그림은 다른 아이콘과 뒤 배경이 같이 찍히고 다시 뽑을 수도 없어서, 다른 그림처럼 코드로 그린다
private func menuPicture() -> NSBitmapImageRep {
    let w: CGFloat = 236, h: CGFloat = 410
    return bitmap(w, h, scale: 1.25) {
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, gray: Bool = false) {
            (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: gray ? 0.66 : 0.13, alpha: 1)])
        }
        func symbol(_ name: String, _ x: CGFloat, _ y: CGFloat, _ pt: CGFloat) {      // x, y 는 가운데
            guard let i = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: pt, weight: .medium)) else { return }
            i.draw(in: NSRect(x: x - i.size.width / 2, y: y - i.size.height / 2, width: i.size.width, height: i.size.height))
        }
        func pill(_ r: NSRect, _ c: NSColor) { c.setFill(); NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill() }

        // 메뉴바 한 토막과, 눌려서 밝아진 발바닥 아이콘
        NSColor(white: 0.90, alpha: 1).setFill(); NSBezierPath(roundedRect: NSRect(x: 0, y: h - 30, width: w, height: 30), xRadius: 9, yRadius: 9).fill()
        NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: 14, y: h - 26, width: 36, height: 22), xRadius: 7, yRadius: 7).fill()
        symbol("pawprint.fill", 32, h - 15, 13)

        // 메뉴 판: 그림자를 깔고 흰 판을 얹는다
        let panel = NSRect(x: 12, y: 16, width: 212, height: h - 52), shape = NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor(white: 0, alpha: 0.28); shadow.shadowBlurRadius = 12; shadow.shadowOffset = NSSize(width: 0, height: -4); shadow.set()
        NSColor.white.setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0, alpha: 0.10).setStroke(); shape.lineWidth = 0.5; shape.stroke()

        var y = panel.maxY - 8                          // 다음 줄의 윗변
        func title(_ s: String) { y -= 22; text(s, panel.minX + 16, y + 3, gray: true) }
        func slider(_ at: CGFloat, ticks: Int = 0) {    // at 은 손잡이 자리(0~1). ticks 는 눈금 수
            y -= 26
            let track = NSRect(x: panel.minX + 20, y: y + 11, width: panel.width - 40, height: 4), knob = track.minX + 9 + (track.width - 18) * at
            for i in 0..<ticks {                            // 눈금은 트랙 아래의 짧은 세로줄
                NSColor(white: 0.70, alpha: 1).setFill()
                NSRect(x: track.minX + 9 + (track.width - 18) * CGFloat(i) / CGFloat(ticks - 1) - 0.5, y: y + 3, width: 1, height: 5).fill()
            }
            pill(track, NSColor(white: 0.86, alpha: 1)); pill(NSRect(x: track.minX, y: track.minY, width: knob - track.minX, height: 4), NSColor(white: 0.62, alpha: 1))
            NSGraphicsContext.saveGraphicsState()
            let s = NSShadow(); s.shadowColor = NSColor(white: 0, alpha: 0.3); s.shadowBlurRadius = 3; s.shadowOffset = NSSize(width: 0, height: -1); s.set()
            pill(NSRect(x: knob - 11, y: y + 6, width: 22, height: 14), .white)
            NSGraphicsContext.restoreGraphicsState()
        }
        func item(_ s: String, mark: String? = nil) { y -= 22; if let m = mark { symbol(m, panel.minX + 19, y + 11, 11) }; text(s, panel.minX + 32, y + 3) }
        func line() { y -= 11; NSColor(white: 0.87, alpha: 1).setFill(); NSRect(x: panel.minX + 12, y: y + 5, width: panel.width - 24, height: 1).fill() }

        title("투명도"); slider(1)
        title("크기"); slider(0.5, ticks: 9)
        title("속도"); slider(0.5, ticks: 3)
        title("랜덤"); item("무늬 랜덤", mark: "checkmark"); item("컬러 랜덤")
        line(); item("이 화면으로 모으기", mark: "display"); item("날지 않기", mark: "shoeprints.fill"); item("모두 색 섞기", mark: "shuffle"); item("모두 숨기기", mark: "eye.slash")
        line(); item("종료", mark: "xmark.rectangle")
    }
}
