GOAL: Build a scored, weighted shortlist of publicly investable companies whose
core products or services materially improve people's lives. This is a research
and analysis exercise — NOT financial advice and NOT a trade instruction.

Spawn 5 teammates using Sonnet for each. This mirrors a scaled-down investment
firm: three analysts generate ideas, a senior analyst pressure-tests them, and an
independent risk function gates the final list. You (the lead) act as the
Portfolio Manager: you own the mandate, the scoring rubric, and the final
scored/weighted list. Wait for teammates to finish their stage before you score.

=== MANDATE / SCREEN (the anchor for everything) ===
A company qualifies only if a CORE product or service demonstrably improves human
lives — e.g. health & longevity, mental health, nutrition & food access, safety,
education & opportunity, financial inclusion, clean water/energy, accessibility.
Exclude companies whose primary revenue relies on harm (addiction, exploitation,
pollution) even if one division looks positive. "Improves lives" is a scored
dimension, not a yes/no — but a company failing it outright is dropped.

=== SHARED SCORING RUBRIC (identical for every analyst; 0–10 per dimension) ===
- Life-Improvement Impact ....... weight 30%  (breadth × depth of who's helped)
- Business Quality / Moat ........ weight 20%
- Financial Health ............... weight 15%
- Valuation / Upside ............. weight 20%  (base-case target vs. price; margin of safety)
- Risk / Thesis Fragility ........ weight 15%  (scored INVERSELY — higher = safer)
Composite = weighted sum, normalized to 0–100. Show the math.

=== TEAMMATES, OWNERSHIP, AND FILE PARTITIONING ===
Each teammate writes to ONLY its own file (single-writer — no shared files):
- Analyst-A → research/pitches/analyst-a.md — theme slice "Human Health & Wellbeing":
    health & longevity · mental/behavioral health · nutrition & food access · accessibility/assistive tech
- Analyst-B → research/pitches/analyst-b.md — theme slice "Opportunity & Inclusion":
    education & workforce · financial inclusion & security · digital access/connectivity · affordable housing & mobility
- Analyst-C → research/pitches/analyst-c.md — theme slice "Planet & Protection":
    clean energy · water & sanitation · environmental efficiency · safety & resilience (incl. cybersecurity)
- Senior-Analyst → research/reviews/senior-analyst.md
- Risk → research/risk-review.md
- Lead (PM) → research/scored-list.md   ← ONLY the lead writes the final list
- research/shared-notes.md → append-only scratchpad for cross-analyst insights
  (there is no broadcast; drop a note here or route via the lead instead of
  messaging every teammate individually)

=== PIPELINE (modeled task dependencies — the funnel) ===
Create these as explicit tasks with the stated dependencies, so the review loop is
enforced by the task graph rather than ad-hoc messaging. Revision is capped at ONE
round to keep the funnel bounded.

1. GENERATE-A / GENERATE-B / GENERATE-C (one task per analyst, parallel, no deps):
   each analyst proposes 10 candidate companies in its slice. Every pitch MUST include:
   ticker/exchange; a mandate-fit statement (who is helped, how directly, how many);
   bull / base / bear cases with the reasoning behind a rough base-case target; the 5
   rubric scores with justification; and the top 2–3 thesis-breakers.
   Done: all 10 pitches contain every element above.

2. REVIEW-1 (Senior-Analyst; depends on GENERATE-A + GENERATE-B + GENERATE-C):
   assign each pitch a verdict — PASS, REVISE (with specific, actionable reasons), or
   KILL. Attack the impact claim, the moat, and the valuation. Kill aggressively.
   Record the per-pitch verdicts in research/reviews/senior-analyst.md.

3. REVISE-A / REVISE-B / REVISE-C (one task per analyst; each depends on REVIEW-1):
   the analyst reworks ONLY its own REVISE-flagged pitches and resubmits them in its
   own file. If REVIEW-1 flagged none of an analyst's pitches, that analyst's REVISE
   task is a no-op and is marked complete immediately so it doesn't block downstream.

4. REVIEW-FINAL (Senior-Analyst; depends on REVISE-A + REVISE-B + REVISE-C):
   final verdict PASS or KILL only — no further revision (the one round is spent).
   Output the surviving PASS set, each with a confidence note.

5. SCORE & WEIGHT (Lead/PM; depends on REVIEW-FINAL): compute each survivor's composite,
   then assign target portfolio weights at the PORTFOLIO level — theme concentration,
   correlation between names, conviction. Draft research/scored-list.md as a ranked table.

6. RISK-GATE (Risk; depends on the SCORE & WEIGHT draft): independently review the draft
   for over-concentration, correlated bets, oversized single positions, and any mandate/
   harm red flags the enthusiasm missed. Flag names for resize or removal with written
   reasons. Route findings to the lead only.

7. FINALIZE (Lead/PM; depends on RISK-GATE): apply or overrule Risk's flags (documenting
   why), and produce the final research/scored-list.md.

=== FINAL DELIVERABLE: research/scored-list.md ===
A ranked table: Rank | Company (Ticker) | Theme | Life-Improvement thesis (1 line)
| Composite /100 | Target portfolio weight % | Key thesis-breaker | Senior-Analyst
confidence | Risk flag. Below the table: methodology notes and every assumption
that needs human verification.

=== GUARDRAILS ===
- Front-load: teammates don't see this conversation's history — restate context in
  each spawn.
- Every quantitative claim (revenue, margins, valuation) is an ESTIMATE requiring
  human verification; label anything you're unsure of rather than asserting it.
- Data sources: use ONLY publicly available sources — company filings (10-K/10-Q,
  annual & investor-relations reports), reputable financial news and public databases,
  and web search. No authenticated, paid, or real-time brokerage feeds. Cite the source
  and the as-of date for every quantitative figure, and flag anything stale or estimated.
- As-of date (PINNED): every analyst uses the SAME valuation snapshot for prices and
  market caps — the most recent market close as of [SET DATE AT SPAWN, e.g. 2026-07-02].
  Do not mix as-of dates across pitches; a composite score is only comparable on one snapshot.
- The loop matters: note for each name what would trigger a re-evaluation or exit
  (broken thesis, hit target), not just the buy case.
- Watchdog the funnel: if a blocked stage hasn't started within a reasonable window
  of its upstream tasks completing, check for a teammate that finished work but
  failed to mark its task done, and nudge or update the status so dependents unblock.
- Slice boundaries & tie-break: assign each company to the single analyst whose theme
  is its PRIMARY revenue driver. A borderline name goes to one analyst only — if unsure
  which, drop it in research/shared-notes.md and let the lead assign. Do not pitch a
  company that sits primarily in another analyst's slice.
