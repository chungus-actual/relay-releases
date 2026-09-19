# Relay memory soak — 2026-09-12

Tested Relay 0.4.2 on Windows with the self-contained executable and fresh, isolated WebView2 profiles. No real accounts were used.

## Workload

608 seconds; seven synthetic services, 81 reconnect cycles, and 21 popup opens/closes. The run used approximately two minutes of warmup, six minutes of switching/reconnecting and UI rebuilding, then two minutes of recovery with the same seven services connected. A final step disconnected every service.

## Results

| Metric | Warm baseline | After recovery | After disconnect |
| --- | ---: | ---: | ---: |
| Managed memory (MiB) | 3.69 | 4.06 | 3.79 |
| Host private bytes (MiB) | 128.41 | 133.29 | 135.82 |
| Browser private bytes (MiB) | 333.61 | 343.10 | 0.00 |
| Host handles | 801 | 833 | 745 |
| Reported browser processes | 11 | 11 | 0 |
| Attached browser views | 7 | 7 | 0 |
| Open popups | 0 | 0 | 0 |

- Disposed browser controls still reachable: **0 of 88**.
- Closed popup windows still reachable: **0 of 21**.
- No runtime errors; view, popup, and pending-initialization counts stayed bounded.

All three table snapshots follow diagnostic full collections. Normal Relay operation never forces garbage collection. Private bytes measure committed process memory, not resident RAM; browser totals use WebView2's process list and exclude its crash reporter. Raw samples also include summed working sets, which can count shared pages more than once.

Managed retention changed by 0.37 MiB with the same services connected. Host private bytes changed by 4.88 MiB and browser private bytes by 9.49 MiB. These differences can include runtime/allocator and browser caches; this run alone cannot assign every byte or prove the absence of a long-term leak.

## Fix found by the test

The first 60-second pilot retained one disposed WebView2 control after returning to Activity. Moving WPF logical focus to the Activity/Settings navigation button removed that retention: the repeat pilot collected all 15 retired views and two popups. The sustained run above verifies the same fix under more churn.

## Log retention

Both error paths now use one synchronized rolling writer: errors.log plus three archives, each limited to 1 MiB. It bounds oversized Unicode entries, retains a bounded tail when rotating old oversized logs, and tolerates locked/unwritable files without recursively throwing from error handling. Rotation, expiry, concurrency, legacy-size handling, truncation, and recovery are covered by the smoke test.

## Reproduce and limits

Run `powershell -File scripts/Soak.ps1 -Seconds 600`. Raw JSONL samples and summaries are written to ignored `artifacts/memory-soak/` folders; `artifacts/latest-memory-soak.txt` identifies the latest run.

This exercises Relay lifecycle behavior with small intercepted pages, not Messenger/Gmail/etc. authenticated applications, large conversations, media calls, extensions, or an overnight workload. Real signed-in usage still needs a separate soak.
