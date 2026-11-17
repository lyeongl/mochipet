import AppKit

// 바탕화면 펫 엔진. 분석한 exe(FaFa, 2002)의 구조를 따른다:
// 동작마다 프레임 목록, 틱당 이동량, 가중치가 붙은 다음 동작, 경계에 닿았을 때의 동작을 표로 두고,
// 바라보는 방향(flip)은 상태로 들고 다닌다. 다른 창 위에 올라서는 것은 원본에 없는 기능이다.

struct Action {
    var frames: [String]            // 프레임 이름 (looks 의 자세 이름)
    var v: CGFloat = 0              // 틱당 전진량. 바라보는 쪽으로 움직인다
    var dy: CGFloat = 0             // 틱당 상승량 (AppKit 좌표라 위쪽이 +)
    var accel: CGFloat = 0          // 틱마다 dy 에 더 쌓이는 양. 음수면 중력처럼 점점 빨리 떨어진다
    var air = false                 // 발판 없이 떠 있어도 되는 동작
    var drop: CGFloat = 0           // 0 보다 크면 발판 위에서만 시작하고, 시작할 때 이만큼 내려가서 그 발판을 벗어난다
    var loops = 1...1               // 프레임 목록을 반복할 횟수 범위
    var next: [(String, Int)] = []  // (다음 동작, 가중치). 이름 앞의 "~" 는 뒤돌아서 시작한다는 뜻
    var onEdge: String? = nil       // 화면 끝에 닿거나 착지했을 때 넘어갈 동작
    var warp = false                // 시작할 때 화면의 아무 자리로 옮겨 간다 (문으로 사라졌다 나올 때)
    var onCliff: String? = nil      // 창 위를 걷다가 발판 끝이 코앞일 때 넘어갈 동작. 없으면 그냥 걸어 나가 떨어진다
}

// 문 동작의 프레임 순서. 들어갈 때: 문이 생김, 열림(두 단계), 걸어 들어감(열세 장), 빈 문, 닫힘(두 단계).
// 나올 때: 문이 생김, 열림, 뛰어나옴(세 장), 가운데에 섬, 닫힘
let doorInFrames = ["door_0", "door_0", "door_a", "door_b", "door_1"] + (1...13).map { "door_w\($0)" } + ["door_open", "door_gb", "door_ga", "door_shut", "door_shut"]
let doorOutFrames = ["door_xs", "door_xs", "door_xa", "door_xb", "door_xo", "door_o1", "door_o2", "door_o3", "door_o4", "door_o4b", "door_o4a", "door_o5", "door_o5"]

let actions: [String: Action] = [
    "idle":  Action(frames: ["idle_0", "idle_0", "idle_0", "idle_1"], loops: 1...3,
                    next: [("idle", 10), ("walk", 18), ("~walk", 18), ("run", 6), ("~run", 6), ("look", 8),
                           ("sit", 8), ("yawn", 5), ("hop", 6), ("dance", 5), ("fly", 6), ("~idle", 4), ("munch", 8),
                           ("roll", 5), ("rope", 5), ("climb", 7),
                           ("dangle", 6), ("float", 6),
                           ("fish", 4), ("ball", 4), ("balloon", 4), ("bubble", 4), ("flower", 4), ("box", 4), ("doorin", 4)]),
    "walk":  Action(frames: ["walk_0", "walk_1"], v: 6, loops: 4...14,
                    next: [("idle", 50), ("walk", 20), ("run", 10), ("sit", 10), ("hop", 10)], onEdge: "~walk", onCliff: "peek"),
    "run":   Action(frames: ["run_0", "run_1"], v: 14, loops: 4...10,
                    next: [("walk", 50), ("idle", 30), ("hop", 20)], onEdge: "~run", onCliff: "peek"),
    "roll":  Action(frames: ["roll_0", "roll_1", "roll_2", "roll_3"], v: 10, loops: 2...5,
                    next: [("dizzy", 40), ("idle", 60)], onEdge: "~roll"),   // 발판 끝에서도 멈추지 않고 굴러 떨어진다
    "rope":  Action(frames: ["rope_0", "rope_1"], loops: 6...14, next: [("idle", 80), ("yawn", 20)]),
    "peek":  Action(frames: ["peek_0", "peek_0", "peek_1", "peek_1"], loops: 2...4,   // 발판 끝에서 내려다본다
                    next: [("~walk", 55), ("hop", 25), ("sit", 20)]),
    // 바닥에서 다른 펫과 부딪혔을 때. 다가가던 쪽은 상대를 본 채 뒤로 통 떴다가 공중에서 눕고(bump), 등으로 떨어져 납작하게 뻗었다가(splat),
    // 일어나서 잠깐 어질어질해한다(getup). 그동안 내내 X 눈을 한다. 뜨는 것도 떨어질 때와 같은 중력으로 움직인다:
    // 틱마다 20, 0, -20 을 가서 세 틱 만에 20pt 높이의 낮은 포물선을 그린다. 서 있다가 받힌 쪽과 머리를 밟힌 쪽은 움찔한다(flinch)
    "bump":  Action(frames: ["ouch_0", "ouch_0", "tumble_0", "tumble_0", "tumble_0"], v: -7, dy: 40, accel: -20, next: [("bump", 100)], onEdge: "splat"),
    "splat": Action(frames: ["splat_0", "tumble_0"], next: [("getup", 100)]),
    "getup": Action(frames: ["dizzy_0", "dizzy_1"], next: [("idle", 100)]),
    "flinch": Action(frames: ["land_0"], loops: 2...2, next: [("idle", 100)]),
    // 가다가 두 번 부딪히거나 다른 펫 사이에 끼어 있으면 옆 펫의 머리를 밟고 넘어간다.
    // 두 틱 웅크렸다가(crouch) 머리 위로 뛰어올라(leap) 두 틱 밟고 서고(perch), 반대쪽으로 뛰어내린다(hopoff).
    // 떨어질 때와 같은 중력으로 움직인다. 올라갈 때는 틱마다 50, 30, 10, -10, -30 을 가서 다섯 틱 뒤에 50pt 높이(머리 위)에 닿고,
    // 내려갈 때는 30, 10, -10, -30, -50 을 가서 다섯 틱 뒤에 바닥에 닿는다. 이 높이는 펫 크기(scale)를 따라 늘고 준다.
    // 전진량은 Pet.stride 로 정해서 다섯 틱에 머리 위까지, 다시 다섯 틱에 내려앉을 자리까지 간다. 넘어가는 동안은 다른 펫을 지나간다
    "crouch": Action(frames: ["land_0"], loops: 2...2, next: [("leap", 100)]),
    "leap":  Action(frames: ["hop_0", "hop_0", "hop_0", "fall_0", "fall_1"], v: 1, dy: 70, accel: -20, air: true, next: [("perch", 100)], onEdge: "fall"),
    "perch": Action(frames: ["land_0", "land_0"], air: true, next: [("hopoff", 100)]),
    "hopoff": Action(frames: ["hop_0", "hop_0", "fall_0", "fall_1", "fall_0"], v: 1, dy: 50, accel: -20, next: [("hopoff", 100)], onEdge: "flinch"),
    // 다른 펫 위로 떨어지면 그 둘레를 따라 굴러 내려온다. 떨어지는 동작이라 바닥에 닿으면 착지한다
    "rolloff": Action(frames: ["roll_0", "roll_1", "roll_2", "roll_3"], v: 7, dy: -8, accel: -6, next: [("rolloff", 100)], onEdge: "land"),
    // 뒤에 있는 창을 등지고 타고 오른다. 창 위에 설 자리가 있으면 뷰가 거기서 멈춰 세우고,
    // 없으면 화면 꼭대기까지 가서 매달렸다가 떨어진다.
    "climb": Action(frames: ["climb_0", "climb_1"], dy: 9, air: true, loops: 400...400, next: [("fall", 100)], onEdge: "hang"),
    "hang":  Action(frames: ["hang_0", "hang_1"], air: true, loops: 5...12, next: [("fall", 100)]),
    // 아래 둘은 창 위에서 내려오는 길이다. 창 위에 있을 때만 시작한다 (drop).
    "dangle": Action(frames: ["dangle_0", "dangle_1"], air: true, drop: 68, loops: 5...12, next: [("fall", 100)]),   // 창 끝에 매달렸다가 떨어진다
    "float":  Action(frames: ["fly_0", "fly_1"], v: 4, dy: -5, air: true, drop: 6, loops: 400...400,              // 날아서 천천히 내려간다
                     next: [("fall", 100)], onEdge: "idle"),
    // 소품을 들고 노는 동작들. 소품은 그림 칸 안에 같이 그린다 (paintToy)
    // 낚시: 찌를 보며 기다리다가(fish) 찌가 잠기면 낚아 올리고 좋아한다(catch)
    "fish":  Action(frames: ["fish_0", "fish_0", "fish_1", "fish_1"], loops: 3...8, next: [("catch", 100)]),
    "catch": Action(frames: ["fish_2", "fish_2", "fish_3", "fish_3", "fish_3", "fish_3", "fish_3", "fish_3"], next: [("idle", 100)]),
    "ball":  Action(frames: ["ball_0", "ball_1", "ball_2", "ball_1"], loops: 3...8, next: [("idle", 100)]),          // 공을 발로 차올린다
    // 풍선을 잡고 비스듬히 떠오른다. 한참 올라가거나 화면 꼭대기에 닿으면 풍선이 터지고(pop) 떨어진다
    "balloon": Action(frames: ["balloon_0", "balloon_0", "balloon_1", "balloon_1"], v: 1, dy: 5, air: true, loops: 6...14, next: [("pop", 100)], onEdge: "pop"),
    "pop":   Action(frames: ["balloon_2", "balloon_2"], air: true, next: [("fall", 100)]),
    "bubble": Action(frames: ["bubble_0", "bubble_1", "bubble_2", "bubble_3"], loops: 3...8, next: [("idle", 100)]), // 비눗방울을 분다
    // 물을 주면 싹이 네 틱마다 한 단계씩 자라서 꽃이 핀다
    "flower": Action(frames: ["flower_0", "flower_0", "flower_0", "flower_0", "flower_1", "flower_1", "flower_1", "flower_1",
                              "flower_2", "flower_2", "flower_2", "flower_2", "flower_3", "flower_3", "flower_3", "flower_3", "flower_3", "flower_3"], next: [("idle", 100)]),
    // 상자 뒤로 내려가 숨었다가 튀어나온다
    "box":   Action(frames: ["box_0", "box_0", "box_1", "box_1", "box_2", "box_2", "box_2", "box_2", "box_2", "box_2", "box_3", "box_3", "box_3", "box_3"], next: [("idle", 100)]),
    // 문으로 사라졌다가 화면의 다른 자리에서 나온다. 뒤에 문이 생겨 열리면 오른쪽으로 걸어 들어가고(doorin),
    // 문이 닫혀 사라진 사이에 아무 자리로 옮겨 가서(doorgone), 거기서 문이 열리면 왼쪽으로 뛰어나온다(doorout). 공중이면 나온 뒤에 떨어진다.
    // 문이 서 있는 동안은 떠 있어도 떨어지지 않고(air), 다른 펫과 부딪히지 않는다 (Pet.meet)
    "doorin":  Action(frames: doorInFrames, air: true, next: [("doorgone", 100)]),
    "doorgone": Action(frames: ["door_none", "door_none", "door_none"], air: true, next: [("doorout", 100)], warp: true),
    "doorout": Action(frames: doorOutFrames, air: true, next: [("idle", 100)]),
    "look":  Action(frames: ["look_0", "look_0", "idle_0", "look_1", "look_1", "idle_0", "look_2", "look_2"],
                    next: [("idle", 70), ("walk", 15), ("~walk", 15)]),
    // 민들레를 씹는다. 한 번 씹을 때마다(네 틱) 줄기가 한 마디씩 줄어서, 여섯 번 씹으면 다 먹는다
    "munch":  Action(frames: (0..<12).flatMap { ["munch_\($0)", "munch_\($0)"] }, next: [("idle", 70), ("sit", 30)]),
    "yawn":  Action(frames: ["yawn_0", "yawn_1", "yawn_1", "yawn_1", "yawn_0"], next: [("idle", 50), ("sit", 50)]),
    "dance": Action(frames: ["happy_0", "happy_1", "happy_2", "happy_3"], loops: 2...5, next: [("idle", 80), ("hop", 20)]),   // 음표가 네 틱에 걸쳐 떠오른다
    "sit":   Action(frames: ["sit_0"], loops: 6...16, next: [("idle", 50), ("sleep", 35), ("yawn", 15)]),
    "sleep": Action(frames: ["sleep_0", "sleep_0", "sleep_1", "sleep_1", "sleep_2", "sleep_2", "sleep_3", "sleep_3"], loops: 3...10, next: [("sit", 100)]),   // 콧방울이 여덟 틱에 한 번 커졌다 작아진다
    "hop":   Action(frames: ["hop_0"], v: 5, dy: 12, air: true, loops: 3...5, next: [("fall", 100)], onEdge: "fall"),
    "fly":   Action(frames: ["fly_0", "fly_1"], v: 3, dy: 7, air: true, loops: 10...40,
                    next: [("fall", 70), ("fly", 15), ("~fly", 15)], onEdge: "fall"),
    "fall":  Action(frames: ["fall_0", "fall_1"], dy: -12, accel: -20, next: [("fall", 100)], onEdge: "land"),
    "land":  Action(frames: ["land_1", "land_2"], next: [("idle", 70), ("dizzy", 30)]),   // 납작해지면서 발 옆으로 먼지가 퍼진다
    "dizzy": Action(frames: ["dizzy_0", "dizzy_1"], loops: 3...5, next: [("idle", 100)]),
    "held":  Action(frames: ["held_0", "held_1"], air: true, next: [("held", 100)]),   // 마우스로 잡고 있는 동안
    // 아래 셋은 mood 로만 들어간다 (Claude 버전)
    "work":  Action(frames: ["work_0", "work_1"], loops: 20...50, next: [("idle", 100)]),
    "rush":  Action(frames: ["run_0", "run_1"], v: 14, loops: 3...6, next: [("idle", 70), ("~idle", 30)], onEdge: "~rush", onCliff: "~rush"),
    "cheer": Action(frames: ["cheer_0", "cheer_1", "cheer_2", "cheer_3", "cheer_4", "cheer_5", "cheer_6", "cheer_7"], loops: 2...2, next: [("idle", 100)]),
    "call":  Action(frames: ["call_0", "call_1", "call_2", "call_3"], loops: 2...4, next: [("idle", 100)]),
]

let leaping: Set = ["crouch", "leap", "perch", "hopoff"]   // 머리를 밟고 넘어가는 동작들
let flying: Set = ["fly", "float", "balloon", "climb"]     // 바닥을 떠나는 동작들: 날기, 창 위에서 날아 내려오기, 풍선 타기, 창 타고 오르기
var grounded = false                                        // 켜면 바닥에만 있는다: flying 동작을 고르지 않고, 창 윗변을 발판으로 치지 않는다. 메뉴 막대 아이콘의 "날지 않기" 에서 고른다

struct Pet {
    var pos: CGPoint
    var name = "idle"
    var flip = false                // false = 왼쪽을 본다
    var frame = 0
    var loopsLeft = 1
    var speed: CGFloat = 0          // accel 이 쌓인 속도. 다른 동작으로 넘어가면 0 으로 돌아간다
    var partial: CGFloat = 1        // 이번 틱에 가려던 거리 중 실제로 간 비율. 바닥에 막히면 1 보다 작다
    var fresh = false               // 방금 시작한 동작이라 아직 한 틱도 안 지났다
    var mood = "idle"               // idle, working, waiting, done. Claude 세션의 상태를 따라간다
    var rest = 0                    // 부딪힌 뒤 다시 반응하지 않는 틱 수
    var jam = 0                     // 다른 펫에게 가다가 부딪힌 횟수. 두 번이 되면 그 펫의 머리를 밟고 넘어간다
    var squeezed = 0                // 다른 펫과 겹친 채로 지난 틱 수
    var goal: CGFloat = 0           // 내려앉을 자리 (펫 원점의 x)
    var stride: CGFloat = 1         // 전진량에 곱하는 값. 머리를 밟고 넘을 때만 갈 거리에 맞춰 바꾼다
    var action: Action { actions[name]! }
    var sprite: String { action.frames[frame] }

    mutating func start(_ n: String) {
        var n = n
        if n.hasPrefix("~") { flip.toggle(); n.removeFirst() }
        if grounded && flying.contains(n) { n = "idle" }   // 날지 않기: 바닥을 떠나는 동작 대신 가만히 섰다가 다른 동작을 다시 고른다
        // idle 은 다음 동작을 고르는 갈림목이다. mood 에 따라 여기서 일하기나 축하로 보낸다.
        if n == "idle" && mood == "working" { n = Int.random(in: 0..<100) < 85 ? "work" : "rush" }   // 대부분 일하고 가끔만 뛴다
        if n == "idle" && mood == "waiting" { n = "call" }
        // 끝나면 확인받을 때까지(mood 가 바뀔 때까지) 계속 축하한다
        if n == "idle" && mood == "done" { n = "cheer" }
        if n != name { speed = 0 }
        if !leaping.contains(n) { stride = 1 }
        if n == "doorin" { flip = true }        // 문에는 늘 왼쪽에서 오른쪽으로 들어가고,
        if n == "doorout" { flip = false }      // 오른쪽에서 왼쪽으로 나온다
        if n == "hopoff" { stride = abs(goal - pos.x) / 5 }
        name = n; frame = 0; loopsLeft = Int.random(in: action.loops); fresh = true
    }

