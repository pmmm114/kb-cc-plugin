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
| `Stop` | **비정상** block/deny 1회 이상 | 세션 내 에러 패턴 감지 (routine guard denies 제외) |
| `SubagentStop` | **비정상** block/deny 1회 이상 | 에이전트 실패 감지 (agent_id 스코프 + routine deny 필터링) |

### Routine deny 제외 (false-positive 방지)

하네스가 **설계대로** 동작하는 guard deny 는 threshold 에서 제외됩니다. 그렇지 않으면 정상적인 `/kb-harness` 진입이나 plan-before-act 흐름이 target 레포에 false-positive incident 로 쌓입니다:

| Hook | 제외 조건 |
|---|---|
| `pre-edit-guard.sh` | `phase ∈ {planning, reviewing, plan_review, config_planning, config_plan_review, config_editing}` |
| `agent-dispatch-guard.sh` | 항상 제외 (always a routing guard) |
| `pr-template-guard.sh` | 항상 제외 (`/pr` skill 라우팅) |
| `worktree-guard.sh` | `phase == idle` 또는 `phase` 가 `config_` 로 시작 |
| `guardian-worktree-guard.sh` | 항상 제외 (worktree 진입 강제) |

예기치 않게 같은 hook 이 다른 phase 에서 deny 하면 정상 incident 로 분류됩니다.

## GitHub Issue Format

