# Transaction analysis workspace

Implement a dedicated, saved transaction-analysis workspace on the user's fork of Sure. Start from `fork/main` commit `e7634043c0807d8e2c744e7794c8cefbb44dfffb` on branch `feat/transaction-analysis-workspace`.

Sure is a Rails application with Hotwire/Turbo, ViewComponent, Tailwind design tokens, Minitest, and background jobs. Follow `/Users/calebbolden/Projects/sure-hermes/AGENTS.md`. Reuse the configured OpenAI, Anthropic, or Gemini provider through the existing provider registry, but do not route this workflow through the generic chat assistant because that registry contains mutation tools.

## Confirmed product contract

- The form always shows account and date filters. All history is an explicit selection, not the default.
- Results contain a concise conclusion, deterministic calculations, and linked supporting transactions. Charts appear only when the data shape benefits from one.
- The model may receive merchant, amount, currency, date, category, and a user-friendly account label. It must not receive account numbers, internal IDs, notes, external IDs, or unnecessary identifiers.
- A saved analysis supports scoped follow-up questions. Every rerun creates a new immutable version with its prompt, scope, result, evidence, provider/model, and timestamp.
- Results are read-only. They may not invoke existing update/create assistant tools. Reviewable mutation suggestions are future work.
- The app performs filtering, grouping, aggregation, currency conversion, and comparisons. The model interprets verified outputs.
- Material ambiguity produces one focused clarification question. Otherwise the result lists its assumptions.

## Implementation defaults

- Initial scope: all accessible visible accounts and the trailing 12 months.
- “All history” is represented explicitly and resolves to the earliest accessible transaction date when a run starts.
- Aggregates use confirmed income and expenses and exclude transfers unless the prompt explicitly asks for pending transactions or transfers.
- Evidence is capped at 25 cited transactions per run. The result may link to the validated transaction filter for the complete matching set.
- Completed runs are immutable. Pending or clarification-waiting runs may transition state until completion.

## Required architecture

- `TransactionAnalysis` is the user-owned saved workspace/thread.
- `TransactionAnalysis::Run` is one prompt execution or follow-up. It stores the immutable scope, deterministic output, narrative result, assumptions, chart specification, provider/model, state, and optional rerun lineage.
- `TransactionAnalysis::Evidence` stores an opaque citation token, optional transaction foreign key, and a safe snapshot so history remains explainable after a transaction changes or is deleted.
- `TransactionAnalysis::Calculator` is the only code allowed to calculate numbers. It scopes through `Current.user.accessible_accounts.visible` and builds on `Transaction::Search` and existing exchange-rate conventions.
- `TransactionAnalysis::Runner` owns the provider tool loop. Its allowlist contains only deterministic calculators, evidence selection, clarification, and final submission.
- Model output refers to calculation tokens such as `C1` and evidence tokens such as `E1`. The server validates every reference before completion.
- Charts are rendered from a validated server-generated specification. Never render model-authored HTML, SVG, JavaScript, or arbitrary chart configuration.

## Subagent workflow

Each phase is a bounded implementation assignment with one owner and a disjoint write scope. The coordinator owns migrations, shared routes, integration, commits, and the running decision log. After each phase, an independent read-only reviewer checks security, regressions, scope adherence, and tests before the phase is accepted. Do not run overlapping implementation writers in parallel.

<!-- model: sonnet -->
## Phase 1 — Persistence, lifecycle, and ownership

Allowed scope: database migrations/schema, `TransactionAnalysis*` models, user associations, fixtures, model tests, routes, and minimal controllers needed to exercise lifecycle. Do not implement provider calls or the final UI.

- [ ] Add migrations for `transaction_analyses`, `transaction_analysis_runs`, and `transaction_analysis_evidences`, including foreign keys, status/lineage indexes, JSON defaults, timestamps, and safe delete behavior.
- [ ] Add models with ownership, status, scope, completion, lineage, evidence-token, and immutability validations. Add `User#transaction_analyses` with dependent cleanup.
- [ ] Add nested routes and controllers for list/show/create/update/destroy analyses plus create, clarify, and rerun actions for runs. Scope every lookup through `Current.user`.
- [ ] Add fixtures and focused model/controller tests covering lifecycle, cross-user denial, inaccessible account rejection, all-history resolution, rerun lineage, and completed-run immutability.
- [ ] Run the phase's focused tests, `bin/rubocop` on changed Ruby files, and update the implementation-notes subtitle before committing.

Phase acceptance: a user can create a scoped pending run and cannot inspect, mutate, clarify, or rerun another user's analysis. No LLM request occurs yet.

<!-- model: sonnet -->
## Phase 2 — Deterministic calculations and evidence snapshots

Allowed scope: `app/models/transaction_analysis/**`, supporting tests/fixtures, and surgical extraction from existing transaction query code only if sharing cannot be achieved without duplication. Do not change the generic assistant registry.