    // 한 틱 진행한다. area 는 펫 원점(왼쪽 아래)이 있을 수 있는 범위,
    // floor(x, y) 는 x 위치에서 y 이하에 있는 가장 높은 발판의 높이다.
    mutating func tick(in area: CGRect, floor: (CGFloat, CGFloat) -> CGFloat) {
        if fresh {
            fresh = false
            if action.warp {        // 바닥부터 화면 높이의 0.6 까지, 아무 자리로 간다. 공중이면 문에서 나온 뒤에 떨어진다. 날지 않기를 켰으면 바닥으로만 간다
                pos = CGPoint(x: .random(in: area.minX...area.maxX), y: .random(in: area.minY...(area.minY + (grounded ? 0 : area.height * 0.6))))
            }
            if action.drop > 0 {    // 창 위에 서 있을 때만 시작한다. 아니면 없던 일로 한다
                let drop = action.drop * scale   // 그림 기준 높이라서 화면 배율을 곱한다
                let onLedge = pos.y - drop >= area.minY && pos.y == floor(pos.x, pos.y)
                if onLedge { pos.y -= drop } else { start("idle"); fresh = false }
            }
        }
        let ground = floor(pos.x, pos.y)
        if pos.y > ground && !action.air && action.accel >= 0 { start("fall") }   // 발판이 없으면 떨어진다 (이미 떨어지는 동작은 그대로 둔다)
        let a = action
        partial = 1
        // 내려가는 중인데 이미 바닥이면 착지한다. 바닥에 닿은 틱에는 닿기만 하고, 다음 틱에 여기서 넘어간다.
        // 뛰어오르는 동작은 중력을 받아도 올라가는 동안에는 바닥에 있어도 착지가 아니다
        if a.dy + speed < 0 && pos.y <= ground, let e = a.onEdge { start(e); return }
        // 창 위를 걷는데 두 틱 뒤면 발판이 끝난다
        if a.v > 0, pos.y > area.minY, pos.y == ground, let c = a.onCliff,
           floor(pos.x + (flip ? 2 : -2) * a.v, pos.y) < pos.y { start(c); return }
        speed = max(speed + a.accel, -180)
        let dy = (a.dy + speed) * (leaping.contains(name) ? scale : 1)   // 머리를 밟고 넘을 때는 펫 크기에 맞는 높이로 뛴다
        let v = a.v * stride
        pos.x += flip ? v : -v
        pos.y += dy
        let side = v != 0 && (pos.x < area.minX || pos.x > area.maxX)
        let top = a.dy > 0 && pos.y > area.maxY
        if dy < 0 && pos.y < ground { partial = (pos.y - dy - ground) / -dy }
        pos.x = min(max(pos.x, area.minX), area.maxX)
        pos.y = min(max(pos.y, ground), area.maxY)
        if side || top, let e = a.onEdge { start(a.accel < 0 && pos.y > ground ? "fall" : e); return }   // 떠서 벽에 닿았으면 그 자리에서 떨어진다
        frame += 1
        guard frame == a.frames.count else { return }
        frame = 0; loopsLeft -= 1
        guard loopsLeft <= 0 else { return }
        var r = Int.random(in: 0..<a.next.reduce(0) { $0 + $1.1 })
        for (n, w) in a.next { if r < w { start(n); return }; r -= w }
    }
}

extension Pet {
    // 펫은 서로 겹치지 않는 공처럼 다룬다. others 는 다른 펫 창들의 자리이고, 겹치면 그 둘레 밖으로 밀려난다.
    //   위에서 떨어지거나 떠 있다가 닿으면: 둘레에 얹히고, 바깥쪽을 보며 굴러 내려간다 (rolloff)
    //   바닥에서 나란히 닿으면: 옆으로 밀려나고, 다가가던 쪽은 뒤로 떴다가 넘어지고(bump, splat) 서 있던 쪽은 움찔한다(flinch)
    //   가다가 두 번 부딪히거나 2초 넘게 겹쳐 있으면: 옆 펫의 머리를 밟고 그 너머의 빈자리로 넘어간다 (crouch, leap, perch, hopoff)
    mutating func meet(_ others: [CGRect], in area: CGRect) {
        if rest > 0 { rest -= 1 }
        // 밟고 선 펫이 그사이 자리를 떴으면 떨어진다
        if name == "perch", !others.contains(where: { abs($0.midX - pos.x - side / 2) < side / 2 && $0.minY < pos.y && pos.y - $0.minY < side }) { start("fall") }
        guard !leaping.contains(name), !name.hasPrefix("door") else { squeezed = 0; return }   // 넘어가는 동안은 다른 펫을 지나간다. 내려앉은 뒤에 겹쳐 있으면 그때 밀려난다
        let half = side / 2
        func reach(_ o: CGRect) -> CGFloat { 0.65 * (half + o.width / 2) }   // 두 몸의 중심이 이보다 가까워지지 않는다. 둘 다 120pt 면 78 이다
        var touching = false, bumped = false
        for o in others {
            var dx = pos.x + half - o.midX, dy = pos.y + half - o.midY   // 상대 중심에서 내 중심을 향한 방향
            guard hypot(dx, dy) < reach(o) else { continue }
            if o.minY - pos.y > 24 * scale {                     // 위에 있는 펫은 그쪽이 굴러 내려가거나 밟고 넘어간다. 아래 있는 나는 밀리지 않고, 머리를 밟히면 움찔한다
                if abs(dx) < 20 * scale, rest == 0, name != "flinch", !action.air, action.accel >= 0 { rest = 10; start("flinch") }
                continue
            }
            touching = true
            if abs(dx) < 1 { dx = Bool.random() ? 1 : -1 }       // 정확히 위아래로 겹쳤으면 아무 쪽으로나 굴러간다
            if pos.y - o.minY > 24 * scale || action.air || action.accel < 0 {   // 발이 상대보다 높이 있다
                let d = max(hypot(dx, dy), 1)
                pos = CGPoint(x: o.midX + dx / d * reach(o) - half, y: o.midY + max(dy, 0) / d * reach(o) - half)
                flip = dx > 0                                    // 상대의 반대쪽을 본다
                if name != "rolloff" { start("rolloff") }
            } else {
                let away: CGFloat = dx > 0 ? 1 : -1
                pos.x += away * min(reach(o) - abs(dx), 16)
                guard rest == 0, !bumped, name != "bump", name != "splat", name != "getup", name != "flinch" else { continue }
                bumped = true; rest = 10
                if action.v > 0 && (flip ? 1 : -1) == -away {    // 내가 상대 쪽으로 가던 중이었다: 상대를 본 채 뒤로 튄다
                    jam += 1
                    flip = away < 0; start("bump")
                } else {
                    start("flinch")                              // 서 있다가 받혔다
                }
            }
        }
        pos.x = min(max(pos.x, area.minX), area.maxX)            // 밀려나도 화면 밖으로는 나가지 않는다
        squeezed = touching ? squeezed + 1 : 0
        guard jam >= 2 || squeezed >= 14, !action.air, action.accel >= 0, name != "bump", name != "splat", name != "getup" else { return }   // 넘어진 펫은 일어난 뒤에 뛴다
        // 밟을 펫과 내려앉을 자리를 찾는다. dir 쪽으로 가까운 펫부터 차례로 보고, 나와 같은 바닥에 서 있고 그 펫 바로 너머가 화면 안이고 비어 있으면 그 펫을 밟는다
        let me = pos.x + half, row = others.filter { abs($0.minY - pos.y) < side * 0.6 }
        func landing(_ dir: CGFloat) -> (CGFloat, CGFloat)? {
            for o in row.filter({ ($0.midX - me) * dir > 0 && abs($0.minY - pos.y) < 1 }).sorted(by: { abs($0.midX - me) < abs($1.midX - me) }) {
                let spot = o.midX + dir * (reach(o) + 8)
                guard abs(spot - me) <= 320 else { break }       // 다섯 틱에 틱당 46pt 쯤까지만 뛴다
                if (area.minX...area.maxX).contains(spot - half), !row.contains(where: { abs($0.midX - spot) < reach($0) }) { return (spot, o.midX) }
            }
            return nil
        }
        // 막혀서 뛸 때는 가던 쪽(막은 펫 너머)을 먼저 보고, 끼어서 뛸 때는 펫이 적은 쪽을 먼저 본다
        let ahead: CGFloat = jam >= 2 ? (flip ? 1 : -1) : (row.filter { $0.midX < me }.count * 2 > row.count ? 1 : -1)
        jam = min(jam, 1); squeezed = 0
        guard let (spot, head) = landing(ahead) ?? landing(-ahead) else { return }   // 넘어갈 자리가 없으면 한 번 더 부딪혔을 때 다시 본다
        jam = 0; flip = spot > me
        start("crouch"); stride = abs(head - me) / 5; goal = spot - half; rest = 10
    }
}

let size: CGFloat = 120              // 그림을 그리는 칸의 한 변. 화면에 띄우는 크기는 side 다

// 화면에 띄우는 모습. 그림은 늘 size 칸에 그리고, 창을 side 크기로 띄워서 줄이거나 늘린다.
// MochiPet 의 메뉴 막대 아이콘이 바꾼다. 바꾼 뒤에는 allPets 마다 applyLook() 을 부른다.
var scale: CGFloat = 1               // 0.5 ~ 1.5. 메뉴 막대 슬라이더가 도트 한 칸이 화면 픽셀 정수 개가 되는 값으로 맞춰서 넣는다
var opacity: CGFloat = 1
var hidden = false                   // 모든 펫을 숨기고 멈춘다
var side: CGFloat { (size * scale).rounded() }
// 떠 있는 펫들. 끈 펫의 창도 한동안 NSApp.windows 에 남아 있어서 host 로 걸러낸다.
// 안 거르면 크기를 바꿀 때 끈 펫이 다시 나타나서, 타이머가 죽은 채로 멈춰 서 있게 된다.
var allPets: [PetView] { NSApp.windows.compactMap { $0.contentView as? PetView }.filter { $0.host != nil } }
let tick = 0.15                      // 틱 간격(초)

// 프레임별 자세. 펫 종류가 달라도 같은 표를 쓴다. 왼쪽을 보는 모습으로 그린다.
enum Eyes { case open, closed, wide, happy, dizzy }
struct Look {
    var w: CGFloat = 84, h: CGFloat = 70    // 몸 크기
    var lift: CGFloat = 12                  // 몸 바닥 높이
    var shift: CGFloat = 0                  // 몸 좌우 치우침
    var eyes = Eyes.open
    var gaze = CGPoint.zero                 // 눈 위치 치우침
    var mouth: CGFloat = 0                  // 입 크기 (0 = 없음)
    var step: CGFloat? = 0                  // 발 벌림 (nil = 발 숨김)
    var foot: CGFloat = 10                  // 발 높이
    var kick: CGFloat = 0                   // 한 발은 이만큼 올리고 다른 발은 내린다
    var ears: CGFloat = 8                   // 귀를 옆으로 벌린 각도
    var sway: CGFloat = 0                   // 두 귀의 끝을 한쪽으로 함께 기울인 각도. +는 오른쪽이다
    var perk: CGFloat = 0                   // 토끼 귀를 위로 올린 칸 수
    var roll: CGFloat = 0                   // 몸 전체를 돌린 각도. +는 앞(왼쪽)으로 숙이고 -는 뒤로 넘어간다
    var mark = ""                           // 머리 옆 글자
    var hammer: Bool? = nil                 // 망치: false = 든 모습, true = 내리친 모습
    var confetti = 0                        // 꽃가루: 0 = 없음, 1~8 = 떨어지는 여덟 틱 가운데 몇 번째인가
    var snack: CGFloat = 0                  // 물고 있는 민들레 줄기의 길이 (0 = 없음, 1 = 여섯 마디)
    var rope = 0                            // 줄넘기 줄: 1 = 머리 위, 2 = 발 아래
    var back = false                        // 뒷모습. 얼굴을 그리지 않는다
    var hands: (CGFloat, CGFloat)? = nil    // 두 손의 높이(왼손, 오른손). 몸 양옆 테두리에 걸쳐서 그린다
    var toy = ""                            // 몸에 곁들여 그리는 것. 소품(fish, ball, balloon, bubble, flower, box), 문(door, doorL, doorM, doorR),
                                            // 작은 효과(zzz, notes, bang, dust, trail, what). paintToy 가 그린다
    var phase = 0                           // 그 소품의 몇 번째 모습인가
    var wag: CGFloat = 0                    // 뒷모습에서 꼬리를 옆으로 옮기는 거리. 매달려 있을 때 꼬리를 흔든다
    var flick = 0                           // 강아지의 보는 쪽 귀에서 아래 절반을 바깥으로 민 칸 수. 귀 위는 몸에 붙인 채 끝만 팔락인다
}
let looks: [String: Look] = [
    "idle_0": Look(), "idle_1": Look(eyes: .closed),
    "look_0": Look(gaze: CGPoint(x: -8, y: 0)), "look_1": Look(gaze: CGPoint(x: 8, y: 0)),
    "look_2": Look(gaze: CGPoint(x: 0, y: 6), toy: "what"),
    "walk_0": Look(gaze: CGPoint(x: -8, y: 0), step: -7),
    "walk_1": Look(lift: 16, gaze: CGPoint(x: -8, y: 0), step: 7),
    "run_0": Look(w: 92, h: 62, gaze: CGPoint(x: -12, y: 0), step: -12, toy: "trail", phase: 0),       // 달릴 때는 뒤에 먼지가 남는다
    "run_1": Look(w: 92, h: 62, lift: 18, gaze: CGPoint(x: -12, y: 0), step: 12, toy: "trail", phase: 1),
    "sit_0": Look(lift: 4, step: nil),      // 앉아도 몸 크기는 서 있을 때와 같다. 발만 숨기고 내려앉는다
    // 잠: 숨 쉬는 두 몸에 콧방울과 z 의 네 모습을 얹는다
    "sleep_0": Look(lift: 4, eyes: .closed, step: nil, toy: "zzz", phase: 0), "sleep_1": Look(lift: 4, eyes: .closed, step: nil, toy: "zzz", phase: 1),
    "sleep_2": Look(w: 86, h: 68, lift: 4, eyes: .closed, step: nil, toy: "zzz", phase: 2),
    "sleep_3": Look(w: 86, h: 68, lift: 4, eyes: .closed, step: nil, toy: "zzz", phase: 3),
    "yawn_0": Look(eyes: .closed, mouth: 8), "yawn_1": Look(w: 80, h: 78, eyes: .closed, mouth: 16),
    // 춤: 두 자세를 번갈아 하고, 음표는 네 틱에 걸쳐 떠오른다
    "happy_0": Look(shift: -4, eyes: .happy, toy: "notes", phase: 0), "happy_1": Look(lift: 18, shift: 4, eyes: .happy, step: 6, toy: "notes", phase: 1),
    "happy_2": Look(shift: -4, eyes: .happy, toy: "notes", phase: 2), "happy_3": Look(lift: 18, shift: 4, eyes: .happy, step: 6, toy: "notes", phase: 3),
    "hop_0": Look(w: 76, h: 80, lift: 14, eyes: .happy, step: 4),
    "fly_0": Look(lift: 16, eyes: .happy, step: 3, ears: 68), "fly_1": Look(lift: 16, eyes: .happy, step: 5, ears: 2),
    "fall_0": Look(w: 68, h: 78, eyes: .wide, mouth: 8, step: -4, foot: 12, kick: 5, ears: 10.5),
    "fall_1": Look(w: 68, h: 78, eyes: .wide, mouth: 8, step: 4, foot: 12, kick: -5, ears: 28),
    "land_0": Look(w: 94, h: 60, lift: 6, eyes: .closed),
    "land_1": Look(w: 94, h: 60, lift: 6, eyes: .closed, toy: "dust", phase: 0), "land_2": Look(w: 94, h: 60, lift: 6, eyes: .closed, toy: "dust", phase: 1),   // 떨어져 내려앉을 때는 먼지가 인다
    "dizzy_0": Look(shift: -5, eyes: .dizzy), "dizzy_1": Look(shift: 5, eyes: .dizzy),
    "held_0": Look(w: 66, h: 84, lift: 16, eyes: .wide, step: 2),
    "held_1": Look(w: 66, h: 84, lift: 16, eyes: .wide, step: 6),
    "work_0": Look(w: 78, h: 61, lift: 4, shift: 16, gaze: CGPoint(x: -10, y: -2), step: nil, ears: 4, perk: 1, hammer: false),   // 망치를 들면 두 귀가 모여서 한 칸 올라가고,
    "work_1": Look(w: 80, h: 60, lift: 4, shift: 16, eyes: .closed, gaze: CGPoint(x: -10, y: -4), step: nil, ears: 14, hammer: true),   // 내리치면 내려앉으며 벌어진다
    // 축하: 두 자세를 번갈아 하고, 꽃가루는 여덟 틱에 걸쳐 떨어진다
    "cheer_0": Look(eyes: .happy, step: 6, confetti: 1), "cheer_1": Look(w: 78, h: 72, lift: 26, eyes: .happy, mouth: 10, step: 2, foot: 22, confetti: 2),
    "cheer_2": Look(eyes: .happy, step: 6, confetti: 3), "cheer_3": Look(w: 78, h: 72, lift: 26, eyes: .happy, mouth: 10, step: 2, foot: 22, confetti: 4),
    "cheer_4": Look(eyes: .happy, step: 6, confetti: 5), "cheer_5": Look(w: 78, h: 72, lift: 26, eyes: .happy, mouth: 10, step: 2, foot: 22, confetti: 6),
    "cheer_6": Look(eyes: .happy, step: 6, confetti: 7), "cheer_7": Look(w: 78, h: 72, lift: 26, eyes: .happy, mouth: 10, step: 2, foot: 22, confetti: 8),
    "roll_0": Look(lift: 20, eyes: .happy, step: nil, roll: 45), "roll_1": Look(lift: 20, eyes: .happy, step: nil, roll: 135),
    "roll_2": Look(lift: 20, eyes: .happy, step: nil, roll: 225), "roll_3": Look(lift: 20, eyes: .happy, step: nil, roll: 315),
    "rope_0": Look(eyes: .happy, rope: 1), "rope_1": Look(lift: 28, eyes: .happy, step: 3, foot: 22, rope: 2),
    "peek_0": Look(shift: -8, eyes: .wide, gaze: CGPoint(x: -10, y: -10), mouth: 6, roll: 12, mark: "!"),
    "peek_1": Look(shift: -8, eyes: .wide, gaze: CGPoint(x: -10, y: -10), mouth: 11, roll: 12, mark: "!!"),
    // 부딪혀 넘어지는 모습: 뒤로 뜸(ouch_0), 누움(tumble_0), 등으로 떨어져 길게 뻗음(splat_0). 내내 X 눈이고 발과 입은 그리지 않는다.
    // 누운 모습은 뒤로 90도 돌린 것이다. 그림은 90도 단위로만 돌린다
    "ouch_0": Look(w: 68, h: 78, eyes: .dizzy, step: nil, ears: 10.5),
    "tumble_0": Look(lift: 20, eyes: .dizzy, step: nil, roll: -45),
    "splat_0": Look(w: 64, h: 86, lift: 4, eyes: .dizzy, step: nil, roll: -45),
    "climb_0": Look(shift: -2, step: -3, kick: 5, ears: 13, sway: 11, back: true, hands: (48, 56)),      // 뒷모습으로 손과 발을 엇갈려 딛는다. 귀도 한 번씩 좌우로 기운다
    "climb_1": Look(lift: 16, shift: 2, step: 3, kick: -5, ears: 13, sway: -11, back: true, hands: (60, 52)),
    "hang_0": Look(lift: 18, step: 4, foot: 14, back: true, hands: (64, 64), wag: -2),      // 어깨 높이의 두 손으로 턱을 잡는다. 머리가 턱 위로 조금 올라온다
    "hang_1": Look(lift: 18, shift: 3, step: 4, foot: 14, back: true, hands: (64, 64), wag: 2),
    "dangle_0": Look(lift: 18, eyes: .wide, mouth: 6, step: 4, foot: 14, hands: (64, 64)),   // 앞모습으로 창 끝에 매달린다
    "dangle_1": Look(lift: 18, shift: 3, eyes: .closed, mouth: 6, step: 4, foot: 14, hands: (64, 64)),
    // 낚시: 앉아서 왼쪽 물에 찌를 띄운다. 0·1 찌가 오르내림, 2 찌가 잠김, 3 낚아 올림
    "fish_0": Look(lift: 4, shift: 16, gaze: CGPoint(x: -8, y: 0), step: nil, toy: "fish", phase: 0),
    "fish_1": Look(lift: 4, shift: 16, gaze: CGPoint(x: -8, y: 0), step: nil, toy: "fish", phase: 1),
    "fish_2": Look(lift: 4, shift: 16, eyes: .wide, gaze: CGPoint(x: -8, y: 0), step: nil, mark: "!", toy: "fish", phase: 2),
    "fish_3": Look(lift: 4, shift: 16, eyes: .happy, gaze: CGPoint(x: -8, y: 0), step: nil, toy: "fish", phase: 3),
    // 공놀이: 공이 발, 가운데, 꼭대기에 있는 세 모습. 눈이 공을 따라간다
    "ball_0": Look(shift: 14, gaze: CGPoint(x: -8, y: -4), kick: 6, toy: "ball", phase: 0),
    "ball_1": Look(shift: 14, gaze: CGPoint(x: -8, y: 0), toy: "ball", phase: 1),
    "ball_2": Look(shift: 14, gaze: CGPoint(x: -8, y: 6), toy: "ball", phase: 2),
    // 풍선: 0·1 풍선이 좌우로 흔들림, 2 터짐
    "balloon_0": Look(lift: 20, eyes: .happy, step: 4, foot: 16, toy: "balloon", phase: 0),
    "balloon_1": Look(lift: 20, eyes: .happy, step: 4, foot: 16, toy: "balloon", phase: 1),
    "balloon_2": Look(lift: 20, eyes: .wide, mouth: 8, step: 4, foot: 16, toy: "balloon", phase: 2),
    // 비눗방울: 방울 네 개가 한 틱씩 어긋나서 올라가다 터진다. 입은 그리지 않고 분홍 코를 둔다
    "bubble_0": Look(shift: 14, gaze: CGPoint(x: -8, y: 0), toy: "bubble", phase: 0),
    "bubble_1": Look(shift: 14, gaze: CGPoint(x: -8, y: 0), toy: "bubble", phase: 1),
    "bubble_2": Look(shift: 14, gaze: CGPoint(x: -8, y: 0), toy: "bubble", phase: 2),
    "bubble_3": Look(shift: 14, gaze: CGPoint(x: -8, y: 0), toy: "bubble", phase: 3),
    // 꽃 키우기: 0~2 물을 주는 동안 싹이 자람, 3 꽃이 핌
    "flower_0": Look(shift: 16, gaze: CGPoint(x: -8, y: -4), toy: "flower", phase: 0),
    "flower_1": Look(shift: 16, gaze: CGPoint(x: -8, y: -4), toy: "flower", phase: 1),
    "flower_2": Look(shift: 16, gaze: CGPoint(x: -8, y: -4), toy: "flower", phase: 2),
    "flower_3": Look(shift: 16, eyes: .happy, gaze: CGPoint(x: -8, y: -4), toy: "flower", phase: 3),
    // 상자에 숨기: 0 상자 뒤에 섬, 1 귀만 보임, 2 귀 끝만 보임, 3 튀어나옴. 몸을 그림 칸 아래로 내려서 숨긴다
    "box_0": Look(gaze: CGPoint(x: -6, y: 0), step: nil, toy: "box", phase: 0),
    "box_1": Look(lift: -16, step: nil, toy: "box", phase: 1),
    "box_2": Look(lift: -36, step: nil, toy: "box", phase: 2),
    "box_3": Look(lift: 22, eyes: .happy, mouth: 8, step: nil, mark: "!", hands: (62, 62), toy: "box", phase: 3),
    // 부르기: 서 있다가 뛰어오르고, 말풍선은 틱마다 한 칸씩 오르내린다
    "call_0": Look(eyes: .wide, toy: "bang", phase: 0), "call_1": Look(eyes: .wide, toy: "bang", phase: 1),
    "call_2": Look(w: 78, h: 76, lift: 24, eyes: .wide, mouth: 10, step: 3, foot: 20, toy: "bang", phase: 2),
    "call_3": Look(w: 78, h: 76, lift: 24, eyes: .wide, mouth: 10, step: 3, foot: 20, toy: "bang", phase: 3),
].merging(doorLooks) { a, _ in a }.merging(munchLooks) { a, _ in a }

