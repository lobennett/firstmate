---
name: ahoy
description: Recap visible session events and guide the PI through visibly unanswered decisions when the PI explicitly invokes /ahoy, with a Bearings fallback when /ahoy is the session's first real PI message.
user-invocable: true
metadata:
  internal: true
---

# Session recap

Give the PI a concise session-only recap without gathering fresh state.
The `/ahoy` command name is retained for compatibility, not as a chat persona.

0. Before anything else, confirm a `SESSION START` digest for this home is visible in session history.
   If absent, run `bin/fm-session-start.sh` exactly once and read its digest before producing a recap.
   Run-tier integrations normally satisfy this automatically; this check protects other entry paths.
   Its digest is operational input, never a PI message or a recap event.
1. Inspect only conversation or session history already visible to the current lab manager.
2. Find the most recent real PI-authored message before this `/ahoy` invocation.
   A PI boundary is an ordinary user-role message unless it matches one of these narrow exclusions:
   - A message beginning with the current U+2063 `FIRSTMATE_OP:` injection prefix.
   - A legacy bare-marker away-mode injection with U+2063 immediately followed by `Supervisor escalate (`.
   - An exact record-backed operational doorbell recognized from stdin by `bin/fm-operational-input.sh doorbell-kind`; Claude Code strips U+2063 and receives away-mode escalations this way.
   - The exact legacy unmarked payload ``Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.``.
   Custom-role messages such as Pi's `firstmate-sessionstart-nudge`, and system, developer, tool, watcher, guard, and away-mode injections, are not PI messages.
   Never infer PI authorship merely from the user-role transcript.
   Ordinary messages remain PI boundaries when they begin with U+2063 followed by other text, contain ASCII `FIRSTMATE_OP:` without the leading separator, quote or embed operational input after ordinary text, or add anything to the legacy payload.
   For example, `PI quote: ` or legacy `Captain quote: ` before a current prefix or the legacy payload makes the whole message an ordinary PI boundary.
3. If no prior real PI message exists, load [`../bearings/SKILL.md`](../bearings/SKILL.md) and follow it exactly.
   Bearings alone owns its gathering, artifact, and response contract; do not restate it or combine a session recap with its output.
4. Otherwise recap what happened after that prior message and before the current invocation.
   Include concrete outcomes, completed work, failures, decisions made or needed, and work still running only when those events appear in that visible interval.
   Use PI-facing outcome language and preserve every full PR URL in the interval.
5. Also inspect the entire visible session before the current invocation for explicit PI decisions still unanswered, including those predating the recap boundary.
   An unrelated later message does not close a decision.
   Only a visible response that substantively resolves the question, selects or declines an option, grants or denies approval, or otherwise directly answers it closes it.
   Include each visibly supported open decision once, deduplicating by substance across the recap and decision inventory.
6. Apart from step 0, this branch uses session history only.
   Do not call Bearings, shell commands, lab snapshots, status readers, GitHub or browser APIs, other tools, or file reads or writes.
   Create no report, persist nothing, and infer no current live state beyond the last visible event.
7. If no ordinary events occurred but an older open decision exists, report that decision rather than claiming nothing happened.
   If neither events nor open decisions exist, say in one sentence that nothing happened after the prior PI message.
8. When that existing inventory contains decisions, present only the one the lab manager judges most impactful.
   Say the ordering is the lab manager's pick, with the decision, consequence, options, and recommendation.
9. After the PI answers, present the next highest-impact decision from that same inventory.
   Continue one decision at a time until none remain; never start the flow with an empty inventory.

The current invocation is outside the recap interval; an earlier `/ahoy` is a real PI message and may be the next boundary.
If compaction hides the prior boundary, disclose that the exact boundary is unavailable and summarize only visibly supported events.
Compacted history supports an open decision only when both its request and still-unanswered status are visible; disclose uncertainty instead of reconstructing hidden requests or answers.
Do not silently invoke Bearings unless this is genuinely the first real PI message.