[observation-log 택소노미](https://github.com/pmmm114/claude-harness-engineering/issues/37)를 따릅니다.

**대상 레포**: `pmmm114/claude-harness-engineering`

Title 형식:

```
[incident] EVENT(agent_id) (session_id_8)
```

예시:

```
[incident] SubagentStop(tdd-implementer) (a1b2c3d4)
```

### Labels

| Label | 설명 |
|-------|------|
| `type:incident` | 자동 생성은 항상 incident |
| `auto:hook-failure` | 자동 생성 구분용 |
| `severity:<level>` | 심각도 자동 분류 (아래 참조) |
| `reporter:domain:<area>` | hook/agent/infra 중 자동 추론 (플러그인 namespace) |
| `reporter:agent:<name>` | `agent_id` 가 있는 경우 — 값은 Claude Code 가 `Agent(subagent_type=...)` 에 전달한 문자열 그대로 (하네스-코어/플러그인 공급 agent 모두) |

> `reporter:` 접두사는 다른 자동화/사람이 소유한 `domain:*`/`agent:*` 라벨과의 충돌을 방지하기 위한 namespace 입니다 (E4 리뷰 피드백).
>
> `reporter:agent:<name>` 의 `<name>` 은 **하드코딩된 allowlist 없이** hook input 의 `agent_id` 필드를 그대로 반영합니다 (issue #15). 하네스-코어 agent (`planner`, `editor`, `guardian`) 는 물론, 다른 플러그인이 공급하는 sub-agent (예: skill-creator 의 `grader`/`comparator`/`analyzer`, code-simplifier 의 `code-simplifier`) 도 자동으로 per-agent 라벨을 받습니다. 하네스의 `subagent-validate.sh` 가 이미 `agent_id` 값을 게이트하므로 플러그인 수준의 중복 검증은 불필요하다는 설계 판단입니다.

### Severity 자동 분류

| Event | 조건 | Severity |
|-------|------|----------|
| `StopFailure` | timeout 에러 | `A3-resource` |
| `StopFailure` | 그 외 | `A1-coordination` |
| `Stop` | block/deny 감지 | `A2-guard-recovered` |
| `SubagentStop` | block/deny 감지 | `A2-guard-recovered` |

### Body 구조

observation-log 템플릿 필드를 따르되, 자동/수동을 구분합니다:

| 필드 | 자동 채움 | 수작업 |
|------|-----------|--------|
| Event, Agent, Session ID, Phase, Trigger Commit | ✓ | |
| Severity, Reproducibility ("observed once") | ✓ | |
| Evidence (debug log, transcript, state, hook input) | ✓ | |
| Counterfactual | | ✓ (placeholder) |
| Hypothesis | | ✓ (placeholder) |

## Prerequisites

- `jq` 설치 (hook input JSON 파싱에 필수)
- `gh` CLI 설치 및 인증 (`gh auth login`)
- `pmmm114/claude-harness-engineering` 레포에 쓰기 권한

라벨은 존재하지 않으면 자동 생성됩니다.

## Enable / Disable

```bash
# 활성화 (기본값 — settings.json에 등록됨)
# enabledPlugins: "./plugins/local/error-reporter": true

# 외부 프로젝트에서 비활성화
echo '{"enabledPlugins":{"./plugins/local/error-reporter":false}}' > .claude/settings.local.json

# 또는 CLI
claude plugin disable ./plugins/local/error-reporter --scope local
```

## Local archive (always-on)

**리포트 본문은 gh 성공 여부와 무관하게 항상 로컬에 먼저 기록됩니다** (E3 리뷰 피드백). 대상 레포가 삭제/privated/rotated 되어도 local archive 가 남아있어 post-hoc forensics 가 가능합니다.

```
${CLAUDE_PLUGIN_DATA}/reports/<session_id>-<epoch>-<pid>.md
```

- 파일 권한은 `0600` (본문에 세션 ID, state snapshot, hook input 등 민감 필드 포함)
- `<pid>` 접미사는 같은 세션·같은 epoch 초에 두 건의 이벤트가 겹쳐도 파일 충돌을 막기 위함
- 처리 순서: **local archive → gh issue create**. gh 가 성공해도 로컬 md 는 보존됨

### 리포트 라이프사이클

```
[event] → (local archive) → (gh issue create) → (marker touch if ANY sink ok)
            필수            선택(fallback-only 가능)        세션 dedup
```

- gh 성공: 둘 다 보존, marker touch
- gh 실패: 로컬만 보존 + `error-reporter.log` 에 진단, marker touch
- gh 미설치/미인증: 로컬만 보존, marker touch
- 로컬 + gh 둘 다 실패: marker **미touch**, 다음 이벤트에서 재시도

### 진단 로그: `error-reporter.log`

`gh issue create` 의 성공/실패 여부를 단일 라인 key=value 포맷으로 추적합니다. "empty log == 리포터가 한 번도 실행되지 않음" 을 healthy 와 구분할 수 있도록 **성공 시에도 audit breadcrumb** 를 남깁니다.

```
${CLAUDE_PLUGIN_DATA}/logs/error-reporter.log
```

포맷:
```
[<epoch>] status=ok   event=<event> sid=<full-sid> phase=<phase> agent=<agent> domain=<domain> commit=<sha>
[<epoch>] status=fail event=<event> sid=<full-sid> phase=<phase> agent=<agent> domain=<domain> commit=<sha> exit=<N> stderr=<quoted>
```

- Timestamp 는 epoch 초(`/tmp/claude-debug/*.jsonl` 과 correlation 용이)
- Session ID 는 full 36-char (8-char truncation birthday collision 방지)
- `stderr` 는 `tr '\n\r' '  '` 정규화 후 512 바이트 cap + `%q` 쉘 인용
- Ring buffer: 1000 라인 초과 시 **첫 줄(first-occurrence 보존)** + 마지막 499 라인으로 트림
- 파일 권한: `0600` (gh stderr 가 일부 failure mode 에서 auth token 단편을 echo 하는 경우 대비)

## Self-test

On-call triage 용 — 의존성, 대상 레포 도달 가능성, 최근 활동, 마커/락 상태를 **부작용 없이** 진단:

```bash
bash plugins/local/error-reporter/scripts/report.sh --self-test
```

출력 예시:
```
error-reporter self-test
========================

dependencies:
  [ok]   jq: jq-1.6
  [ok]   gh: gh version 2.63.0 (2024-11-27)
  [ok]   gh auth: authenticated
  [ok]   target repo reachable: pmmm114/claude-harness-engineering

data dir:
  [ok]   /Users/kb/.claude/reports (writable)

recent activity:
  error-reporter.log: 42 lines
  last 5 entries:
    [1744650000] status=ok event=Stop sid=abc...
    ...
  status tally: ok=38 fail=4
  fallback .md reports: 27 in /Users/kb/.claude/reports/reports
  /tmp markers: 12 reported, 0 lockdirs

(no side effects: no issues created, no files written)
```

`error-reporter.log` 이 비어 있거나 없으면 "리포터가 한 번도 실행되지 않음" 으로 분류됨 (healthy 와 구분).

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
- **중복 방지**: 세션별 marker file (`/tmp/claude-report-{SESSION}.reported`) 로 보통 세션당 1회만 리포트. 단 `gh` 와 로컬 폴백이 **모두** 실패한 경우 마커는 찍히지 않아 다음 이벤트에서 재시도 (세션 가시성 보장). `mkdir` atomic lock 으로 동시 fork 경합 방지, SIGKILL/OOM 으로 남은 5분 이상 경과 lock 은 재활용. `/tmp/claude-report-*` 아티팩트는 7일 TTL 로 opportunistic sweep.

## Plugin Self-Containment

이 플러그인은 `hook-lib.sh`에 대한 런타임 의존이 없습니다. Agent context (`agent_id`, `is_subagent`)는 hook input stdin의 JSON에서 직접 `jq`로 추출합니다. Layer 1의 debug log는 읽기 전용 데이터 소스로만 사용됩니다.

## Related

- `hooks/hook-lib.sh` — Layer 1 debug logger + Exit Handler Registry
- `hooks/state-recovery.sh` — SessionEnd 시 debug log 정리
- `rules/code-quality.md` § 11 — `no-raw-exit-trap` 규칙