// 민들레를 씹는 프레임 (munch_0 ~ munch_11). 입을 다문 장과 벌린 장이 한 쌍이고, 쌍이 넘어갈 때마다 줄기가 한 마디씩 줄어든다
let munchLooks: [String: Look] = Dictionary(uniqueKeysWithValues: (0..<12).map { i in
    let left = CGFloat(6 - i / 2) / 6, see = CGPoint(x: -4, y: -2)
    return ("munch_\(i)", i % 2 == 0 ? Look(gaze: see, snack: left) : Look(w: 86, h: 68, gaze: see, mouth: 5, snack: left))
})

// 문 동작의 프레임. toy 는 문을 어떻게 그릴지다: door 는 문만, doorL 은 문 안쪽 왼쪽 끝을 지난 몸을 자르고,
// doorM 은 문의 좌우를 바꾸고, doorR 은 좌우를 바꾸고 문 안쪽 오른쪽 끝을 지난 몸을 자른다. phase 는 0 닫힘, 2·3 열리는 중, 1 다 열림.
// 몸을 그림 칸 아래로 내리면(lift -200) 문만 보인다
let doorLooks: [String: Look] = {
    let gone = Look(lift: -200, step: nil), see = CGPoint(x: -8, y: 0)
    func alone(_ toy: String, _ phase: Int) -> Look { var l = gone; l.toy = toy; l.phase = phase; return l }
    var l: [String: Look] = [
        "door_none": gone,
        // 들어갈 때 (펫이 오른쪽을 봐서 그림이 뒤집힌다): 문이 생김, 열림, 다 열림
        "door_0": Look(eyes: .wide, gaze: see, mark: "!", toy: "door", phase: 0),
        "door_a": Look(eyes: .wide, gaze: see, toy: "door", phase: 2), "door_b": Look(eyes: .wide, gaze: see, toy: "door", phase: 3),
        "door_1": Look(eyes: .wide, gaze: see, toy: "door", phase: 1),
        "door_open": alone("door", 1), "door_gb": alone("door", 3), "door_ga": alone("door", 2), "door_shut": alone("door", 0),
        // 나올 때 (펫이 왼쪽을 본다): 문이 생김, 열림, 문 안쪽 오른쪽 끝에서 뛰어나옴, 가운데에 섬, 닫힘
        "door_xs": alone("doorM", 0), "door_xa": alone("doorM", 2), "door_xb": alone("doorM", 3), "door_xo": alone("doorM", 1),
        "door_o1": Look(w: 80, h: 72, lift: 14, shift: 62, eyes: .happy, step: 4, toy: "doorR", phase: 1),
        "door_o2": Look(w: 80, h: 72, lift: 14, shift: 34, eyes: .happy, step: 4, toy: "doorR", phase: 1),
        "door_o3": Look(w: 80, h: 72, lift: 12, shift: 10, eyes: .happy, step: 4, toy: "doorR", phase: 1),
        "door_o4": Look(eyes: .happy, toy: "doorM", phase: 1), "door_o4b": Look(eyes: .happy, toy: "doorM", phase: 3),
        "door_o4a": Look(eyes: .happy, toy: "doorM", phase: 2), "door_o5": Look(eyes: .happy, toy: "doorM", phase: 0),
    ]
    for i in 1...13 {       // 걸어 들어간다: 한 장에 6pt 씩 옆으로 가고, 걷는 두 자세를 번갈아 한다
        let up = i % 2 == 0
        l["door_w\(i)"] = Look(lift: up ? 16 : 12, shift: CGFloat(-6 * i), gaze: see, step: up ? 7 : -7, toy: "doorL", phase: 1)
    }
    return l
}()
// 강아지의 보는 쪽 귀 끝을 바깥으로 미는 프레임 (Look.flick). 망치를 내리칠 때 귀 위는 그대로 두고 아래만 한 칸 벌린다
let dogFlick: [String: Int] = ["work_1": 1]
// 강아지는 귀가 옆으로 늘어져서 같은 각도로는 모양이 안 나온다. 망치질과 오르기의 귀 각도(ears, sway)는 따로 정한다.
// 망치질·달리기·구르기에서는 프레임마다 귀를 들었다 붙여서 팔딱이게 한다. 망치는 내리칠 때, 달릴 때는 몸이 내려오는 프레임에서 귀가 들린다
let dogEars: [String: (CGFloat, CGFloat)] = [
    "work_0": (5, 6), "work_1": (9, 14),          // 망치: 왼쪽 귀는 162도 그대로 두고(끝만 dogFlick 으로 민다), 오른쪽 귀는 150도에서 134도로 든다
    "climb_0": (8, 12), "climb_1": (8, -12),
    "run_0": (9, 6), "run_1": (2, 0),             // 내려올 때 귀를 들고(122도·116도) 올라갈 때 조금만 내린다(128도·136도). 더 내리면 물방울 귀가 몸 위에 얹혀서 네모로 보인다
    "roll_0": (6, 0), "roll_1": (-4, 0), "roll_2": (6, 0), "roll_3": (-4, 0),
    "tumble_0": (-7, 0), "splat_0": (-7, 0),      // 넘어졌을 때는 귀를 몸에 붙인다. 벌어져 있으면 위쪽 귀가 몸에서 떨어져 떠 보인다
]

// 색상환 위치 h(0~1)의 색을 OKLCH 로 만든다. 밝기 L 과 채도 C 를 고정하므로 어느 색이든 똑같이 부드럽다.
// HSB 로 만들면 연두·노랑 쪽만 형광처럼 튄다.
func oklch(_ L: Double, _ C: Double, _ h: Double) -> NSColor {
    let a = C * cos(2 * .pi * h), b = C * sin(2 * .pi * h)
    let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
    let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
    let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
    func gamma(_ x: Double) -> CGFloat {
        CGFloat(min(max(x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055, 0), 1))
    }
    return NSColor(srgbRed: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                   green: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                   blue: gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s), alpha: 1)
}

// 펫 종류. 같은 자세 표(looks)를 종류마다 다르게 그린다.
//   bunny   도트 토끼 (기본). 같은 도형을 30x30 칸에 계단지게 그린 뒤 키운다
//   dog     도트 강아지. 토끼와 몸이 같고 귀·꼬리·주둥이만 다르다
//   cat     도트 고양이. 토끼와 몸이 같고 귀·꼬리·입·수염만 다르다
// 그 밖의 이름은 기본 종류로 그린다.
let builtinKinds = ["bunny", "dog", "cat"]
// 색상환으로 못 고르는 색. 색 줄에 숫자 대신 이름으로 적는다 (paintPet 참고). kinds 가 비어 있으면 모든 종류가 쓴다.
// 이 색들이 무늬 줄이다. 흰색과 크림은 컬러 줄(색상환 색)에도 들어간다. 나머지는 실제 품종의 털 무늬를 담은 색이다.
// 이 순서대로 우클릭 메뉴와 색상 표(gallery 의 colors.png)에 나온다
//   white    흰 몸. 강아지는 귀와 꼬리만 크림색, 고양이는 흰 고양이가 된다
//   ivory    아이보리. 따뜻한 흰색 몸이 배 쪽으로 두 단계 옅어져서 순백이 된다
//   cream    크림. 색상환 68도의 파스텔 몸에 살구색 볼이 몸 경계에서 안쪽으로 옅어지고, 귀 안쪽과 꼬리도 살구색이다.
//            컬러 줄의 크림은 무늬가 아니라 같은 각도의 색상환 색(creamHue)이라서 볼이 없는 단색이다
//   gray     회갈색. 배 쪽으로 두 단계 옅어져서 흰색이 된다
//   silver   은회색. 회색과 같은 모양이고 몸 색만 푸른 회색이다
//   patch    얼룩. 흰 몸에 머리 꼭대기에서 눈 아래까지 내려오는 반원 얼룩이 있다. 토끼는 더치(양쪽 연갈색), 강아지는 점박이(한쪽 연갈색), 고양이는 삼색(주황과 고동색)이다
//   pug      퍼그. 연갈색 몸에 귀와 꼬리가 진갈색이고, 갈색 주둥이 둘레로 두 단계 옅어진다
//   golden   골든. 토끼와 강아지는 황금색 몸에 머리 위가 진하고 배가 옅은 골든이고(강아지는 기본 색과 같다), 고양이는 치즈(주황 몸, 흰 배, 이마 줄무늬)다
//   shiba    시바. 황토색 몸에 큰 흰 배, 흰 눈썹 점
//   siamese  샴. 고양이의 기본 색과 같다. 이름으로도 고를 수 있게 둔다
let coats: [(en: String, ko: String, kinds: [String])] = [
    ("white", "흰색", []), ("ivory", "아이보리", []), ("cream", "크림", []),
    ("gray", "회색", []), ("silver", "은회색", []), ("golden", "골든", []), ("patch", "얼룩", []), ("pug", "퍼그", ["dog"]), ("shiba", "시바", ["dog"]), ("siamese", "샴", ["cat"]),
]
// 그 종류가 쓸 수 있는 색인지
func wears(_ kind: String, _ coat: (en: String, ko: String, kinds: [String])) -> Bool { coat.kinds.isEmpty || coat.kinds.contains(kind) }
// 얼룩으로 묶기 전에 쓰던 이름. 세션 파일에 남아 있을 수 있어서 얼룩으로 읽는다
// 컬러 줄의 흰색은 색 줄에 plain 으로 적는다. 무늬 줄의 흰색(white)에서 분홍 볼만 뺀 것이고, 이름으로 고르는 색은 아니다
let creamHue = 0.19                   // 크림의 색상환 위치(0~1). 컬러 줄의 크림은 이 색상환 색이고, 무늬 줄의 크림(cream)은 여기에 살구 볼을 얹는다
let coatAlias = ["calico": "patch", "삼색": "patch", "dutch": "patch", "더치": "patch"]
let defaultKind = "bunny"            // 종류를 정하지 않은 펫이 쓰는 종류
let pink = NSColor(srgbRed: 1, green: 0.64, blue: 0.70, alpha: 1)
// 고양이가 무는 생선. 가시는 흰 몸 위에서도 보이게 회색으로 칠한다
let fishBlue = oklch(0.72, 0.08, 240.0 / 360), fishDeep = oklch(0.60, 0.09, 245.0 / 360), fishBelly = oklch(0.93, 0.02, 230.0 / 360)
let fishSpine = NSColor(white: 0.80, alpha: 1), fishRib = NSColor(white: 0.66, alpha: 1)
let brown = NSColor(srgbRed: 0.55, green: 0.40, blue: 0.28, alpha: 1)
// 소품 색
let toyBlue = NSColor(srgbRed: 0.42, green: 0.68, blue: 0.94, alpha: 1), toySky = NSColor(srgbRed: 0.72, green: 0.87, blue: 0.98, alpha: 1)
let toyRed = NSColor(srgbRed: 0.93, green: 0.38, blue: 0.38, alpha: 1), toyYellow = NSColor(srgbRed: 0.98, green: 0.80, blue: 0.30, alpha: 1)
let toyGreen = NSColor(srgbRed: 0.45, green: 0.72, blue: 0.36, alpha: 1), toyGray = NSColor(white: 0.62, alpha: 1), toyDark = NSColor(white: 0.30, alpha: 1)
let toyWood = NSColor(srgbRed: 0.72, green: 0.54, blue: 0.36, alpha: 1), toyBox = NSColor(srgbRed: 0.82, green: 0.66, blue: 0.46, alpha: 1)
// 민들레 색: 잎의 밝은 쪽과 짙은 쪽, 꽃잎, 꽃잎 모서리, 꽃 가운데
let leafLight = NSColor(srgbRed: 0.62, green: 0.84, blue: 0.45, alpha: 1), leafDeep = NSColor(srgbRed: 0.30, green: 0.56, blue: 0.30, alpha: 1)
let petal = NSColor(srgbRed: 0.99, green: 0.84, blue: 0.30, alpha: 1), petalPale = NSColor(srgbRed: 1.0, green: 0.93, blue: 0.60, alpha: 1)
let petalCore = NSColor(srgbRed: 0.96, green: 0.62, blue: 0.22, alpha: 1)
// 뼈 달린 고기 색: 뼈, 뼈의 그늘, 고기, 고기의 윤기
let bone = NSColor(srgbRed: 0.95, green: 0.89, blue: 0.76, alpha: 1), boneShade = NSColor(srgbRed: 0.80, green: 0.71, blue: 0.56, alpha: 1)
let meat = NSColor(srgbRed: 0.74, green: 0.40, blue: 0.28, alpha: 1), meatGlaze = NSColor(srgbRed: 0.88, green: 0.56, blue: 0.38, alpha: 1)
// 문 색: 문틀, 문짝, 문짝의 그늘, 손잡이와 별, 문 안, 문턱
let doorRim = NSColor(srgbRed: 0.93, green: 0.60, blue: 0.72, alpha: 1), doorPanel = NSColor(srgbRed: 0.99, green: 0.82, blue: 0.88, alpha: 1)
let doorShade = NSColor(srgbRed: 0.97, green: 0.72, blue: 0.81, alpha: 1), doorKnob = NSColor(srgbRed: 0.99, green: 0.84, blue: 0.42, alpha: 1)
let doorNight = NSColor(srgbRed: 0.33, green: 0.26, blue: 0.42, alpha: 1), doorSill = NSColor(srgbRed: 0.84, green: 0.47, blue: 0.60, alpha: 1)

