#!/bin/sh
# 1.x 를 ./install.sh 로 설치한 분이 그 설치를 지울 때 쓴다. 2.0 부터는 플러그인으로만 설치한다 (README).
#   ./install.sh uninstall   1.x 가 넣은 훅, 스킬, 세션 상태, 앱 설정, 백업을 지운다
if [ "$1" != uninstall ]; then
    echo "2.0 부터는 플러그인으로 설치합니다:"
    echo "  claude plugin install mochipet --marketplace lyeongl/mochipet"
    echo "1.x 설치를 지우려면: ./install.sh uninstall"
    exit 1
fi

# ~/.claude/settings.json 의 hooks 에서 이 펫의 항목만 뺀다. 다른 훅과 설정은 건드리지 않는다.
/usr/bin/python3 - <<'EOF'
import json, os, sys
path = os.path.expanduser("~/.claude/settings.json")
if os.path.exists(path):
    try:
        settings = json.load(open(path))
    except ValueError as e:
        sys.exit(f"{path} 이 올바른 JSON 이 아니라서 훅을 건드리지 않았다: {e}")
    hooks = settings.get("hooks", {})
    for event in list(hooks):
        groups = []
        for g in hooks[event]:
            g["hooks"] = [h for h in g.get("hooks", []) if "MochiPet" not in h.get("command", "")]
            if g["hooks"]:
                groups.append(g)
        if groups:
            hooks[event] = groups
        else:
            del hooks[event]
    if "hooks" in settings and not hooks:
        del settings["hooks"]
    if settings:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(settings, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, path)
    else:                                     # 설치하면서 만든 빈 파일이면 지운다
        os.remove(path)
backup = path + ".pet-backup"
if os.path.exists(backup):
    os.remove(backup)
print("훅을 지웠다 ->", path)
EOF

rm -rf "$HOME/.claude/skills/pet" "$HOME/.claude/mochipet"
rmdir "$HOME/.claude/skills" 2>/dev/null || true   # 비어 있을 때만 지워진다
defaults delete local.mochipet 2>/dev/null || true # 1.x 가 남긴 앱 설정
echo "스킬, 세션 상태, 앱 설정을 지웠다"
