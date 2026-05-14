# stall_detector fixtures

`scripts/stall_detector.sh` の bats unit test (`tests/unit/test_stall_detector.bats`) 用
fixture 群。各 scenario ディレクトリは `queue/` tree を持ち、test は

```
cp -r tests/fixtures/stall_detector/<scenario>/queue/. "$STALL_ROOT/queue/"
```

で隔離した `STALL_ROOT` に展開してから `stall_detector.sh --once` を走らせる。

## 時刻基準 (anchor)

fixture 内の timestamp は **固定 ISO 8601** で記述する。test 側は `STALL_NOW`
(epoch injection hook) を anchor からの相対時刻で与えて閾値を制御する。

anchor: `2026-05-15T00:00:00`

## scenario 一覧

| dir | 用途 |
|-----|------|
| `blocked_unresolved/` | blocked report が未解決。`STALL_NOW` で 15m 未満 / P1 / P0 を出し分け |
| `blocked_resolved/`   | 上の report が done (terminal) に変化した版。auto-resolve 検証用に差し替える |
| `assigned_no_progress/` | assigned のまま進捗なし (worktree なし)。idle 2 連続 scan で alert |
| `assigned_worktree/`  | `worktree:` に `@@WORKTREE@@` placeholder。test が実 path に置換し worktree progress 抑制を検証 |
| `fp_idle_null/`       | false-positive control: `status: idle` + `task_id: null` |
| `fp_blocked_by/`      | false-positive control: `blocked_by` 持ち (意図的 dependency hold) |