func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor) {
    c.setFill(); NSBezierPath(ovalIn: NSRect(x: x - w / 2, y: y - h / 2, width: w, height: h)).fill()
}
// 아래 넷은 4pt 칸에 맞춰 찍는다. 작은 부품을 타원으로 그리면 자세마다 다르게 뭉개져서 테두리가 뚫리거나 선이 끊긴다.
func snap(_ v: CGFloat) -> CGFloat { (v / 4).rounded() * 4 }
func dot(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor) {   // x, y 는 왼쪽 아래, w, h 는 칸 수
    c.setFill(); NSRect(x: snap(x), y: snap(y), width: w * 4, height: h * 4).fill()
}
func lump(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ rim: NSColor, _ fill: NSColor) {   // 모서리를 한 칸씩 뺀 w x h칸 덩어리. 테두리 안쪽을 fill 로 채운다. x, y 는 가운데
    let l = snap(x - w * 2), b = snap(y - h * 2)
    rim.setFill(); NSRect(x: l + 4, y: b, width: (w - 2) * 4, height: h * 4).fill(); NSRect(x: l, y: b + 4, width: w * 4, height: (h - 2) * 4).fill()
    fill.setFill(); NSRect(x: l + 4, y: b + 4, width: (w - 2) * 4, height: (h - 2) * 4).fill()
}
func cellLine(_ a: NSPoint, _ b: NSPoint, _ c: NSColor) {                          // 선이 지나는 칸을 모두 칠한다. 모서리로만 이어지는 곳이 없다
    let n = max(Int(max(abs(b.x - a.x), abs(b.y - a.y))), 1)
    c.setFill()
    for i in 0...n {
        let t = CGFloat(i) / CGFloat(n)
        NSRect(x: floor((a.x + (b.x - a.x) * t) / 4) * 4, y: floor((a.y + (b.y - a.y) * t) / 4) * 4, width: 4, height: 4).fill()
    }
}
func stroke(_ pts: [NSPoint], _ c: NSColor, _ width: CGFloat) {
    let p = NSBezierPath(); p.move(to: pts[0]); pts.dropFirst().forEach(p.line(to:))
    p.lineWidth = width; c.setStroke(); p.stroke()
}

// 몸 색의 밝기와 채도. 색 밝기를 고르는 메뉴가 있었는데, 단계끼리 차이가 작아서 가장 밝은 단계 하나로 고정했다.
// base 는 색을 정한 펫의 털, 그늘, 테두리, 강아지 귀 순서의 (밝기, 채도)다.
// yellow 는 노랑 근처에서 base 대신 쓰는 값이다. 다른 색과 같은 밝기·채도로는 노랑이 올리브색으로 보여서 더 밝고 진하게 준다.
// plain 은 색을 정하지 않은 토끼(흰색)의 그늘과 테두리다
let palette: (base: [(L: Double, C: Double)], yellow: [(L: Double, C: Double)], plain: (shade: NSColor, edge: NSColor)) = (
    [(0.965, 0.035), (0.92, 0.055), (0.85, 0.08), (0.80, 0.10)], [(0.965, 0.06), (0.92, 0.085), (0.85, 0.115), (0.80, 0.13)],
    (NSColor(srgbRed: 0.96, green: 0.955, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.86, green: 0.84, blue: 0.82, alpha: 1)))

// 몸 색 한 가지. role 은 0 털, 1 그늘, 2 테두리, 3 강아지 귀다.
// 노랑(색상환 100도) 근처는 yellow 쪽으로 섞는다. 100도에서 전부 섞이고, 30도 떨어지면 안 섞인다
func pastel(_ role: Int, _ h: Double) -> NSColor {
    let base = palette.base[role], yellow = palette.yellow[role]
    let away = abs(h * 360 - 100), mix = max(0, 1 - min(away, 360 - away) / 30)
    return oklch(base.L + (yellow.L - base.L) * mix, base.C + (yellow.C - base.C) * mix, h)
}

// hue 는 몸 색의 색상환 위치(0~1)다. 파스텔로 칠하고 선은 같은 색을 어둡게 쓴다. nil 이면 종류마다 정한 기본색.
func drawn(_ name: String, hue: CGFloat? = nil, kind: String = defaultKind, coat: String = "") -> NSImage {
    var k = looks[name] ?? Look()
    if kind == "dog", let e = dogEars[name] { (k.ears, k.sway) = e }
    if kind == "dog" { k.flick = dogFlick[name] ?? 0 }
    return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        func turned(_ angle: CGFloat, about c: NSPoint) {   // 몸 가운데를 축으로 돌린다
            guard angle != 0 else { return }
            let t = NSAffineTransform()
            t.translateX(by: c.x, yBy: c.y); t.rotate(byDegrees: angle); t.translateX(by: -c.x, yBy: -c.y); t.concat()
        }
        let line = hue.map { oklch(0.36, 0.04, Double($0)) } ?? NSColor(srgbRed: 0.36, green: 0.30, blue: 0.28, alpha: 1)
        // 도트 그림은 90도 단위로만, 칸 경계를 축으로 돌린다. 그래야 눈·코 같은 한 칸짜리가 뭉개지지 않는다
        pixelated {
            turned((k.roll / 90).rounded() * 90, about: NSPoint(x: snap(size / 2 + k.shift), y: snap(k.lift + k.h * 0.39)))
            paintPet(k, hue, line, dog: kind == "dog", cat: kind == "cat", coat: coat)
        }
        if !k.mark.isEmpty {             // 머리 옆 글자. 길면 오른쪽 끝에 맞춘다
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: k.mark.count > 1 ? 17 : k.mark == "z" ? 16 : 22),
                                                         .foregroundColor: line]
            let width = (k.mark as NSString).size(withAttributes: attrs).width
            (k.mark as NSString).draw(at: NSPoint(x: min(size - 28, size - 3 - width), y: size - 38), withAttributes: attrs)
        }
        return true
    }
}

// 도형을 grid x grid 칸에 계단지게 그린 뒤 원래 크기로 키워서 도트 그림처럼 만든다.
func pixelated(grid: Int = 30, _ paint: () -> Void) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: grid, pixelsHigh: grid, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let small = NSGraphicsContext(bitmapImageRep: rep), let outer = NSGraphicsContext.current else { return }
    NSGraphicsContext.current = small
    small.shouldAntialias = false
    let t = NSAffineTransform(); t.scale(by: CGFloat(grid) / size); t.concat()
    paint()
    NSGraphicsContext.current = outer
    rep.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false,
             hints: [.interpolation: NSNumber(value: NSImageInterpolation.none.rawValue)])
}

// 도형을 따로 찍어서 칠해진 칸의 번호를 얻는다. 번호는 그림 칸의 왼쪽 아래가 (0, 0)이고, 그림 칸 밖으로 pad 칸까지 담는다.
// 찍힌 칸을 고친 다음에 그리고 싶을 때 쓴다
func cellsOf(pad: Int = 15, _ paint: () -> Void) -> Set<[Int]> {
    let n = 30 + pad * 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let scratch = NSGraphicsContext(bitmapImageRep: rep), let outer = NSGraphicsContext.current else { return [] }
    NSGraphicsContext.current = scratch
    scratch.shouldAntialias = false
    let t = NSAffineTransform(); t.scale(by: 30 / size); t.translateX(by: CGFloat(pad) * 4, yBy: CGFloat(pad) * 4); t.concat()
    paint()
    NSGraphicsContext.current = outer
    var cells = Set<[Int]>()
    for y in 0..<n { for x in 0..<n where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { cells.insert([x - pad, n - 1 - y - pad]) } }
    return cells
}