- [ ] Implement `TransactionAnalysis::Scope` to validate account IDs, resolve the explicit date range, record account labels, and produce a stable scope snapshot/data-version key.
- [ ] Implement `TransactionAnalysis::Calculator` operations for totals/counts/averages, category/merchant/account breakdowns, monthly trends, equal-period comparisons, and largest transactions.
- [ ] Normalize all results into calculation tokens with raw numeric values, currency, display values, dimensions, and optional chart-ready series. Preserve Sure's exchange-rate, pending, and transfer semantics.
- [ ] Implement an evidence collector that assigns opaque tokens, stores at most 25 safe snapshots, retains an optional internal transaction link, and emits no internal IDs to model-facing payloads.
- [ ] Add exhaustive calculator tests for permissions, empty scopes, mixed currency, pending rows, transfers, deleted source transactions, date boundaries, and deterministic repeatability.

Phase acceptance: every displayed number and evidence row can be produced without an LLM, and the model-facing payload contains only approved fields.

<!-- model: sonnet -->
## Phase 3 — Constrained provider orchestration

Allowed scope: transaction-analysis runner/functions/job, provider-facing adapters needed by this workflow, debug logging, and their tests. Do not add transaction/category/budget mutation tools.

- [ ] Implement read-only analysis functions for calculation, evidence selection, `request_clarification`, and `submit_analysis`; use strict bounded schemas and the existing provider function-call format.
- [ ] Implement `TransactionAnalysis::Runner` with a dedicated system prompt, a bounded tool loop, selected built-in provider resolution, and provider-independent conversation context from prior completed runs.
- [ ] Require a structured final submission containing narrative Markdown, calculation/evidence references, assumptions, and an optional constrained chart request. Reject unknown or mismatched references and retry correction once.
- [ ] Implement `TransactionAnalysisJob` state transitions, Turbo broadcasts, safe retries, timeout/error capture through `DebugLogEntry`, and clarification resume behavior.
- [ ] Add provider-mocked tests for OpenAI-compatible/Gemini and Anthropic response shapes, successful completion, clarification, follow-up inheritance, reruns, invalid references, tool limits, provider failures, and privacy filtering.

Phase acceptance: a queued run reaches completed, awaiting-clarification, or failed state; it cannot call a mutating function or complete with unverified references.

<!-- model: sonnet -->
## Phase 4 — Analysis workspace UI

Allowed scope: transaction-analysis controllers/helpers/components/views, navigation, locales, a dedicated Stimulus chart controller if required, and system/controller tests. Follow the repository's design-system hygiene rules.

- [ ] Add an Analyze navigation item and a responsive workspace with saved analyses, visible account/date/all-history controls, a free-text prompt area, and an AI-configuration empty state.
- [ ] Render run history as a scoped conversation showing prompt, scope badges, provider/model/timestamp, status, clarification form, assumptions, narrative conclusion, and verified calculation cards/table.
- [ ] Render linked evidence from server-side transaction IDs after rechecking access; retain the safe snapshot and show an unavailable state when the source transaction no longer exists.
- [ ] Add optional accessible line/bar charts from the server-generated chart spec, plus a table/text equivalent. Use `DS::*`, functional design tokens, `icon`, and translated user-facing strings.
- [ ] Add rename/delete, follow-up, clarification, and rerun interactions with Turbo and system tests for desktop/mobile behavior, pending states, evidence links, and version history.

Phase acceptance: the full workflow is usable without the generic chat screen, keyboard-accessible, privacy-mode compatible, and responsive.

<!-- model: sonnet -->
## Phase 5 — Security, regression verification, and documentation

Allowed scope: tests, documentation, lint-only fixes in changed files, and surgical fixes for review findings. No unrelated cleanup.

- [ ] Add golden workflow cases for spending growth, unusual purchases, and recurring-cost review; assert that verified calculations and evidence support each saved result.
- [ ] Run an adversarial privacy/access review covering forged account IDs, cross-user analysis IDs, deleted/hidden accounts, prompt injection in merchant/category labels, unsafe Markdown, and attempts to request writes.
- [ ] Run `bin/rails test`, `DISABLE_PARALLELIZATION=true bin/rails test:system`, `bin/rubocop`, `npm run lint`, targeted ERB linting, and `bin/brakeman --no-pager`; fix only failures caused by this branch.
- [ ] Update the AI hosting documentation with the analysis workflow, data sent to providers, default scope, retention/version behavior, supported providers, and operational failure states.
- [ ] Perform one live Gemini smoke run with synthetic or fixture data only, record exact evidence, and append the final implementation-complete decision-log item.

Phase acceptance: all required checks pass, the live synthetic-data smoke run succeeds, the independent final review has no unresolved high/medium findings, and the branch is ready for a fork PR without pushing or opening one.
