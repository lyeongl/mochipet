#!/bin/sh
# 앱을 빌드하고 /pet 스킬과 Claude Code 훅을 ~/.claude 에 설치한다.
#   ./install.sh             설치 (다시 돌려도 된다. 예전 항목을 지우고 새로 넣는다)
#   ./install.sh uninstall   스킬, 훅, 세션 상태, 백업을 지운다
set -e
cd "$(dirname "$0")"
BIN="$PWD/MochiPet.app/Contents/MacOS/MochiPet"
SKILL="$HOME/.claude/skills/pet"

if [ "$1" != uninstall ]; then
    ./build.sh
fi

# ~/.claude/settings.json 의 hooks 에서 이 펫의 항목만 넣고 뺀다. 다른 훅과 설정은 건드리지 않는다.
/usr/bin/python3 - "$BIN" "$1" <<'EOF'
import json, os, shutil, sys
bin_, uninstall = sys.argv[1], sys.argv[2:] == ["uninstall"]
path = os.path.expanduser("~/.claude/settings.json")
backup = path + ".pet-backup"
existed = os.path.exists(path)
try:
    settings = json.load(open(path)) if existed else {}
except ValueError as e:
    sys.exit(f"{path} 이 올바른 JSON 이 아니라서 훅을 건드리지 않았다: {e}")
mine = lambda h: "MochiPet" in h.get("command", "")
hooks = settings.setdefault("hooks", {})
# 펫 훅이 없는 상태일 때만 백업한다. 다시 설치해도 설치 전 모습이 남는다.
if existed and not uninstall and not any(mine(h) for gs in hooks.values() for g in gs for h in g.get("hooks", [])):
    shutil.copy(path, backup)
events = {  # 이벤트: (펫 상태, 도구 실행을 기다리게 하지 않을지)
    "UserPromptSubmit": ("working", False),   # 프롬프트를 보냈다
    "PermissionRequest": ("waiting", False),  # 권한 승인을 기다린다
    "PostToolUse": ("resume", True),          # 도구가 끝났다: 기다리던 중이었으면 다시 일한다
    "Stop": ("done", False),                  # 턴이 끝났다
    "SessionEnd": ("end", False),             # 세션이 끝났다
}
for event, (state, background) in events.items():
    groups = []
    for g in hooks.get(event, []):            # 예전에 넣은 항목을 걷어낸다
        g["hooks"] = [h for h in g.get("hooks", []) if not mine(h)]
        if g["hooks"]:
            groups.append(g)
    if not uninstall:
        h = {"type": "command", "command": f'"{bin_}" --hook {state} 2>/dev/null || true'}
        if background:
            h["async"] = True
        groups.append({"hooks": [h]})
    if groups:
        hooks[event] = groups
    else:
        hooks.pop(event, None)
if not hooks:
    del settings["hooks"]
if uninstall and not settings:                # 설치하면서 만든 빈 파일이면 지운다
    if existed:
        os.remove(path)
else:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)
if uninstall and os.path.exists(backup):
    os.remove(backup)
print("훅을 지웠다" if uninstall else "훅 5개를 넣었다", "->", path)
EOF

if [ "$1" = uninstall ]; then
    rm -rf "$SKILL" "$HOME/.claude/mochipet"
    rmdir "$HOME/.claude/skills" 2>/dev/null || true   # 비어 있을 때만 지워진다
    echo "스킬을 지웠다"
else
    mkdir -p "$SKILL"
    # 스킬 파일은 플러그인과 같이 쓴다. 플러그인용 경로를 이 폴더의 실행 파일로 바꿔서 넣는다.
    sed "s|\"\${CLAUDE_PLUGIN_ROOT}/scripts/mochipet\"|\"$BIN\"|g" skills/pet/SKILL.md > "$SKILL/SKILL.md"
    echo "설치 끝. Claude 세션에서 /pet on"
fi