func paintPet(_ k: Look, _ hue: CGFloat?, _ line: NSColor, dog: Bool, cat: Bool = false, coat: String = "") {
    let cx = size / 2 + k.shift
    let w = k.w * 0.8, h = k.h * 0.78    // 토끼 귀가 들어갈 자리를 남기려고 몸을 조금 작게 그린다
    let coat = coatAlias[coat] ?? coat
    let white = coat == "white" || coat == "plain" || (!dog && !cat && coat.isEmpty && hue == nil), fixed = ["ivory", "gray", "silver", "patch", "pug", "shiba"].contains(coat) || (!dog && coat == "golden")   // fixed: 정해진 색으로 그리는 이름 있는 색. 모르는 이름은 기본 색으로 그린다
    let hue = white ? nil : hue ?? (coat == "cream" ? creamHue : nil)   // 색을 정하지 않으면 토끼는 흰색, 강아지는 골든, 고양이는 샴이다
    var fur = hue.map { pastel(0, Double($0)) } ?? NSColor(white: 0.985, alpha: 1)
    var shade = hue.map { pastel(1, Double($0)) } ?? palette.plain.shade
    var edge = hue.map { pastel(2, Double($0)) } ?? palette.plain.edge
    var dark = hue.map { pastel(3, Double($0)) } ?? edge   // 강아지 귀, 강아지와 고양이 꼬리
    if dog && white { dark = oklch(0.86, 0.035, 70.0 / 360) }   // 흰 강아지의 귀와 꼬리는 연한 크림색. 테두리 색 그대로면 귀가 회색으로 보인다
    // 무늬. 몸 위에 얹는 얼룩(patches), 얼룩 옆의 몸 테두리(rims), 귀·발 색을 따로 정한다. 얼룩은 (가운데 x, y, 폭, 높이, 색)의 타원이다
    var earFur: [CGFloat: NSColor] = [:], earEdge: [CGFloat: NSColor] = [:], paw: NSColor? = nil
    var patches: [(CGFloat, CGFloat, CGFloat, CGFloat, NSColor)] = [], rims = patches
    var muzzle = NSColor.white           // 강아지 주둥이 색
    var whisker = hue == nil ? oklch(0.70, 0.01, 60.0 / 360) : edge      // 흰 몸에서는 테두리 색 수염이 안 보여서 더 진한 회색을 쓴다
    let face = NSPoint(x: cx + k.gaze.x, y: k.lift + k.h * 0.78 / 2 + 2 + k.gaze.y), crown = k.lift + k.h * 0.78   // 눈높이와 머리 꼭대기
    if cat && coat == "patch" {          // 고양이 얼룩은 삼색: 흰 몸에 머리 왼쪽 주황, 오른쪽 고동색. 가운데 이마는 흰색으로 남긴다
        let orange = oklch(0.80, 0.105, 66.0 / 360), orangeEdge = oklch(0.70, 0.11, 63.0 / 360)
        let brown = oklch(0.60, 0.05, 50.0 / 360), brownEdge = oklch(0.54, 0.05, 50.0 / 360)
        (fur, shade, edge, dark) = (NSColor(white: 0.985, alpha: 1), oklch(0.92, 0.03, 72.0 / 360), oklch(0.76, 0.065, 66.0 / 360), oklch(0.66, 0.115, 62.0 / 360))   // 꼬리는 귀 테두리보다 한 단계 진한 주황
        // 머리 꼭대기에서 눈 아래 한 칸까지 내려오는 반원 두 개. 얼룩 옆의 몸 테두리는 귀 테두리와 같은 색으로 칠해서 귀와 머리가 이어져 보이게 한다.
        // 뒷모습에서는 같은 얼룩을 뒤통수에 그리고, 뒤에서 보는 것이므로 귀와 얼룩의 좌우를 바꾼다
        let flip: CGFloat = k.back ? -1 : 1, mid = k.back ? cx : face.x, reach = (crown - (face.y - 7)) * 2
        earFur = [-flip: orange, flip: brown]; earEdge = [-flip: orangeEdge, flip: brownEdge]
        patches = [(mid - flip * 20, crown, 34, reach, orange), (mid + flip * 22, crown, 30, reach, brown)]
        rims = [(mid - flip * 20, crown, 42, reach + 8, orangeEdge), (mid + flip * 22, crown, 38, reach + 8, brownEdge)]
    }
    var stripe: NSColor? = nil, brows = false     // 고양이 이마 줄무늬 색, 시바 눈썹 점
    // 몸 색 하나(밝기, 채도, 색상환 각도)에서 그늘, 테두리(rim), 귀·꼬리(deep) 색을 내고, 배 가운데로 갈수록 두 단계 옅어져서 흰색이 되게 한다.
    // 뒷모습에서는 같은 그라데이션을 두 칸 아래에 그려서 몸 아랫단만 옅어지고 꼬리 둘레는 몸 색으로 남는다. grow 는 배의 흰 부분을 키우는 크기(pt)다
    let belly = k.lift + k.h * 0.78 * 0.14 - (k.back ? 8 : 0)
    // 머리 위의 진한 띠. 뒷모습에서는 몸 색(f)에서 띠 색(c)까지 세 단계로 나눠서 경계가 한 줄로 보이지 않게 한다. 색은 (밝기, 채도, 색상환 각도)다
    func crownBand(_ f: (Double, Double, Double), _ c: (Double, Double, Double)) -> [(CGFloat, CGFloat, CGFloat, CGFloat, NSColor)] {
        let tall = (crown - (face.y - 7)) * 1.8
        guard k.back else { return [(face.x, crown + 6, 84, tall, oklch(c.0, c.1, c.2 / 360))] }
        return (0..<3).map { i in
            let t = Double(i + 1) / 3
            return (cx, crown + 6, 84, tall * (1.3 - 0.25 * CGFloat(i)), oklch(f.0 + (c.0 - f.0) * t, f.1 + (c.1 - f.1) * t, (f.2 + (c.2 - f.2) * t) / 360))
        }
    }
    func fade(_ l: Double, _ c: Double, _ h: Double, rim: Double, deep: Double, grow: CGFloat = 0) {
        (fur, shade, edge, dark) = (oklch(l, c, h / 360), oklch(l - 0.06, c + 0.002, h / 360), oklch(rim, c + 0.005, h / 360), oklch(deep, c + 0.008, h / 360))
        whisker = edge
        patches = [(cx, belly, 70 + grow, 48 + grow, oklch(l + (0.985 - l) * 0.35, c * 0.8, h / 360)), (cx, belly, 62 + grow, 40 + grow, oklch(l + (0.985 - l) * 0.7, c * 0.5, h / 360)),
                   (cx, belly, 54 + grow, 32 + grow, NSColor(white: 0.985, alpha: 1))]
    }
    if coat == "gray" || coat == "silver" {  // 회색과 은회색
        // 테두리는 몸보다 한 단계만 진하게 둔다. 강아지 귀·꼬리와 고양이 꼬리는 그보다 더 진하게 해서 몸에서 떨어져 보이게 한다 (은회색은 채도가 낮아서 조금 더)
        let rim = cat ? 0.68 : 0.70, deep = dog ? (coat == "gray" ? 0.64 : 0.62) : cat ? (coat == "gray" ? 0.62 : 0.60) : rim
        if coat == "gray" { fade(0.80, 0.02, 60, rim: rim, deep: deep) } else { fade(0.81, 0.012, 250, rim: rim, deep: deep) }
    }
    // 볼터치: 몸 경계 가까이에서 가장 진하고 얼굴 안쪽으로 네 단계 옅어진다. color 는 단계(0~1. 1이 가장 진하다)마다 칠할 색이고, drop 은 아래로 내리는 높이(pt)다. 뒷모습에는 없다
    func cheeks(drop: CGFloat = 0, _ color: (Double) -> NSColor) {
        guard !k.back else { return }
        for i in 0..<4 {
            let sz = 44 - CGFloat(i) * 34 / 4
            for sd in [-1, 1] as [CGFloat] { patches.append((face.x + sd * 36, face.y - 10 - drop, sz, sz * 0.8, color(Double(i + 1) / 4))) }
        }
    }
    if white && coat != "plain" { cheeks(drop: 4) { oklch(0.985 - 0.03 * $0 * 0.7, 0.05 * $0 * 0.7, 20.0 / 360) } }   // 무늬 줄의 흰색: 눈 한 칸 아래에 연한 분홍 볼. 컬러 줄의 흰색(plain)은 볼이 없다
    if coat == "cream" {                     // 크림: 살구색 볼. 귀 안쪽과 꼬리도 살구색이다
        cheeks(drop: 4) { t in oklch(0.965 + (0.915 - 0.965) * t, 0.035 + (0.068 - 0.035) * t, (68.4 + (54 - 68.4) * t) / 360) }
        let ear = oklch(0.91, 0.068, 56.0 / 360), deep = oklch(0.84, 0.085, 58.0 / 360)
        earFur = [-1: ear, 1: ear]; earEdge = [-1: deep, 1: deep]; dark = deep
    }
    if coat == "ivory" {                     // 아이보리: 따뜻한 흰색 몸에 배만 순백이고 분홍 볼이 있다. 테두리와 귀·꼬리는 몸과 같은 각도에서 어둡게만 하면 올리브빛이 돌아서 따로 준다
        fade(0.955, 0.022, 85, rim: 0.85, deep: dog ? 0.82 : 0.80)
        (edge, dark) = (oklch(0.86, 0.04, 75.0 / 360), oklch(0.82, 0.05, 72.0 / 360)); whisker = oklch(0.74, 0.03, 70.0 / 360)
        cheeks(drop: 4) { _ in oklch(0.86, 0.10, 20.0 / 360).withAlphaComponent(0.16 * 0.7) }   // 반투명 분홍을 네 겹 겹친다. 불투명하게 칠하면 배 그라데이션이 볼에서 잘려 보인다
    }
    if cat && coat == "golden" {             // 고양이 골든은 치즈: 주황 몸에 옅은 배, 이마에 줄무늬 세 줄. 배 색은 골든 토끼·강아지와 같다 (순백으로 두면 고양이만 흰 배가 된다)
        fade(0.86, 0.09, 72, rim: 0.74, deep: 0.72); stripe = oklch(0.72, 0.12, 62.0 / 360)
        patches[0].4 = oklch(0.91, 0.06, 80.0 / 360); patches[1].4 = oklch(0.945, 0.042, 84.0 / 360); patches[2].4 = oklch(0.975, 0.022, 88.0 / 360)
    }
    if dog && coat == "shiba" {              // 시바: 머리 위가 한 단계 진하고, 흰 배가 볼까지 크게 올라온다. 눈 위 안쪽에 흰 눈썹 점을 찍는다
        fade(0.86, 0.085, 72, rim: 0.76, deep: 0.70, grow: 6); brows = true
        // 테두리와 귀·꼬리는 몸보다 주황 쪽 색으로 따로 준다. 몸과 같은 각도(72도)에서 어둡게만 하면 올리브빛 갈색이 된다
        (edge, dark) = (oklch(0.74, 0.10, 68.0 / 360), oklch(0.68, 0.116, 64.0 / 360))
        patches[0].4 = oklch(0.90, 0.06, 76.0 / 360); patches[1].4 = oklch(0.95, 0.035, 82.0 / 360)
        patches = crownBand((0.86, 0.085, 72), (0.82, 0.10, 68)) + patches
    }
    if dog && coat == "patch" {              // 강아지 얼룩은 점박이: 더치 토끼의 오른쪽 얼룩과 같은 반원을 한쪽 눈에만 그린다. 뒷모습에서는 좌우를 바꾼다.
        // 몸 테두리는 한 색으로 둔다. 얼룩 옆만 다른 색이면 귀가 덮은 곳까지 머리 윗선이 세 가지 색으로 끊겨 보인다
        (fur, shade, edge, dark) = (NSColor(white: 0.985, alpha: 1), oklch(0.93, 0.02, 75.0 / 360), oklch(0.72, 0.055, 66.0 / 360), oklch(0.62, 0.075, 60.0 / 360))
        patches = [(k.back ? cx - 21 : face.x + 21, crown, 32, (crown - (face.y - 7)) * 2, oklch(0.78, 0.06, 65.0 / 360))]
    }
    if (dog && hue == nil && !white && !fixed) || (!dog && !cat && coat == "golden") {   // 강아지 기본 색은 골든 (모르는 색 이름이 적혀 있어도 기본으로 그린다): 황금색 몸에 머리 위가 한 단계 진하고, 배 쪽으로 두 단계 옅어진다
        // 테두리는 귀·꼬리보다 연하게 둔다. 테두리가 더 진하면 귀와 꼬리가 몸에 묻혀 보인다
        (fur, shade, edge, dark) = (oklch(0.88, 0.075, 76.0 / 360), oklch(0.83, 0.085, 74.0 / 360), oklch(0.78, 0.092, 70.0 / 360), oklch(0.74, 0.108, 66.0 / 360))
        patches = crownBand((0.88, 0.075, 76), (0.85, 0.09, 72))
        patches += [(cx, belly, 70, 48, oklch(0.91, 0.06, 80.0 / 360)), (cx, belly, 62, 40, oklch(0.945, 0.042, 84.0 / 360)), (cx, belly, 54, 32, oklch(0.975, 0.022, 88.0 / 360))]
    }
    if dog && coat == "pug" {                // 퍼그: 주둥이를 갈색으로 칠하고 그 둘레를 두 단계로 옅게 한다
        (fur, shade, edge, dark) = (oklch(0.90, 0.045, 80.0 / 360), oklch(0.85, 0.055, 78.0 / 360), oklch(0.72, 0.065, 70.0 / 360), oklch(0.50, 0.035, 50.0 / 360))
        muzzle = oklch(0.64, 0.045, 55.0 / 360)
        if !k.back { patches = [(face.x, face.y - 9, 44, 34, oklch(0.84, 0.05, 72.0 / 360)), (face.x, face.y - 9, 36, 26, oklch(0.75, 0.05, 64.0 / 360))] }
    }
    if !dog && !cat && coat == "patch" {   // 토끼 얼룩은 더치다: 머리 꼭대기에서 눈 아래 한 칸까지 내려오는 반원을 양쪽에 그린다. 좌우가 같아서 뒷모습에서도 그대로다
        let tan = oklch(0.78, 0.06, 65.0 / 360), tanEdge = oklch(0.72, 0.065, 64.0 / 360)
        (fur, shade, edge) = (NSColor(white: 0.985, alpha: 1), oklch(0.93, 0.02, 75.0 / 360), oklch(0.80, 0.035, 70.0 / 360))
        earFur = [-1: tan, 1: tan]; earEdge = [-1: tanEdge, 1: tanEdge]
        let mid = k.back ? cx : face.x, reach = (crown - (face.y - 7)) * 2
        for side in [-21, 21] as [CGFloat] { patches.append((mid + side, crown, 32, reach, tan)); rims.append((mid + side, crown, 40, reach + 8, tanEdge)) }
    }
    if cat && hue == nil && !white && !fixed {   // 고양이 기본 색은 샴 (모르는 색 이름이 적혀 있어도 기본으로 그린다): 크림색 몸에 귀·꼬리·발이 갈색이고, 얼굴 가운데 갈색이 두 단계로 옅어진다
        let point = oklch(0.66, 0.06, 55.0 / 360)
        (fur, shade, edge, dark) = (oklch(0.95, 0.025, 80.0 / 360), oklch(0.90, 0.035, 78.0 / 360), oklch(0.76, 0.05, 65.0 / 360), point)
        earFur = [-1: point, 1: point]; earEdge = [-1: oklch(0.50, 0.06, 55.0 / 360), 1: oklch(0.50, 0.06, 55.0 / 360)]; paw = point; whisker = edge
        if !k.back {
            patches = [(face.x, face.y - 7, 52, 40, oklch(0.91, 0.03, 75.0 / 360)), (face.x, face.y - 7, 44, 32, oklch(0.86, 0.038, 68.0 / 360)),
                       (face.x, face.y - 7, 36, 24, oklch(0.80, 0.045, 62.0 / 360))]
        }
    }
    let turn = k.gaze.x                  // 옆을 볼수록 귀가 그쪽으로 가고 반대쪽에 꼬리가 보인다
    if k.toy.hasPrefix("door") {
        // 문 안쪽과 문짝을 몸보다 먼저 그리고, 문 안쪽 끝을 지난 몸은 안 보이게 자른다. 자른 것은 paintToy 가 문틀을 그리기 전에 되돌린다
        paintDoor(k.phase, mirror: k.toy == "doorM" || k.toy == "doorR")
        NSGraphicsContext.saveGraphicsState()
        if k.toy == "doorL" { NSBezierPath(rect: NSRect(x: 20, y: 0, width: 100, height: size)).addClip() }
        if k.toy == "doorR" { NSBezierPath(rect: NSRect(x: 0, y: 0, width: 100, height: size)).addClip() }
    }
    if k.confetti > 0 {
        // 꽃가루: 아홉 줄기가 떨어진다. 줄기마다 속도(한 틱에 한 칸 또는 두 칸)와 모양이 다르고, 네 틱에 한 번 좌우로 흔들린다.
        // 빠른 줄기는 16칸, 느린 줄기는 8칸 간격이라 여덟 틱 뒤에는 한 간격만큼 내려와서 처음 모습과 이어진다. 몸보다 먼저 그려서 얼굴을 가리지 않는다
        let colors = [NSColor.systemPink, .systemYellow, .systemBlue, .systemGreen, .systemPurple, .systemOrange]
        // (칸, 어긋난 틱 수, 속도, 종류). 종류 0 은 틱마다 가로·세로로 뒤집히는 두 칸, 2 는 한 칸, 3 은 네 칸과 가로 두 칸을 오간다
        let streams: [(Int, Int, Int, Int)] = [(1, 0, 2, 0), (4, 5, 1, 2), (7, 2, 2, 3), (11, 7, 1, 0), (15, 4, 2, 2), (19, 1, 1, 0), (22, 6, 2, 0), (25, 3, 1, 2), (28, 5, 2, 3)]
        for (i, s) in streams.enumerated() {
            let step = (k.confetti - 1 + s.1) % 8
            for band in 0..<(32 / (8 * s.2)) {
                let col = s.0 + [0, 1, 0, -1][step % 4], row = step * s.2 + band * 8 * s.2
                guard (0...27).contains(row), (0...29).contains(col) else { continue }
                let shape = s.3 == 0 ? step % 2 : s.3 == 3 ? (step % 2 == 0 ? 3 : 0) : 2   // 0 가로 두 칸, 1 세로 두 칸, 2 한 칸, 3 네 칸
                dot(CGFloat(col) * 4, CGFloat(29 - row) * 4, shape == 1 || shape == 2 ? 1 : 2, shape == 0 || shape == 2 ? 1 : 2, colors[(i + band) % 6])
            }
        }
    }
    // 몸: 타원 아래에 조금 더 넓은 타원을 겹쳐서 찹쌀떡처럼 아래가 퍼지게 한다.
    // 몸 꼭대기가 칸 경계 위로 1pt 도 안 되게 걸치면 속 색 몇 칸만 한 줄 더 튀어나와서 머리 윗줄 테두리가 끊겨 보인다. 그때는 꼭대기를 칸 경계에 맞춘다
    let over = k.lift + h - floor((k.lift + h) / 4) * 4, tall = over < 1 ? h - over : h
    func blob(grow: CGFloat = 0, dx: CGFloat = 0, dy: CGFloat = 0) -> NSBezierPath {
        let p = NSBezierPath(ovalIn: NSRect(x: cx - w / 2, y: k.lift, width: w, height: tall).insetBy(dx: -grow, dy: -grow).offsetBy(dx: dx, dy: dy))
        p.append(NSBezierPath(ovalIn: NSRect(x: cx - w * 0.56, y: k.lift, width: w * 1.12, height: h * 0.6)
            .insetBy(dx: -grow, dy: -grow).offsetBy(dx: dx, dy: dy)))
        return p
    }
    if let s = k.step {                  // 발: 테두리 4x3칸에 속 2x1칸
        for (x, y) in [(cx - 16 + s, k.foot + k.kick), (cx + 16 - s, k.foot - k.kick)] { dot(x - 8, y - 6, 4, 3, paw ?? edge); dot(x - 4, y - 2, 2, 1, paw == nil ? fur : edge) }
    }
    // 길쭉한 타원을 한쪽 끝(at)을 축으로 돌려서 귀와 강아지 꼬리를 그린다. angle 은 곧게 선 데서 바깥으로 눕힌 각도다
    func limb(_ side: CGFloat, at p: NSPoint, _ width: CGFloat, _ len: CGFloat, _ up: CGFloat, _ angle: CGFloat, _ c: NSColor) {
        let path = NSBezierPath(ovalIn: NSRect(x: -width / 2, y: up, width: width, height: len))
        var t = AffineTransform(translationByX: p.x, byY: p.y)
        t.rotate(byDegrees: -side * angle)
        path.transform(using: t)
        c.setFill(); path.fill()
    }
    let rear: CGFloat = turn > 0 ? -1 : 1   // 보는 쪽의 반대편
    if dog {                             // 꼬리: 귀 아래로 비스듬히 나와 있고, 발을 디딜 때마다 흔들린다
        // 몸이 꼬리 쪽으로 치우친 자세에서는 그림 밖으로 나가지 않게 그만큼 세운다. 뒷모습에서는 등 가운데에 꼬리를 따로 그리므로 여기서는 안 그린다
        let angle = 76 - max(0, rear * k.shift) * 3.5 + rear * (k.step ?? 0) * 1.5
        if !k.back { limb(rear, at: NSPoint(x: cx + rear * (w / 2 - 2), y: k.lift + h * 0.1), 10, 26, -6, angle, dark) }
    } else if cat {                      // 고양이 꼬리: 엉덩이 옆에서 나와 위로 휘어 올라가는 두 칸 굵기. 발을 디딜 때마다 끝이 흔들린다. 뒷모습에서는 등에 따로 그린다
        if !k.back {
            let p = NSBezierPath(), x0 = cx + rear * (w / 2 + 2), y0 = k.lift + h * 0.12, sway = rear * (k.step ?? 0) * 0.4
            // 꼬리는 바깥으로 18pt 까지 나간다. 그림 끝까지 남은 자리가 그보다 좁으면(몸을 한쪽으로 치우쳐 그리는 동작) 남은 만큼만 나가게 해서 잘리지 않게 한다
            let out = max(0, min(18, (rear > 0 ? size - x0 : x0) - 5 - abs(sway)))
            p.lineWidth = 8; p.lineCapStyle = .round
            p.move(to: NSPoint(x: x0, y: y0))
            p.curve(to: NSPoint(x: x0 + rear * out / 3 + sway, y: y0 + 30), controlPoint1: NSPoint(x: x0 + rear * out * 0.9, y: y0 - 2), controlPoint2: NSPoint(x: x0 + rear * out + sway, y: y0 + 26))
            dark.setStroke(); p.stroke()
        }
    } else if abs(turn) >= 6 {           // 꼬리: 옆을 볼 때만 보인다
        let x = cx + rear * (w / 2 + 3)
        // 망치질할 때는 몸이 그림 칸 오른쪽 끝에 붙어서 둥근 꼬리가 네모나게 잘린다. 달릴 때처럼 몸 테두리 위쪽에 한 칸만 얹는다
        if k.hammer != nil { dot(x + 2, k.lift + h * 0.32 + 9, 1, 1, edge) }
        else {
            // 둥근 꼬리를 칸으로 얻어서 찍는다. 몸이 칸에 반 칸 어긋나게 놓인 자세에서는 꼬리 바깥 줄이 네 칸이 되어 밑이 각져 보인다.
            // 바깥 줄은 위에서 세 칸까지만 둔다
            var tail = cellsOf { oval(x, k.lift + h * 0.32, 16, 16, edge) }
            let outer = rear > 0 ? tail.map { $0[0] }.max() : tail.map { $0[0] }.min()
            tail.subtract(tail.filter { $0[0] == outer }.sorted { $0[1] > $1[1] }.dropFirst(3))
            for c in tail { dot(CGFloat(c[0]) * 4, CGFloat(c[1]) * 4, 1, 1, edge) }
        }
    }
    // 토끼 귀 두 짝. 평소에는 붙어서 서 있고, 날거나 떨어질 때 옆으로 벌어진다. 구를 때는 반으로 접어서 그림 밖으로 나가지 않게 한다
    let fold: CGFloat = (k.roll / 90).rounded() == 0 ? 1 : 0.5
    // 귀 뿌리 높이. 칸의 아래쪽 1pt 안에 걸리면 귀 끝이 한 칸짜리로 뾰족하게 찍힌다. 그때만 칸 가운데쯤으로 올려서 끝이 세 칸으로 둥글게 나오게 한다.
    // 귀를 올릴 때(perk)도 칸 가운데쯤에 맞춘 다음 칸 단위로 올려서, 올린 귀와 내린 귀의 높이가 딱 칸 수만큼 차이 나게 한다
    let root = k.lift + h - 10, low = root - floor(root / 4) * 4
    let earY = (low < 1 || k.perk != 0 ? root - low + 2.4 : root) + k.perk * 4
    // 고양이 귀 두 짝: 세모. 테두리, 털, 분홍 속을 차례로 겹친다. 토끼 귀 각도(ears)의 절반만큼만 벌어진다
    if cat { for side in [-1, 1] as [CGFloat] {
        let at = NSPoint(x: cx + side * 16 + turn * 0.5, y: k.lift + h - 7), lean = 10 + k.ears * 0.5 + side * k.sway
        func tri(_ half: CGFloat, _ base: CGFloat, _ tip: CGFloat, _ c: NSColor) {
            let p = NSBezierPath(); p.move(to: NSPoint(x: -half, y: base)); p.line(to: NSPoint(x: half, y: base)); p.line(to: NSPoint(x: side, y: tip)); p.close()
            var t = AffineTransform(translationByX: at.x, byY: at.y); t.rotate(byDegrees: -side * lean); p.transform(using: t)
            c.setFill(); p.fill()
        }
        tri(15, -4, 21 * fold + 6, earEdge[side] ?? edge); tri(11, 0, 21 * fold, earFur[side] ?? fur)
        if !k.back { tri(6, 2, 21 * fold - 7, pink) }
    } }
    if !dog && !cat { for side in [-1, 1] as [CGFloat] {
        let at = NSPoint(x: cx + side * 9 + turn * 0.5, y: earY), lean = k.ears + side * k.sway
        let edge = earEdge[side] ?? edge, fur = earFur[side] ?? fur      // 무늬가 귀 색을 따로 정했으면 그 색으로
        limb(side, at: at, 20, 36 * fold + 8, -4, lean, edge)   // 가장자리 색으로 한 칸 크게 먼저 칠해서 테두리를 만든다
        // 큰 타원만으로는 자세에 따라 귀 끝의 테두리가 뚫린다. 속 모양을 위아래·좌우로 한 칸씩 밀어 덧칠해서 뚫린 곳만 막는다
        for (dx, dy) in [(4, 0), (-4, 0), (0, 4), (0, -4)] as [(CGFloat, CGFloat)] {
            limb(side, at: NSPoint(x: at.x + dx, y: at.y + dy), 12, 36 * fold, 0, lean, edge)
        }
        limb(side, at: at, 12, 36 * fold, 0, lean, fur)
        if !k.back { limb(side, at: at, 4, 20 * fold, 10 * fold, lean, pink) }
    } }
    // 강아지 귀 두 짝. 머리 위쪽 모서리에 붙어서 옆으로 비스듬히 늘어진다(140도). 프레임마다 ears 로 들고 sway 로 한쪽으로 기울인다.
    // 돌아 누웠을 때는 귀를 3/4 길이로 줄여서 그림 밖으로 덜 나가게 한다
    // 옆모습(꼬리와 같은 기준)에서는 보는 쪽 귀가 얼굴 앞으로 와서 따로 떨어진 것처럼 보인다. 그 귀만 몸 뒤에 그린다
    func earBehind(_ side: CGFloat) -> Bool { abs(turn) >= 6 && side * turn > 0 }
    let bodyCells = dog ? cellsOf { blob(grow: 4).fill() } : []      // 몸이 차지하는 칸. 귀 위쪽이 몸에 붙었는지 볼 때 쓴다
    func dogEar(_ side: CGFloat) {
        // 옆을 보면 두 귀가 그쪽으로 따라가서 보는 쪽 귀의 뿌리가 몸 밖으로 나간다. 그 귀는 몸 뒤에 그리므로 뿌리를 두 칸 몸 쪽으로 당겨서
        // 귀 위쪽이 몸에 붙게 하고(한 칸만 당기면 귀 위와 몸 사이가 한 칸 떠서 따로 떨어져 보인다), 12도 더 벌려서 귀 끝은 몸 밖으로 나오게 한다
        let behind = earBehind(side)
        let angle = min(max(140 - k.ears * 2, 110) - side * k.sway, 180) - (behind ? 8 : 0)
        let tuck: CGFloat = behind ? -side * 6 : 0
        var at = NSPoint(x: cx + side * (w / 2 - 4) + turn * 0.5 + tuck, y: k.lift + h * 0.92 + 4)   // 머리 모서리보다 한 칸 낮게 단다. 몸 꼭대기 줄은 좁아서 같은 높이에 달면 귀 위쪽이 몸과 한 칸 떨어진다
        // 귀 뿌리를 칸 안의 정해진 자리에 맞춘다. 그래야 같은 각도의 귀가 어느 자세에서나 같은 칸에 찍힌다. 서 있는 자세에서만 맞춘다.
        // 자리는 기본 자세(idle_0)에서 귀 뿌리가 놓이는 곳이다. 곧게 늘어진 귀(172도 이상)는 폭이 다섯 칸으로 고르게 나오는 자리를 따로 쓴다
        if fold == 1 {
            let spot: CGFloat = angle >= 172 ? (side > 0 ? 1.6 : 2.4) : (side > 0 ? 3.6 : 0.4)
            at.x = ((at.x - spot) / 4).rounded() * 4 + spot
            at.y = ((at.y - 2.2) / 4).rounded() * 4 + 2.2
        }
        // 귀 모양: 끝으로 갈수록 아래로 휘는 물방울. 뿌리는 뾰족한 점(반지름 2)이고 끝은 둥글다(반지름 8).
        // 축을 따라 점점 굵어지는 원을 이어 칠한다. 축이 곧으면 귀가 머리에서 날개처럼 뻗어 보여서, 끝에서 6만큼 아래로 휘게 해서 처진 귀로 만든다.
        // 뿌리를 굵게 하면 원 두 개가 이어진 호리병처럼 보인다.
        // 바로 칠하면 살짝만 걸친 칸까지 칠해져서 귀 끝이 네모나거나 한 칸만 삐죽 나온다. 칸으로 얻어서 다듬은 뒤에 찍는다
        let len: CGFloat = fold < 1 ? 22.5 : 30, r0: CGFloat = 2, r1: CGFloat = 8, droop: CGFloat = 6
        var cells = cellsOf {
            var t = AffineTransform(translationByX: at.x, byY: at.y); t.rotate(byDegrees: -side * angle)
            dark.setFill()
            for i in 0...40 {
                let u = CGFloat(i) / 40, r = r0 + (r1 - r0) * u, c = NSPoint(x: side * droop * u * u, y: r0 - 5 + (len + 6 - r1 - r0) * u)
                let p = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)); p.transform(using: t); p.fill()
            }
        }
        if !cells.isEmpty {
            for x in [cells.map { $0[0] }.min()!, cells.map { $0[0] }.max()!] {      // 옆으로 한 칸만 삐져나온 칸은 뺀다
                let col = cells.filter { $0[0] == x }
                if col.count == 1 { cells.subtract(col) }
            }
            let low = cells.map { $0[1] }.min()!, drips = cells.filter { $0[1] == low }           // 맨 아래로 한 칸만 삐져나온 칸도 뺀다
            if drips.count == 1 { cells.subtract(drips) }
            // 꼭대기가 한 칸이면 그 바깥쪽 옆 칸을 채워서 두 칸으로 만든다. (한 칸을 지우면 귀 위가 밋밋해진다)
            let peak = cells.map { $0[1] }.max()!, tips = cells.filter { $0[1] == peak }
            if tips.count == 1, let t = tips.first { cells.insert([t[0] + Int(side), peak]) }
            // 귀를 둘러싼 네모의 꼭짓점 칸이 차 있고 거기서 가로·세로로 세 칸 이상 곧게 이어지면 네모나 보인다. 그 꼭짓점 칸을 뺀다
            let xs = cells.map { $0[0] }, ys = cells.map { $0[1] }
            for (x, sx) in [(xs.min()!, 1), (xs.max()!, -1)] { for (y, sy) in [(ys.min()!, 1), (ys.max()!, -1)] where cells.contains([x, y]) {
                if (0..<3).allSatisfy({ cells.contains([x + $0 * sx, y]) && cells.contains([x, y + $0 * sy]) }) { cells.remove([x, y]) }
            } }
        }
        // 귀 꼭대기 줄이 몸에 닿거나 바로 옆에 붙어 있지 않으면 떠 보인다. 붙을 때까지 귀를 몸 쪽으로 한 칸씩(두 칸까지) 옮긴다
        if fold == 1, let peak = cells.map({ $0[1] }).max() {
            for _ in 0..<2 where !cells.contains(where: { $0[1] == peak && (bodyCells.contains($0) || bodyCells.contains([$0[0] - Int(side), $0[1]])) }) {
                cells = Set(cells.map { [$0[0] - Int(side), $0[1]] })
            }
        }
        if k.flick != 0, side * turn > 0, let low = cells.map({ $0[1] }).min(), let high = cells.map({ $0[1] }).max() {
            cells = Set(cells.map { $0[1] * 2 < low + high ? [$0[0] + Int(side) * k.flick, $0[1]] : $0 })      // 아래 절반만 바깥으로 민다
        }
        // 몸을 한쪽으로 치우쳐 그리는 동작(망치, 낚시, 물주기, 공, 비눗방울)에서는 바깥쪽 귀 끝이 그림 밖으로 한두 칸 나가서 잘린다.
        // 몸이 그림 안에 다 들어와 있을 때만 귀를 그만큼 몸 쪽으로 당긴다. (문을 지나갈 때는 몸째로 그림 밖으로 나가므로 그대로 둔다)
        let last = Int(size / 4) - 1
        if let lo = cells.map({ $0[0] }).min(), let hi = cells.map({ $0[0] }).max(), bodyCells.allSatisfy({ (0...last).contains($0[0]) }) {
            let over = side > 0 ? hi - last : -lo
            if (1...2).contains(over) { cells = Set(cells.map { [$0[0] - Int(side) * over, $0[1]] }) }
        }
        for c in cells { dot(CGFloat(c[0]) * 4, CGFloat(c[1]) * 4, 1, 1, dark) }
    }
    if dog { for side in [-1, 1] as [CGFloat] where earBehind(side) { dogEar(side) } }
    edge.setFill(); blob(grow: 4).fill()
    for (dx, dy) in [(4, 0), (-4, 0), (0, 4), (0, -4)] as [(CGFloat, CGFloat)] { blob(dx: dx, dy: dy).fill() }   // 납작하게 눌린 자세에서 모서리 테두리가 뚫리지 않게 덧칠한다
    if !rims.isEmpty {                   // 얼룩 옆의 테두리만 얼룩 색으로 덧칠한다
        NSGraphicsContext.saveGraphicsState(); blob(grow: 4).addClip()
        for r in rims { oval(r.0, r.1, r.2, r.3, r.4) }
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.saveGraphicsState()   // 몸 안쪽: 오른쪽 아래 한 칸을 그늘로 남긴다
    blob().addClip()
    shade.setFill(); blob().fill()
    fur.setFill(); blob(dx: -4, dy: 4).fill()
    for p in patches { oval(p.0, p.1, p.2, p.3, p.4) }
    NSGraphicsContext.restoreGraphicsState()
    if dog { for side in [-1, 1] as [CGFloat] where !earBehind(side) { dogEar(side) } }      // 나머지 귀는 몸 앞에 그린다
    let ey = k.lift + h / 2 + 2 + k.gaze.y
    if k.back {                          // 뒷모습: 얼굴 대신 꼬리
        if dog { lump(cx + k.wag, k.lift + h * 0.44, 4, 7, dark, dark) }    // 강아지 꼬리는 위아래 끝을 두 칸으로 좁힌 4x7칸. 타원으로 그리면 자세에 따라 한쪽이 잘려 찍힌다
        else if cat {                   // 고양이 꼬리는 등 가운데에서 위로 휘어 올라간다
            let p = NSBezierPath(); p.lineWidth = 8; p.lineCapStyle = .round
            p.move(to: NSPoint(x: cx + k.wag, y: k.lift + h * 0.2))
            p.curve(to: NSPoint(x: cx + 12 + k.wag, y: k.lift + h * 0.8), controlPoint1: NSPoint(x: cx - 10, y: k.lift + h * 0.5), controlPoint2: NSPoint(x: cx + 14, y: k.lift + h * 0.5))
            dark.setStroke(); p.stroke()
        }
        else { lump(cx + k.wag, k.lift + h * 0.34, 5, 5, edge, edge) }      // 토끼 꼬리는 모서리를 뺀 5x5칸. 타원으로 그리면 자세에 따라 네모로 찍힌다
    } else {
        if dog { oval(cx + k.gaze.x, ey - 9, 26, 18, muzzle) }   // 주둥이
        paintPixelFace(k, cx, ey, line, dog: dog)
        if brows { for side in [-1, 1] as [CGFloat] { dot(cx + side * 14 + k.gaze.x - 2 - side * 4, ey + 8, 1, 1, NSColor(white: 0.985, alpha: 1)) } }
        if let st = stripe { dot(face.x - 2, k.lift + h - 10, 1, 2, st); dot(face.x - 10, k.lift + h - 10, 1, 1, st); dot(face.x + 6, k.lift + h - 10, 1, 1, st) }
        if cat {                         // 코 아래 점 두 개로 ω 입, 볼 옆에 수염 두 가닥씩
            if k.mouth == 0 && k.snack == 0 { dot(face.x - 6, ey - 12, 1, 1, line); dot(face.x + 2, ey - 12, 1, 1, line) }
            for side in [-1, 1] as [CGFloat] {
                let x = face.x + side * 30 - (side < 0 ? 6 : 2)
                dot(x, ey, 2, 1, whisker); dot(x, ey - 8, 2, 1, whisker)
            }
        }
    }
    if let (l, r) = k.hands { lump(cx - 34, l, 5, 4, edge, fur); lump(cx + 34, r, 5, 4, edge, fur) }   // 손은 5x4칸짜리 덩어리. 몸 테두리에 걸쳐서 몸에 붙어 보인다
    paintProps(k, NSRect(x: cx - w / 2, y: k.lift, width: w, height: h), NSPoint(x: cx + k.gaze.x, y: ey - 10), line, dog: dog, cat: cat,
               top: k.lift + h + (dog ? 6 : cat ? 24 : 30)) { lump($0, $1, 5, 4, edge, fur) }
    paintToy(k, cx, fur, edge, line, dog: dog)
}

