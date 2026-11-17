---
name: pet
description: 이 Claude 세션의 바탕화면 펫을 켜고, 끄고, 색이나 이름을 바꾼다. 트리거는 "/pet on", "/pet off", "/pet color", "/pet name", "/pet kind", "펫 켜줘", "펫 꺼줘", "펫 색 바꿔줘", "이모지 온".
---

# pet

이 세션에 딸린 바탕화면 펫을 다룬다. 인자는 `$ARGUMENTS` 다.

| 인자 | Bash 로 실행할 명령 |
|---|---|
| `on` 또는 비어 있음 | `"${CLAUDE_PLUGIN_ROOT}/scripts/mochipet" --on` |
| `on <이름>` | `"${CLAUDE_PLUGIN_ROOT}/scripts/mochipet" --on --name "<이름>"` |
| `off` | `"${CLAUDE_PLUGIN_ROOT}/scripts/mochipet" --off` |
| `color` | `"${CLAUDE_PLUGIN_ROOT}/scripts/mochipet" --color` |
| `color <색>` | `"${CLAUDE_PLUGIN_ROOT}/scripts/mochipet" --color <색>` |
| `name <이름>` | `"${CLAUDE_PLUGIN_ROOT}/scripts/mochipet" --name "<이름>"` |
| `kind <종류>` | `"${CLAUDE_PLUGIN_ROOT}/scripts/mochipet" --kind <종류>` |

- 펫 머리 위 이름표에는 Claude 데스크탑의 세션 제목이 쓰인다. `on <이름>` 이나 `name <이름>` 으로 이름을 주면 그 이름이 우선한다.
- `<색>` 은 컬러 red, orange, yellow, green, blue, purple, pink (또는 빨강, 주황, 노랑, 초록, 파랑, 보라, 분홍) 이나 0~360 숫자, 무늬 white, ivory, cream, gray, silver, golden, patch (또는 흰색, 아이보리, 크림, 회색, 은회색, 골든, 얼룩), 또는 default(기본)다. 강아지는 pug(퍼그), shiba(시바), 고양이는 siamese(샴)도 쓸 수 있다. 색을 안 주면 무늬 중에서 지금 색만 빼고 무작위로 고르고(메뉴바의 "랜덤" 이 컬러 랜덤이면 컬러 중에서), default 를 주면 그 종류의 기본 색(토끼는 흰색, 강아지는 골든, 고양이는 샴)으로 돌아간다.
- `on` 으로 처음 켤 때는 종류(토끼, 강아지, 고양이)를 무작위로 정하고, 색도 같은 방식으로 무작위로 정한다.
- `<종류>` 는 bunny(도트 토끼), dog(도트 강아지), cat(도트 고양이), 또는 `sprites/<종류>/` 폴더를 만들어 둔 이름이다. "토끼로 바꿔줘" 는 `kind bunny`, "강아지로 바꿔줘" 는 `kind dog`, "고양이로 바꿔줘" 는 `kind cat` 다.
- 명령 하나만 실행하고, 출력된 한 줄을 그대로 전한다. 다른 작업은 하지 않는다.
- 플러그인으로 설치한 뒤 처음 켤 때는 펫 앱을 빌드하느라 10~20초쯤 걸린다. 그동안 기다린다.
- 세션 id 는 Claude Code 가 Bash 에 넣어 주는 `CLAUDE_CODE_SESSION_ID` 에서 프로그램이 직접 읽으므로 넘기지 않는다.
