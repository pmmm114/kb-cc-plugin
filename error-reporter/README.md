# error-reporter

Hook debug log를 분석하여 fail 이벤트 발생 시 error stack을 GitHub Issue로 자동 등록하는 플러그인.

## Architecture

2-layer 구조로 동작합니다.

### Layer 1: Debug Logger (hook-lib.sh)

`hook-lib.sh`의 `emit_block`, `emit_deny_json`, `emit_guidance` 함수에 삽입된 로깅이 모든 훅 결정을 자동 기록합니다.

- **로그 위치**: `/tmp/claude-debug/<session_id>.jsonl`
- **로그 포맷**: JSONL (한 줄 = 한 결정)
- **필드**: `ts`, `event`, `hook`, `decision`, `reason`, `phase`, `wf_id`, `session`, `agent_id`
- **Decision 유형**: `allow`, `block`, `deny`, `guide`
- **Ring buffer**: 1000줄 초과 시 500줄로 자동 트림
- **정리**: SessionEnd 시 자동 삭제 (`state-recovery.sh`)

```jsonl
{"ts":"2026-04-01T12:00:01Z","event":"PreToolUse","hook":"pre-edit-guard.sh","decision":"deny","reason":"Edit blocked during intake","phase":"intake","wf_id":"3","session":"abc123"}
```

> Layer 1은 플러그인과 독립적으로 동작합니다. 플러그인 비활성화 시에도 로그는 계속 기록됩니다.

### Layer 2: Error Reporter (this plugin)

Layer 1의 로그를 읽고, fail 이벤트 감지 시 GitHub Issue를 생성합니다.
**Raw Data Reporter** — state.json을 파싱하지 않고 원본 그대로 적재합니다. 해석은 이슈를 읽는 사람이 수행합니다.

**실행 모델**: Synchronous snapshot → Background fork → Immediate exit 0

```
[Hook event] → report.sh → 파일 읽기 (동기, ~1ms) → fork & disown → exit 0
                                                        ↓ (백그라운드)
                                                   gh issue create
```

## Trigger Events

| Event | Threshold | 설명 |
|-------|-----------|------|
| `StopFailure` | 없음 (항상 리포트) | API 에러. `rate_limit`, `server_error`는 transient로 필터링 (이슈 미생성) |
| `Stop` | block/deny 1회 이상 | 세션 내 에러 패턴 감지 |
| `SubagentStop` | block/deny 1회 이상 | 에이전트 실패 감지 (agent_id 스코프 필터링) |

## GitHub Issue Format

Title 형식:

```
[harness-debug] EVENT (session_id_8)
```

예시:

```
[harness-debug] SubagentStop (a1b2c3d4)
```

Issue body 구조 (raw data — 파싱/해석 없음):

- **Raw State**: `state.json` 원본 전체 (JSON)
- **Debug Log (last 50)**: debug log 마지막 50줄
- **Transcript (last 20 lines)**: transcript 마지막 20줄
- **Hook Input**: hook event input JSON 원본

## Prerequisites

- `jq` 설치 (hook input JSON 파싱에 필수)
- `gh` CLI 설치 및 인증 (`gh auth login`)
- 현재 디렉토리가 GitHub 리포지토리
- `harness-debug` 라벨이 리포지토리에 존재

```bash
gh label create harness-debug --description "Auto-generated harness debug reports" --color "d93f0b" --force
```

## Enable / Disable

```bash
# 활성화 (기본값 — settings.json에 등록됨)
# enabledPlugins: "./plugins/local/error-reporter": true

# 외부 프로젝트에서 비활성화
echo '{"enabledPlugins":{"./plugins/local/error-reporter":false}}' > .claude/settings.local.json

# 또는 CLI
claude plugin disable ./plugins/local/error-reporter --scope local
```

## Fallback

`gh` CLI가 없거나 인증 실패 시, 리포트를 로컬 파일로 저장합니다:

```
${CLAUDE_PLUGIN_DATA}/reports/<session_id>-<timestamp>.md
```

## File Structure

```
plugins/local/error-reporter/
├── .claude-plugin/
│   └── plugin.json        # 플러그인 매니페스트
├── hooks/
│   └── hooks.json         # StopFailure, Stop, SubagentStop 훅 등록
├── scripts/
│   └── report.sh          # 리포터 (snapshot → fork → issue create)
└── README.md              # 이 파일
```

## Safety Guarantees

- `report.sh`는 **어떤 상황에서도 `exit 0`** — 워크플로우 블로킹 불가
- 네트워크 I/O는 `& disown`으로 백그라운드 실행 — 훅 timeout 무관
- 동기 구간은 파일 읽기만 (~1ms) — Claude Code 응답 지연 없음
- Layer 1 로깅은 서브셸 + `>/dev/null 2>/dev/null || true` — stdout/stderr 오염 없음
- **중복 방지**: 세션별 marker file (`/tmp/claude-report-{SESSION}.reported`)로 1회만 리포트, `mkdir` atomic lock으로 동시 fork 경합 방지

## Plugin Self-Containment

이 플러그인은 `hook-lib.sh`에 대한 런타임 의존이 없습니다. Agent context (`agent_id`, `is_subagent`)는 hook input stdin의 JSON에서 직접 `jq`로 추출합니다. Layer 1의 debug log는 읽기 전용 데이터 소스로만 사용됩니다.

## Related

- `hooks/hook-lib.sh` — Layer 1 debug logger + Exit Handler Registry
- `hooks/state-recovery.sh` — SessionEnd 시 debug log 정리
- `rules/code-quality.md` § 11 — `no-raw-exit-trap` 규칙