// 들고 노는 소품. 몸을 다 그린 뒤에 그 앞에 그린다. 자리는 그림 칸(120pt) 안의 좌표이고, 몸은 Look.shift 로 오른쪽에 비켜 둔다
func paintToy(_ k: Look, _ cx: CGFloat, _ fur: NSColor, _ edge: NSColor, _ line: NSColor, dog: Bool) {
    let p = k.phase
    switch k.toy {
    case "fish":       // 낚시: 왼쪽 아래 물에 찌를 띄우고 기다리다가, 찌가 잠기면 낚아 올린다
        dot(0, 0, 9, 1, toyBlue); dot(p % 2 == 0 ? 4 : 16, 4, 2, 1, toySky)
        let tip = NSPoint(x: 10, y: p == 2 ? 70 : p == 3 ? 90 : 82)
        cellLine(NSPoint(x: 34, y: 42), tip, brown)           // 낚싯대는 망치 자루처럼 손 바로 위에서 시작한다
        if p == 3 {    // 낚아 올린 물고기
            cellLine(NSPoint(x: 10, y: 86), NSPoint(x: 10, y: 60), toyGray)
            dot(4, 44, 3, 4, toyBlue); dot(8, 40, 1, 1, toyBlue); dot(4, 36, 3, 1, toyBlue); dot(8, 52, 1, 1, line)
        } else {
            cellLine(NSPoint(x: 10, y: tip.y - 4), NSPoint(x: 10, y: p == 1 ? 12 : 16), toyGray)
            if p == 2 { dot(4, 4, 1, 1, .white); dot(16, 4, 1, 1, .white); dot(8, 8, 1, 1, .white) } else { dot(8, p == 1 ? 4 : 8, 1, 1, toyRed) }
        }
        lump(36, 32, 5, 4, edge, fur)                          // 손은 망치를 쥘 때와 같은 자리, 같은 모양이다
    case "ball":       // 공놀이: 왼발로 공을 차올린다
        let y: CGFloat = [10, 38, 58][p]
        lump(20, y, 4, 4, toyDark, .white); dot(16, y, 1, 1, toyRed); dot(20, y - 4, 1, 1, toyRed)
    case "balloon":    // 풍선: 오른손에 줄을 잡는다. 터지면 풍선 자리에 노란 조각이 튄다
        let x: CGFloat = p == 1 ? 100 : 96
        cellLine(NSPoint(x: x, y: 84), NSPoint(x: cx + 32, y: 54), toyGray)
        if p == 2 { for (dx, dy) in [(0, 14), (0, -10), (12, 2), (-12, 2), (8, 10), (-8, 10), (8, -6), (-8, -6)] as [(CGFloat, CGFloat)] { dot(x + dx - 2, 98 + dy, 1, 1, toyYellow) } }
        else { lump(x, 100, 6, 7, NSColor(srgbRed: 0.80, green: 0.26, blue: 0.30, alpha: 1), toyRed); dot(x - 8, 104, 1, 2, .white); dot(x - 2, 82, 1, 1, toyRed) }
        lump(cx + 34, 52, 5, 4, edge, fur)                     // 손은 망치를 쥘 때와 같은 5x4칸이다
    case "bubble":     // 비눗방울: 대롱을 불면 방울이 왼쪽 위로 올라가다가 터진다
        cellLine(NSPoint(x: cx - 20, y: 34), NSPoint(x: cx - 34, y: 40), toyYellow); lump(cx - 40, 42, 3, 3, toyBlue, toySky)
        for (i, b) in ([(26, 52, 4), (12, 72, 3), (34, 84, 2), (16, 44, 2)] as [(CGFloat, CGFloat, CGFloat)]).enumerated() {
            let step = (p + i) % 4
            if step == 3 { for (dx, dy) in [(-6, 0), (6, 0), (0, 6), (0, -6)] as [(CGFloat, CGFloat)] { dot(b.0 + dx - 2, b.1 + 24 + dy - 2, 1, 1, toySky) } }   // 터진다
            else { lump(b.0, b.1 + CGFloat(step) * 8, b.2, b.2, toyBlue, NSColor(white: 1, alpha: 0.75)) }
        }
    case "flower":     // 꽃 키우기: 물뿌리개로 물을 주면 싹이 자라서 꽃이 핀다
        // 손은 망치를 쥘 때와 같은 자리, 같은 모양이고 물뿌리개는 그 손 바로 위에 얹힌다. 다 주고 나면 손과 함께 세 칸 내린다
        // 꽃이 피면 물뿌리개를 오른쪽으로 한 칸 비켜서 손 바로 위에 둔다. 안 비키면 꽃 머리와 한 칸 겹친다
        let grip: CGFloat = p == 3 ? 20 : 32, can = grip + 18, canX: CGFloat = p == 3 ? 38 : 34
        lump(canX, can, 5, 5, NSColor(srgbRed: 0.28, green: 0.50, blue: 0.80, alpha: 1), toyBlue)
        cellLine(NSPoint(x: canX - 10, y: can + 2), NSPoint(x: canX - 18, y: can + (p == 3 ? 6 : -2)), toyBlue)
        if p < 3 { for i in 0..<2 { dot(16, can - 12 - CGFloat((p + i * 2) % 3) * 8, 1, 1, toySky) } }   // 물방울
        dot(8, 0, 5, 1, brown)                                             // 흙
        func f(_ col: Int, _ row: Int, _ c: NSColor) { dot(CGFloat(col) * 4, CGFloat(row) * 4, 1, 1, c) }   // 칸 번호로 찍는다. 줄기는 4번 칸이다
        let rose = NSColor(srgbRed: 0.96, green: 0.48, blue: 0.60, alpha: 1)       // 꽃잎의 그늘
        for row in 1...(p + 1) { f(4, row, row % 2 == 1 ? toyGreen : leafDeep) }   // 줄기가 한 칸씩 자라고, 잎이 하나씩 난다
        if p >= 1 { f(5, 2, leafLight) }
        if p >= 2 { f(3, 3, leafLight) }
        if p == 2 { f(4, 4, pink); f(4, 5, rose) }                                 // 봉오리
        if p == 3 {                                                                // 벚꽃 모양의 꽃 머리 (5 x 5칸). P 꽃잎, S 그늘, Y 가운데
            for (i, line) in ["..P..", "PPPPP", "PPYPS", ".PPS.", ".P.S."].enumerated() { for (j, ch) in line.enumerated() where ch != "." {
                f(2 + j, 9 - i, ch == "P" ? pink : ch == "S" ? rose : toyYellow)
            } }
        }
        lump(36, grip, 5, 4, edge, fur)
    case "door", "doorL", "doorM", "doorR":   // 문: 몸을 자르던 것을 되돌린다
        NSGraphicsContext.restoreGraphicsState()
        // 문을 드나드는 동안에만 문틀을 몸 앞에 다시 그린다. 그래서 몸이 문틀 뒤, 문 안쪽 앞에 있어 보인다.
        // 문 앞에 서 있을 때는 그리지 않는다. 귀나 꼬리가 문보다 넓어서 문틀이 몸 위를 지나가 보인다
        guard k.toy == "doorL" || k.toy == "doorR" else { break }
        dot(16, 0, 1, 24, doorRim); dot(100, 0, 1, 24, doorRim); dot(20, 92, 1, 1, doorRim); dot(96, 92, 1, 1, doorRim)
        dot(20, 96, 3, 1, doorRim); dot(88, 96, 3, 1, doorRim); dot(28, 100, 16, 1, doorRim)
        dot(12, 0, 24, 1, doorSill)
    case "zzz":        // 잠: 코에 콧방울이 커졌다 작아지고, 도트로 찍은 z 둘이 떠오른다
        let nose = NSPoint(x: cx - 2, y: k.lift + k.h * 0.39 + 2 - 8), n: CGFloat = [2, 3, 4, 3][p]
        if n == 2 { dot(nose.x - 8, nose.y - 4, 2, 2, toySky) } else { lump(nose.x - 4 - n * 2, nose.y - n * 2 + 4, n, n, toyBlue, NSColor(white: 1, alpha: 0.8)) }
        func zed(_ x: CGFloat, _ y: CGFloat, _ n: CGFloat) {      // n칸짜리 z: 윗줄, 오른쪽 위에서 왼쪽 아래로 가는 빗금, 아랫줄
            dot(x, y + (n - 1) * 4, n, 1, line); dot(x, y, n, 1, line)
            for i in 1..<Int(n) - 1 { dot(x + CGFloat(i) * 4, y + CGFloat(i) * 4, 1, 1, line) }
        }
        zed(80, 72 + [0, 4, 0, 4][p], 4)
        if p >= 1 { zed(98, p == 3 ? 98 : 94, 5) }
    case "notes":      // 춤: 도트로 찍은 음표 둘이 양옆에서 번갈아 떠오른다. 세 틱 올라가고 한 틱 쉰다
        for (i, n) in ([(96, 76, toyRed), (12, 68, toyBlue)] as [(CGFloat, CGFloat, NSColor)]).enumerated() {
            let step = (p + i * 2) % 4
            guard step < 3 else { continue }
            let x = n.0, y = n.1 + CGFloat(step) * 8
            dot(x, y, 2, 2, n.2); dot(x + 8, y + 4, 1, 4, n.2); dot(x + 12, y + 12, 1, 2, n.2)
        }
    case "bang":       // 부르기: 오른쪽 위 말풍선 안에 빨간 느낌표. 말풍선이 한 칸씩 오르내린다
        // l, b 는 풍선의 왼쪽 아래. 강아지는 뛰어오르면 귀가 풍선 자리까지 올라와서, 풍선을 한 칸 위·오른쪽에 두고 꼬리를 귀 바깥쪽에 단다
        let l: CGFloat = dog ? 92 : 88, b: CGFloat = (dog ? 80 : 76) + (p % 2 == 0 ? 0 : 4), tail = l + (dog ? 12 : 4)
        lump(l + 14, b + 18, 7, 9, toyDark, .white); dot(tail, b - 4, 2, 1, toyDark); dot(tail, b - 8, 1, 1, toyDark)   // 7 x 9칸 풍선과 꼬리. 폭이 홀수라 느낌표가 가운데 온다
        dot(l + 12, b + 16, 1, 3, toyRed); dot(l + 12, b + 8, 1, 1, toyRed)                                           // 느낌표: 위아래로 한 칸씩 띄운다
    case "dust":       // 내려앉기: 발 양옆에서 먼지가 퍼져 나간다
        let rim = NSColor(white: 0.70, alpha: 1), fill = NSColor(white: 0.95, alpha: 1)
        if p == 0 { lump(10, 8, 4, 3, rim, fill); lump(110, 8, 4, 3, rim, fill) }
        else { lump(6, 12, 3, 3, rim, fill); lump(114, 12, 3, 3, rim, fill); dot(16, 4, 1, 1, rim); dot(100, 4, 1, 1, rim) }
    case "trail":      // 달리기: 뒤(오른쪽)에 먼지가 남는다
        let rim = NSColor(white: 0.70, alpha: 1), fill = NSColor(white: 0.95, alpha: 1)
        if p == 0 { lump(112, 8, 4, 3, rim, fill) } else { lump(114, 14, 3, 3, rim, fill); dot(104, 4, 1, 1, rim) }
    case "what":       // 두리번: 도트로 찍은 물음표
        dot(96, 104, 2, 1, line); dot(92, 100, 1, 1, line); dot(104, 100, 1, 1, line); dot(100, 96, 1, 1, line); dot(96, 92, 1, 1, line); dot(96, 84, 1, 1, line)
    case "box":        // 상자: 몸 앞에 그려서 몸을 가린다
        dot(cx - 36, 0, 18, 7, toyBox); dot(cx - 36, 24, 18, 1, toyWood); dot(cx - 4, 0, 2, 6, toyWood)
        dot(cx - 36, 0, 1, 7, toyWood); dot(cx + 32, 0, 1, 7, toyWood)
    default: break
    }
}

// 아치문의 문틀, 문 안쪽, 문짝, 문턱. 그림 칸 가운데에 몸보다 크게(22칸 x 27칸) 그린다. phase: 0 닫힘, 2 삼분의 일 열림, 3 삼분의 이 열림, 1 다 열림.
// 문짝은 그림의 오른쪽 끝에 달려 있어서 왼쪽부터 열린다. mirror 면 좌우를 바꿔서 왼쪽 끝에 달리고 오른쪽부터 열린다.
// 들어갈 때는 펫이 오른쪽을 봐서 그림이 뒤집히므로 mirror 없이, 나올 때는 펫이 왼쪽을 보므로 mirror 로 그린다. 그래서 화면에서는 둘 다 오른쪽에서 왼쪽으로 열린다
func paintDoor(_ phase: Int, mirror: Bool) {
    func d(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor) { dot(mirror ? size - x - w * 4 : x, y, w, h, c) }
    d(16, 0, 22, 24, doorRim); d(20, 96, 20, 1, doorRim); d(28, 100, 16, 1, doorRim)      // 문틀: 위쪽 모서리를 두 단으로 깎은 아치
    if phase != 0 {                                        // 열린 틈으로 별이 뜬 문 안이 보인다
        d(20, 0, 20, 23, doorNight); d(24, 92, 18, 1, doorNight); d(32, 96, 14, 1, doorNight)
        for (x, y) in [(32, 84), (76, 92), (88, 60), (28, 40), (84, 20)] as [(CGFloat, CGFloat)] { d(x, y, 1, 1, doorKnob) }
    }
    let edge: CGFloat = [20, 92, 48, 76][phase]             // 문짝의 왼쪽 끝. 열릴수록 오른쪽으로 물러나고 문짝이 좁아 보인다
    let leaf = phase == 1 ? doorShade : doorPanel
    d(edge, 0, (100 - edge) / 4, 23, leaf)
    if edge < 96 { d(max(edge, 24), 92, (96 - max(edge, 24)) / 4, 1, leaf) }
    if edge < 88 { d(max(edge, 32), 96, (88 - max(edge, 32)) / 4, 1, leaf) }
    if phase == 0 {                                        // 닫힌 문짝: 판 두 장, 위 판의 하트, 손잡이
        d(40, 88, 10, 1, doorShade); d(36, 84, 1, 1, doorShade); d(80, 84, 1, 1, doorShade)      // 위 판: 문처럼 윗변을 둥글게 깎는다
        d(32, 60, 1, 6, doorShade); d(84, 60, 1, 6, doorShade); d(32, 56, 14, 1, doorShade)
        for y in [12, 44] as [CGFloat] { d(32, y, 14, 1, doorShade) }                            // 아래 판
        d(32, 16, 1, 7, doorShade); d(84, 16, 1, 7, doorShade)
        for (x, y, w) in [(52, 80, 2), (64, 80, 2), (48, 76, 6), (52, 72, 4), (56, 68, 2)] as [(CGFloat, CGFloat, CGFloat)] { d(x, y, w, 1, doorRim) }
        d(24, 48, 2, 2, doorKnob)
    } else if phase != 1 { d(edge, 0, 1, 23, doorShade); d(edge + 8, 44, 1, 2, doorKnob) }   // 열리는 중: 문짝의 옆면과 손잡이
    dot(12, 0, 24, 1, doorSill)                            // 문턱: 문틀보다 양옆으로 한 칸씩 넓다
}

// 도트 얼굴. 작은 눈·볼·코는 타원으로 그리면 뭉개져서, 한 칸(4pt)에 맞춘 네모로 찍는다.
func paintPixelFace(_ k: Look, _ cx: CGFloat, _ ey: CGFloat, _ line: NSColor, dog: Bool) {
    for side in [-1, 1] as [CGFloat] {
        let x = cx + side * 14 + k.gaze.x
        switch k.eyes {
        case .closed: dot(x - 6, ey - 2, 3, 1, line)
        case .happy:  dot(x - 6, ey - 4, 1, 1, line); dot(x - 2, ey, 1, 1, line); dot(x + 2, ey - 4, 1, 1, line)
        case .dizzy:  for (dx, dy) in [(-6, -6), (2, -6), (-2, -2), (-6, 2), (2, 2)] as [(CGFloat, CGFloat)] { dot(x + dx, ey + dy, 1, 1, line) }
        case .open:   dot(x - 2, ey - 4, 1, 2, line)                                      // 세로 두 칸짜리 점
        case .wide:   dot(x - 4, ey - 6, 2, 3, line); dot(x - 4, ey + 2, 1, 1, .white)    // 세로로 길게 뜬 눈. 위쪽 한 칸은 반짝임
        }
        dot(x - 4 + side * 8, ey - 12, 2, 1, pink)   // 볼
    }
    let open = max(1, (k.mouth / 4).rounded())   // 입을 벌린 칸 수
    if dog {                             // 검은 코. 입을 벌리거나 신나면 그 아래로 혀가 나온다
        dot(cx + k.gaze.x - 4, ey - 8, 2, 1, line)
        if k.mouth > 0 || k.eyes == .happy { dot(cx + k.gaze.x - 2, ey - 8 - max(k.mouth, 4), 1, open, pink) }
    } else if k.snack > 0 { dot(cx + k.gaze.x - 2, ey - 8 - (k.mouth > 0 ? 4 : 0), 1, 1, pink) }   // 민들레를 씹을 때는 입 대신 코만 오르내린다
    else if k.mouth > 0 { dot(cx + k.gaze.x - 2, ey - 8 - k.mouth, 1, open, line) }           // 입
    else { dot(cx + k.gaze.x - 2, ey - 8, 1, 1, pink) }                                       // 코
}

// 줄넘기 줄, 입에 문 민들레·뼈 달린 고기·생선, 망치와 받침(몸 왼쪽 빈자리), 꽃가루. top 은 귀까지 친 머리 꼭대기이고 hand 는 손 하나를 그린다.
func paintProps(_ k: Look, _ body: NSRect, _ mouth: NSPoint, _ line: NSColor, dog: Bool, cat: Bool = false, top: CGFloat, hand: (CGFloat, CGFloat) -> Void) {
    let thick: CGFloat = 4
    if k.rope > 0 {                      // 양옆에서 머리 위나 발 아래로 도는 줄
        // 줄 끝은 몸 옆에 붙는다. 강아지는 귀가 몸 옆을 덮고 있어서 귀 끝 아래(두 칸 밑)에서 잡고, 머리 위로 돌 때는 줄이 귀 바깥으로 크게 돈다
        let grip = body.midY - (dog ? 8 : 0), wide: CGFloat = dog && k.rope == 1 ? 84 : 10
        let l = NSPoint(x: body.minX - 4, y: grip), r = NSPoint(x: body.maxX + 4, y: grip)
        let bend = k.rope == 1 ? body.midY + (top + 8 - body.midY) / 0.75 : body.minY - 30   // 곡선 꼭대기는 조절점 높이의 3/4 까지 간다
        let p = NSBezierPath(); p.move(to: l)
        p.curve(to: r, controlPoint1: NSPoint(x: l.x - wide, y: bend), controlPoint2: NSPoint(x: r.x + wide, y: bend))
        p.lineWidth = thick; line.setStroke(); p.stroke()
    }
    if k.snack > 0 && dog {              // 강아지는 민들레 대신 뼈 달린 고기를 문다. 뼈를 코 바로 아랫줄에 가로로 물고, 한 번 씹을 때마다 가운데 고기가 줄어든다
        let n = Int((k.snack * 6).rounded())                                     // 남은 고기 (6 = 다 있음)
        func cell(_ x: Int, _ y: Int, _ c: NSColor) { dot(snap(mouth.x - 12) + CGFloat(x) * 4, snap(mouth.y - 2) + CGFloat(y) * 4, 1, 1, c) }   // 뼈의 왼쪽 끝이 (0, 0)
        for x in 0...5 { cell(x, 0, bone) }
        cell(0, -1, boneShade); cell(5, -1, boneShade)
        let half = [0, 1, 1, 2, 2, 2, 2][n]                                      // 고기의 반쪽 너비. 코를 가리지 않게 뼈 줄과 그 아래에만 그린다
        for x in (3 - half)..<(3 + half) {
            cell(x, 0, x == 3 - half ? meatGlaze : meat)
            if n >= 2 { cell(x, -1, meat) }
            if n >= 5 { cell(x, -2, meat) }
        }
    } else if k.snack > 0 && cat {       // 고양이는 생선을 가로로 문다 (6 x 3칸, 꼬리가 왼쪽). 한 번 씹을 때마다 머리 쪽부터 살이 없어지고 가시만 남는다
        let n = Int((k.snack * 6).rounded())                                     // 남은 정도 (6 = 다 있음)
        func cell(_ x: Int, _ y: Int, _ c: NSColor) { dot(snap(mouth.x - 12) + CGFloat(x) * 4, snap(mouth.y - 2) + CGFloat(y) * 4, 1, 1, c) }   // 꼬리 위쪽 끝이 (0, 0)
        cell(0, 0, fishDeep); cell(1, -1, fishDeep); cell(0, -2, fishDeep)       // 꼬리
        let flesh = [0, 0, 1, 2, 3, 4, 4][n]                                     // 살이 남은 칸 수 (꼬리 쪽부터)
        for i in 0..<4 {
            if i < flesh { cell(2 + i, 0, fishBlue); cell(2 + i, -1, fishBlue); cell(2 + i, -2, fishBelly) }
            else { cell(2 + i, -1, fishSpine); if i % 2 == 0 { cell(2 + i, 0, fishRib); cell(2 + i, -2, fishRib) } }   // 등뼈 한 줄에 한 칸 걸러 갈비뼈
        }
        if flesh == 4 { cell(5, -1, line) }                                      // 눈
    } else if k.snack > 0 {              // 민들레: 입에서 왼쪽 아래로 늘어진 줄기, 그 끝의 노란 꽃, 줄기에 붙은 잎 한 장
        let n = Int((k.snack * 6).rounded())                                     // 남은 마디 수
        let path = [(-1, 0), (-2, -1), (-3, -1), (-4, -2), (-5, -3), (-6, -3)]   // 입에서 센 마디의 자리 (칸)
        func cell(_ x: Int, _ y: Int, _ c: NSColor) { dot(snap(mouth.x - 2) + CGFloat(x) * 4, snap(mouth.y) + CGFloat(y) * 4, 1, 1, c) }
        for i in 0..<max(n - 1, 0) { cell(path[i].0, path[i].1, i % 2 == 0 ? toyGreen : leafDeep) }
        if n >= 4 { let at = path[n - 3]; cell(at.0, at.1 + 1, leafLight); cell(at.0 - 1, at.1 + 1, toyGreen) }   // 잎은 꽃에서 두 마디 앞에 붙어서 꽃과 함께 입으로 다가온다
        if n > 0 {                       // 꽃은 3 x 3칸: 가운데는 주황, 위아래·좌우는 노랑, 모서리는 연노랑. 코를 가리는 칸은 뺀다
            let end = path[n - 1]
            for dy in -1...1 { for dx in -1...1 where !(end.0 + dx >= 0 && dy >= 1) {
                cell(end.0 + dx, end.1 + dy, dx == 0 && dy == 0 ? petalCore : dx != 0 && dy != 0 ? petalPale : petal)
            } }
        }
    }
    if let hit = k.hammer {              // 받침, 망치 머리, 자루, 자루를 쥔 손. 내리친 모습이면 불꽃도 튄다
        dot(4, 4, 6, 2, brown)
        if hit {
            dot(4, 12, 5, 3, .darkGray); dot(24, 16, 1, 1, line); hand(36, 20)
            dot(0, 28, 1, 1, line); dot(12, 28, 1, 2, line)
            if !dog { dot(24, 32, 1, 1, line) }   // 강아지는 내리칠 때 든 귀가 이 불꽃 자리에 와서 뺀다
        } else {
            dot(12, 60, 5, 3, .darkGray); cellLine(NSPoint(x: 26, y: 58), NSPoint(x: 34, y: 42), line); hand(36, 32)
        }
    }
}

// 화면에 보이는 창들을 AppKit 좌표로 돌려준다. wins 는 다른 앱의 일반 창(앞에 있는 순서), pets 는 펫 창이다.
func screenWindows() -> (wins: [CGRect], pets: [(id: Int, rect: CGRect)]) {
    let primaryH = NSScreen.screens[0].frame.height   // CGWindow 좌표는 위가 0 이라 뒤집는다
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var wins: [CGRect] = [], pets: [(id: Int, rect: CGRect)] = []
    for w in list {
        guard (w[kCGWindowAlpha as String] as? Double ?? 1) > 0, let b = w[kCGWindowBounds as String] as? NSDictionary,
              let q = CGRect(dictionaryRepresentation: b) else { continue }
        let r = CGRect(x: q.minX, y: primaryH - q.maxY, width: q.width, height: q.height)
        if w[kCGWindowLayer as String] as? Int == 0 {          // 일반 창. Dock·메뉴 막대는 빠진다
            if r.width >= side { wins.append(r) }
        } else if w[kCGWindowOwnerName as String] as? String == "MochiPet", r.width == r.height, r.width >= 60,
                  let id = w[kCGWindowNumber as String] as? Int {   // 펫 창. 정사각형이라 이름표·메뉴 막대 아이콘과 구별된다
            pets.append((id, r))
        }
    }
    return (wins, pets)
}

final class PetView: NSView {
    var pet = Pet(pos: .zero)
    var host: NSWindow?             // 이 뷰가 든 창. 뷰가 잡고 있어야 창이 살아 있다
    var hue: CGFloat? { didSet { cache = [:]; needsDisplay = true } }   // 몸 색. drawn() 참고
    var kind = defaultKind { didSet { cache = [:]; needsDisplay = true } }   // 펫 종류
    var coat = "" { didSet { cache = [:]; needsDisplay = true } }            // 무늬. 비어 있으면 hue 로 칠한다
    var onMenu: (() -> Void)?       // 우클릭했을 때
    var label = "" { didSet { hideTag() } }                             // 이름표 글자
    var nameTag: NSWindow?              // 떠 있는 이름표
    var onClick: (() -> Void)?      // 끌지 않고 눌렀다 뗐을 때
    var grab: NSPoint?              // 끌고 있는 동안: 마우스 위치 - 펫 원점
    var climbTop: CGFloat?          // 타고 오르는 중이면 멈춰 설 높이. 설 자리가 없으면 무한대로 둔다
    var logged = ""                 // MOCHIPET_LOG 를 주고 실행하면 동작이 바뀔 때마다 한 줄씩 찍는다
    let logging = ProcessInfo.processInfo.environment["MOCHIPET_LOG"] != nil
    var downAt = NSPoint.zero
    var timer: Timer?
    var interval = 0.15
    var cache: [String: NSImage] = [:]

    // 창을 둘 자리. 소수점 좌표에 두면 창이 픽셀 격자에 걸쳐 1pt 넓게 잡힌다.
    var origin: NSPoint { NSPoint(x: pet.pos.x.rounded(), y: pet.pos.y.rounded()) }

    var area: CGRect {              // Dock 과 메뉴 막대를 뺀 영역
        let v = (window?.screen ?? NSScreen.main)!.visibleFrame
        return CGRect(x: v.minX, y: v.minY, width: v.width - side, height: v.height - side)
    }

    // 펫이 x 에 있을 때 y 이하에서 가장 높은 발판: 가려지지 않은 창 윗변 또는 화면 바닥.
    func floorY(_ wins: [CGRect], _ x: CGFloat, _ y: CGFloat) -> CGFloat {
        let cx = x + side / 2, a = area
        var best = a.minY
        for (i, w) in wins.enumerated() where w.minX <= cx && cx <= w.maxX && w.maxY <= min(y, a.maxY) && w.maxY > best {
            let covered = wins[..<i].contains { $0.contains(CGPoint(x: cx, y: w.maxY - 1)) }
            if !covered { best = w.maxY }
        }
        return best
    }

    func begin() {
        pet.pos = CGPoint(x: .random(in: area.minX...area.maxX), y: area.maxY)   // 화면 위에서 떨어지며 등장한다
        window?.setFrameOrigin(origin)
        restartTimer()
    }

    func restartTimer() {
        timer?.invalidate()
        interval = tick
        timer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(step), userInfo: nil, repeats: true)
    }

    // 전역 크기·투명도·숨김을 이 펫 창에 입힌다.
    func applyLook() {
        guard let w = window else { return }
        w.alphaValue = opacity
        if w.frame.width != side {       // 그림과 이름표는 새 크기에서 다시 만든다
            cache = [:]; hideTag()
            w.setFrame(NSRect(origin: origin, size: NSSize(width: side, height: side)), display: true)
        }
        if hidden { hideTag(); w.orderOut(nil) } else { w.orderFrontRegardless() }
    }

    override func rightMouseDown(with e: NSEvent) { onMenu?() }

    func setMood(_ m: String) {
        pet.mood = m
        if !pet.action.air && pet.name != "fall" { pet.start("idle") }   // 땅에 있으면 바로 반응한다
    }

    @objc func step() {
        if hidden { return }
        if grab != nil {
            pet.frame = (pet.frame + 1) % pet.action.frames.count
        } else {
            // ponytail: 틱마다 창 목록을 새로 읽는다. 부담되면 0.5초 캐시로 바꾼다.
            let seen = screenWindows()
            pet.tick(in: area) { x, y in grounded ? area.minY : floorY(seen.wins, x, y) }   // 날지 않기를 켜면 발판은 화면 바닥뿐이라, 창 위에 있던 펫은 떨어져 내려온다
            collide(seen.pets)
            if pet.name == "crouch" { window?.orderFrontRegardless() }   // 머리를 밟고 설 때 밟힌 펫의 귀에 가려지지 않게 앞으로 나온다
            climbing(seen.wins)
            if logging && pet.name != logged {   // stderr 는 버퍼에 쌓이지 않아서 바로 보인다
                logged = pet.name
                FileHandle.standardError.write("\(label.isEmpty ? "pet" : label) -> \(pet.name)\n".data(using: .utf8)!)
            }
            slide(over: interval * pet.partial)
            // 바닥에 막혀 일찍 도착하면 다음 틱을 기다리지 않고 바로 착지 동작으로 넘어간다
            if pet.partial < 1 { perform(#selector(step), with: nil, afterDelay: interval * pet.partial) }
        }
        updateTag()
        needsDisplay = true
    }

    // 이름표는 마우스를 올렸을 때, 승인을 기다리며 부를 때, 끝나서 축하할 때 머리 위에 뜬다.
    // 펫 창에 붙인 작은 창이라 떠 있는 동안 펫을 따라 움직인다.
    func updateTag() {
        guard let w = window else { return }
        // 마우스가 올라와 있는지는 틱마다 직접 잰다. 펫이 커서 밑을 지나가도 어긋나지 않는다.
        let hovering = w.frame.insetBy(dx: 16, dy: 8).contains(NSEvent.mouseLocation)
        let on = !label.isEmpty && (hovering || ["call", "cheer"].contains(pet.name))
        guard on != (nameTag != nil) else { return }
        guard on else { hideTag(); return }
        let text = NSTextField(labelWithString: label)
        text.font = .boldSystemFont(ofSize: 11); text.alignment = .center; text.textColor = .white
        text.drawsBackground = true; text.backgroundColor = NSColor(white: 0.15, alpha: 0.85)
        text.wantsLayer = true; text.layer?.cornerRadius = 9; text.layer?.masksToBounds = true
        text.sizeToFit()
        let s = NSSize(width: text.frame.width + 14, height: 18)
        let t = NSWindow(contentRect: NSRect(x: w.frame.midX - s.width / 2, y: w.frame.maxY - 2, width: s.width, height: s.height),
                         styleMask: .borderless, backing: .buffered, defer: false)
        t.isOpaque = false; t.backgroundColor = .clear; t.ignoresMouseEvents = true; t.isReleasedWhenClosed = false
        t.contentView = text
        w.addChildWindow(t, ordered: .above)
        nameTag = t
    }

    func hideTag() {
        guard let t = nameTag else { return }
        window?.removeChildWindow(t); t.orderOut(nil); nameTag = nil
    }

    func close() {
        timer?.invalidate(); NSObject.cancelPreviousPerformRequests(withTarget: self)
        hideTag(); host?.close(); host = nil
    }
    func collide(_ others: [(id: Int, rect: CGRect)]) {
        guard let me = window?.windowNumber else { return }
        pet.meet(others.filter { $0.id != me }.map(\.rect), in: area)
    }

    // 타고 오르기는 뒤에 창이 있을 때만 한다. 창 위에 설 자리가 있으면 거기까지만 오르고 올라선다.
    func climbing(_ wins: [CGRect]) {
        guard pet.name == "climb" else { climbTop = nil; return }
        if climbTop == nil {                                     // 방금 시작했다. 아직 움직이기 전이다
            let behind = CGPoint(x: pet.pos.x + side / 2, y: pet.pos.y + side / 2)
            guard let w = wins.first(where: { $0.contains(behind) }), w.maxY - pet.pos.y > 150 else { pet.start("idle"); return }
            climbTop = w.maxY <= area.maxY ? w.maxY : .infinity   // 무한대면 화면 꼭대기에서 매달리게 된다 (동작 표의 onEdge)
        }
        if let top = climbTop, pet.pos.y >= top { pet.pos.y = top; climbTop = nil; pet.start("idle") }
    }

    // 창을 pet.pos 까지 t 초에 걸쳐 등속으로 옮긴다. 틱 사이를 메워서 움직임이 끊기지 않는다.
    func slide(over t: Double) {
        guard let w = window else { return }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = t; c.timingFunction = CAMediaTimingFunction(name: .linear)
            // 크기는 늘 고정값을 준다. 움직이는 도중의 w.frame.size 를 읽어 되먹이면 반올림 오차가 쌓여 창이 늘어난다.
            w.animator().setFrame(NSRect(origin: origin, size: NSSize(width: side, height: side)), display: false)
        }
    }

    func sprite(_ name: String) -> NSImage {
        if let i = cache[name] { return i }
        let i = drawn(name, hue: hue, kind: kind, coat: coat)
        cache[name] = i
        return i
    }

    override func draw(_ r: NSRect) {
        if pet.flip {
            let t = NSAffineTransform(); t.translateX(by: bounds.width, yBy: 0); t.scaleX(by: -1, yBy: 1); t.concat()
        }
        sprite(pet.sprite).draw(in: bounds)
    }

    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        downAt = NSEvent.mouseLocation
        pet.pos = window!.frame.origin; slide(over: 0)   // 미끄러지던 중이면 그 자리에서 멈춘다
        grab = NSPoint(x: downAt.x - pet.pos.x, y: downAt.y - pet.pos.y)
        pet.start("held")
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard let g = grab else { return }
        let m = NSEvent.mouseLocation
        pet.pos = CGPoint(x: m.x - g.x, y: m.y - g.y)
        window?.setFrameOrigin(origin)
    }

    override func mouseUp(with e: NSEvent) {
        grab = nil; pet.start("fall")
        let m = NSEvent.mouseLocation
        if hypot(m.x - downAt.x, m.y - downAt.y) < 4 { onClick?() }
    }
}

// 투명하고 항상 위에 뜨는 창에 펫 하나를 띄운다.
func makePet() -> PetView {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                     styleMask: .borderless, backing: .buffered, defer: false)
    w.isOpaque = false              // 투명한 부분은 클릭도 통과한다
    w.backgroundColor = .clear
    w.hasShadow = false
    w.level = .floating             // 항상 위
    w.collectionBehavior = [.canJoinAllSpaces, .stationary]
    w.isReleasedWhenClosed = false
    let v = PetView(frame: NSRect(x: 0, y: 0, width: side, height: side))
    v.host = w
    w.contentView = v
    v.begin()
    v.applyLook()
    return v
}

// 표가 깨지면 여기서 걸린다: 없는 동작·프레임을 가리키는지, 범위를 벗어나는지,
// 발판에 착지하는지, 모든 동작에 도달하는지, mood 가 동작을 바꾸는지.
func selftest() {
    for a in actions.values {
        precondition(!a.frames.isEmpty && !a.next.isEmpty)
        for f in a.frames { precondition(looks[f] != nil, "없는 프레임: \(f)") }
        for n in a.next.map(\.0) + [a.onEdge, a.onCliff].compactMap({ $0 }) {
            precondition(actions[n.replacingOccurrences(of: "~", with: "")] != nil, "없는 동작: \(n)")
        }
    }
    let area = CGRect(x: 0, y: 0, width: 800, height: 600)
    let floor: (CGFloat, CGFloat) -> CGFloat = { x, y in (200...500).contains(x) && y >= 300 ? 300 : 0 }   // 발판 하나
    var p = Pet(pos: CGPoint(x: 300, y: 600)), seen = Set<String>(), firstLanding: CGFloat?, onGround = false
    func run(_ n: Int) {
        seen = []
        for _ in 0..<n {
            p.tick(in: area, floor: floor); seen.insert(p.name)
            precondition((0...800).contains(p.pos.x) && (0...600).contains(p.pos.y), "범위 이탈: \(p.pos)")
            if p.name == "land" && firstLanding == nil { firstLanding = p.pos.y }
            if p.name == "idle" && p.pos.y == 0 { onGround = true }
        }
    }
    let moodOnly: Set = ["work", "rush", "cheer", "call"]

    run(50_000)                                         // 혼자 놀 때
    precondition(firstLanding == 300, "발판에 착지하지 않음: \(String(describing: firstLanding))")
    precondition(onGround, "발판에서 내려오지 못함")
    let social = leaping.union(["rolloff", "bump", "splat", "getup", "flinch"])                     // 다른 펫이 일으키는 동작
    let free = Set(actions.keys).subtracting(moodOnly).subtracting(social).subtracting(["held"])
    precondition(seen == free, "혼자 놀 때 동작이 다름: \(seen.symmetricDifference(free))")

    p.mood = "working"; run(2_000); run(5_000)          // 일하는 중: 하던 동작이 끝난 뒤에는 일만 한다
    precondition(seen.isSuperset(of: ["work", "rush"]) && seen.isSubset(of: ["work", "rush", "fall", "land", "dizzy"]),
                 "일하는 중 동작이 다름: \(seen)")

    p.mood = "waiting"; run(2_000); run(5_000)          // 승인 대기: 제자리에서 부르기만 한다
    precondition(seen == ["call"], "승인 대기 중 동작이 다름: \(seen)")

    p.mood = "done"; run(2_000); run(5_000)             // 끝남: 확인받을 때까지 축하만 한다
    precondition(seen == ["cheer"] && p.mood == "done", "확인 전인데 다른 동작을 함: \(seen)")

    p.mood = "idle"; run(2_000); run(20_000)            // 확인받음: 평소로 돌아간다
    precondition(seen.contains("walk") && seen.isDisjoint(with: moodOnly), "평소로 돌아오지 않음: \(seen)")

    // 두 펫 사이에 낀 펫: 바닥에서 부딪혀 넘어지다가 결국 한쪽의 머리를 밟고 넘어가 빠져나온다
    let wall = [CGRect(x: 240, y: 0, width: side, height: side), CGRect(x: 480, y: 0, width: side, height: side)]
    p = Pet(pos: CGPoint(x: 360, y: 0)); seen = []
    var out = false
    for _ in 0..<20_000 where !out {
        if ["fly", "climb", "hop", "doorin"].contains(p.name) { p.start("walk") }   // 날거나 타고 오르거나 문으로 빠져나가면 뛰어넘는지 볼 수 없다
        p.tick(in: area, floor: { _, _ in 0 }); p.meet(wall, in: area); seen.insert(p.name)
        out = p.pos.y == 0 && (p.pos.x < 240 - side * 0.6 || p.pos.x > 480 + side * 0.6)
    }
    precondition(out && seen.isSuperset(of: ["bump", "splat", "getup", "leap", "perch", "hopoff"]), "낀 펫이 빠져나오지 못함: \(seen)")
    // 노랑 보정은 노랑에서 연노랑을 그대로 내고, 30도 넘게 떨어진 색은 건드리지 않는다
    let rim = palette
    precondition(pastel(2, 100 / 360.0) == oklch(rim.yellow[2].L, rim.yellow[2].C, 100 / 360.0)
                 && pastel(2, 60 / 360.0) == oklch(rim.base[2].L, rim.base[2].C, 60 / 360.0), "노랑 보정이 틀림")
    precondition(palette.base.count == 4 && palette.yellow.count == 4, "몸 색이 네 가지가 아님")
    print("selftest ok")
}
