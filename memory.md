# memory.md — project working log

Single running log for this repo: requirements, enhancements, TODOs, actions
taken, decisions, open questions.

**Protocol:** read this file at the START of every conversation. Update it at
the END, in the same commit as the code change. Newest activity at the top of
each section.

---

## Repo facts (stable context)

- This repo = **Inventory + Ledger app** (`gavthan_inventory`), single file
  `index.html`. React 18 UMD + htm, no build step. Deployed GitHub Pages +
  Vercel (`gavthan-inventory.vercel.app`).
- Separate repo = **Gavthan billing app** (order taking, bill settlement).
  Not in this workspace.
- **Both apps share ONE Supabase database.**
- Working branch: `spatial-ui-design`. Main branch: `main`.
- Companion docs: `inn.md` (UI spec for Android port), `android-sync.md`
  (web→Capacitor change log), `settle-flag-spec.md` (settled-only totals,
  functional spec + test vectors), `supabase-rls.sql` (drafted, NOT applied),
  `supabase-stock-sync.sql` (R1 draft, NOT applied).

### Known DB tables (as used by this app)
| Table | Purpose | Key columns seen |
|---|---|---|
| `mh_ledger` | cashbook | entry_type (income/expense), amount, category, note, entry_date, mode, source, ref, created_by, settled, reversed |
| `mh_inventory_items` | stock catalogue | name, category, unit, qty, reorder_level, cost_price, supplier_id, active, created_by |
| `mh_stock_moves` | stock audit trail | item_id, move_type (in/out/waste/adjust), qty, unit_cost, note, move_date, created_by |
| `mh_customers` | bills from billing app | status ("settled"), items (JSON), bill_no, name, phone, added_by, date, discount_on, discount_pct, adjustment_on, adjustment |
| `mh_users` | staff profiles | email, display_name, role (admin/staff), active |
| ~~`mh_parties`~~ | suppliers — **being dropped**, web refs removed 2026-07-08, android still TODO (see `drop-mh-parties.md`) | id, name, type |

Bill settled test: `status === "settled"`.
Bill line items: `mh_customers.items` is a **JSON array/string**, elements
have `price` and `qty`. No stable menu-item id confirmed from this repo.

---

## OPEN REQUIREMENTS

### R1 — Cross-app real-time inventory sync + item mapping  `[NEW, not started]`
Auto-deduct stock in Inventory app when a bill is settled in Gavthan billing
app.

**Cutoff date: `2026-07-08`.** Orders on/after cutoff trigger movement.
Orders before cutoff are historical — never retro-trigger.

- Trigger: bill settlement in billing app (`mh_customers.status -> "settled"`).
- Target categories only: **Starter, Cold Drinks, Water, Cigarette**.
- Action: write an outgoing `mh_stock_moves` row (`move_type:"out"`) and
  decrement `mh_inventory_items.qty`.
- Mapping: link billing menu item -> inventory stock item
  (e.g. "Aquafina 1L" -> "Water Bottle 1L"), with conversion ratio
  (e.g. 1 pack = 20 units).
- Proposed table: `category_item_mappings` (gavthan_item_id ->
  inventory_item_id + ratio).
- Unmapped item must NOT fail silently — needs confirmation/fallback prompt
  or a pending-mapping queue surfaced in UI.
- Audit: tie every deduction to the settled `order_id`/bill id for
  reconciliation.

**DECIDED 2026-07-08 — architecture: billing app initiates, DB executes.**
Not a pure DB trigger, not raw client writes. Split:
- Billing app, on settle: resolve bill lines via mapping table; if an item in
  a target category is unmapped, **prompt the user** (map now / skip once);
  then call ONE Postgres RPC with bill_id + resolved lines.
- RPC does everything in a single transaction: insert `mh_stock_moves` rows,
  decrement `qty` atomically (`qty = qty - x` — never client read-then-write),
  insert deduction-audit row keyed to bill_id.
- Unique constraint on (bill_id, item_id) in the audit table = re-settle or
  double-tap cannot double-deduct.

Rationale: a pure DB trigger cannot prompt a human, so on an unmapped item it
must either skip silently (inventory drifts — the exact failure requirement 2
forbids) or raise and block bill settlement (unacceptable at service time).
The user is present at settle, so that is the right moment to ask. But raw
client-side table writes would repeat this repo's existing A-P0-2 lost-update
race and A-P1-1 partial-write drift, hence the single atomic RPC.

**Safety net:** bills settled outside that path (direct DB edit, a future
client) deduct nothing. Add a reconcile view listing settled bills with no
deduction record — reuse the existing "Reconcile bills" pattern already used
for ledger sales import.

**Blockers RESOLVED 2026-07-08 (answers from user):**
1. Bill lines carry **menu names only** — no stable menu item id. Mapping
   keys on normalized name (`mh_norm`: lowercase, trim, collapse whitespace).
2. A bill **never** holds the same menu item as two separate lines.
3. Billing app **does not touch stock** today — no double-deduction risk.
4. **Always read categories from `mh_categories`** — never hardcode names.
   Implemented as a `deducts_stock boolean` flag on that table, so the
   "Cold Drinks" vs "Cold Drink" string problem disappears permanently.

**Design catch:** two different menu names can map to the SAME inventory item
("Aquafina 1L" and "Bisleri 1L" -> "Water Bottle 1L"), so one bill can hit one
inventory item twice. Idempotency key is therefore
**(bill_id, menu_name_norm)**, NOT (bill_id, inventory_item_id) — the latter
would wrongly reject the second legitimate line.

**Schema + RPC drafted:** `supabase-stock-sync.sql` (NOT applied yet).
Contains: `mh_categories.deducts_stock` flag, `mh_item_map` (menu name ->
inventory item + `qty_per_unit` ratio), `mh_stock_sync_log` (audit, unique on
bill+menu name), `mh_preview_bill_stock(bill_id)` (read-only resolve, drives
the unmapped prompt), `mh_apply_bill_stock(bill_id)` (atomic + idempotent
apply, cutoff 2026-07-08 enforced inside, `qty = qty - x` decrement),
`mh_stock_sync_pending` view (settled bills that never synced), plus RLS.

**Still to verify before running:** actual column names of `mh_categories`
(assumed `id`, `name`) and that `mh_customers.items` elements expose `name`,
`qty`, and `category` keys.

**Hard constraint — do NOT reuse the current client-side stock update
pattern.** Existing `MoveSheet` does a read-modify-write on `qty` from a
stale snapshot (known P0 lost-update race, logged below as A-P0-1). The sync
must use an atomic DB-side increment (`qty = qty - x`) inside a transaction,
or derive qty from the sum of `mh_stock_moves`.

---

## TODO BACKLOG (from pre-launch audit, not yet done)

| id | Sev | Item |
|---|---|---|
| A-P0-1 | Critical | Apply `supabase-rls.sql`. All authorization is currently client-side only — any signed-in user can forge `created_by`, run admin-only imports, or delete rows via the API. Deactivated users keep write access. **Launch blocker.** |
| A-P0-2 | Critical | Stock qty update is a client read-modify-write from a stale snapshot -> lost updates when 2 staff move the same item. Needs atomic DB increment. |
| A-P1-1 | High | `MoveSheet` 3 writes are non-atomic (move insert -> qty update -> ledger insert). Partial failure corrupts; retry double-applies. |
| A-P1-2 | High | Sales-bill import dedupe is client-side only. Add unique index on `mh_ledger (source, ref)`. |
| A-P1-3 | High | Excel import inserts in batches of 200 with no rollback; partial failure leaves partial import, retry duplicates. |
| A-P1-4 | High | "Set to" (adjust) accepts blank/negative qty -> silently zeroes or negatives stock. |
| A-P1-5 | High | `mh_users` fetch error silently demotes admin to staff (reads `data`, ignores `error`). |
| A-P1-6 | High | Sheet scrim/Escape dismiss during an in-flight save abandons the write with no warning. |
| A-P1-7 | High | Bump `xlsx@0.18.5` (prototype-pollution + ReDoS CVEs) to >= 0.20.2. |
| A-P2-x | Medium | `num()` turns "1,000" into 0; `parseDate` rolls over invalid dates; Excel "user" column regex matches customer Name; negative stock allowed; settle double-tap race; float equality in reconcile; silent realtime disconnect; blank date -> raw Postgres error; huge amounts overflow columns. |

### DB migrations pending
- [ ] `mh_ledger.reversed boolean default false` — **required** by the
      shipped Reversal Entry feature. If missing, the reverse action's flag
      update silently no-ops and an entry can be reversed twice.
      ```sql
      ALTER TABLE mh_ledger ADD COLUMN IF NOT EXISTS reversed BOOLEAN NOT NULL DEFAULT FALSE;
      ```
- [ ] `mh_ledger.partially_settled boolean default false` — **required** by
      the shipped Partial Settlement feature. Without it the split still works
      and totals stay correct, but the "already split" guard doesn't persist,
      so the Partial payment action stays offered on an entry already split.
      ```sql
      ALTER TABLE mh_ledger ADD COLUMN IF NOT EXISTS partially_settled BOOLEAN NOT NULL DEFAULT FALSE;
      ```
- [ ] `supabase-rls.sql` policies (see A-P0-1).
- [ ] unique index `mh_ledger (source, ref) where ref is not null`.
- [ ] R1 mapping + deduction-audit tables (schema TBD, see blockers).

---

## ACTIONS TAKEN (newest first)

### 2026-07-08
- **Stock moves paginated 10/page** with the ledger's exact pager (clickable
  numbers, 5-button window, safePage clamp). Card was a hard-coded
  `slice(0,6)`. Reaching the last page now auto-fetches the next 300 by
  growing the fetch limit — kept as a limit rather than appending, so a
  realtime refresh re-reads the same window instead of discarding the older
  pages the user paged into. Verified no fetch loop: settles once the server
  returns fewer rows than the limit.
- **Removed all `mh_parties` (supplier) dependencies from the web app** ahead
  of dropping the table: suppliers state + query, the supplier dropdown on
  ItemSheet, and the "also add to supplier's ledger" checkbox + ledger post on
  MoveSheet. Zero `mh_parties|supplier|party_id` matches left in `index.html`.
  **Feature loss:** nothing auto-posts a stock purchase into the cashbook
  anymore — purchases update stock only, the money side is manual. Can be
  re-added supplier-free if wanted.
  **Android side also done** — branch `claude/drop-mh-parties`,
  PR https://github.com/elearning-hue/inventory_android_app/pull/6 (8 files,
  not compiled — no Android SDK here, needs a build before merge).
  Full site list + drop SQL in `drop-mh-parties.md`. GitHub code-search API
  reports 0 hits on that private repo (not indexed) — clone and grep, don't
  trust the search API.
- **Ported two Android ledger changes** (source: android repo
  `inventory_android_app`, branch `claude/great-sanderson-23abf1`, file
  `web-changes-since-2.9.1.md`):
  1. **Reversal pairs excluded from totals.** New `countsEntry(e)` predicate
     (`!e.reversed && e.source!=="reversal"`) applied everywhere
     `isSettledEntry` already was — income, expense, pending sums,
     unsettledCount, chartBase. Fixes gross tiles: a reversed 1000 sale used
     to read as income 1000 + expense 1000; now neither side counts. Net was
     always right — the bug was the gross figures.
  2. **Partial settlement.** On a settled income entry, "Partial payment"
     records cash received and splits the shortfall into an unsettled income
     row (the receivable, excluded from totals so it shows as pending) plus a
     settled expense row of the same amount (keeps Dr/Cr balanced). Original
     untouched, flagged `partially_settled`. Both new rows carry the
     ORIGINAL entry's date, not today — else splitting an old bill scatters
     the pair into the current period and Dr/Cr looks unbalanced under a date
     filter. Balancing row's settle toggle is locked (generated, not entered)
     but NOT dimmed, since it still counts fully toward Expense.
     Known tradeoff carried over from Android: the balancing expense inflates
     the standalone Expense tile (it's contra-revenue, not a real cost). Net
     and Dr/Cr stay correct.
  Verified against the spec's test vectors: `income == 1250` (not 2250,
  proving reversal exclusion), partial 1000-bill/600-paid gives
  income 1000 / expense 400 / net 600 / pending 400, and after settling the
  rest income 1400 / net 1000.
- **`settle-flag-spec.md` written** — functional spec for the settled-only
  totals rule so the Android app can implement it identically. Includes the
  `settled != false` predicate rationale (null/legacy rows must keep
  counting), formulas, UI strings, what deliberately does NOT change, and a
  5-row test vector whose key assertion is `income == 1250`.
- **R1 schema + RPC drafted** in `supabase-stock-sync.sql` after user resolved
  all four blockers (menu names only, no duplicate lines, billing app doesn't
  touch stock, categories come from `mh_categories`). Not applied yet.
- **R1 architecture decided:** billing app initiates on settle (resolves
  mappings, prompts on unmapped items), then calls one atomic Postgres RPC
  that inserts the stock moves, decrements qty, and writes a deduction audit
  row. Rejected pure DB trigger (cannot prompt a human; would either drift
  silently or block settlement) and rejected raw client-side table writes
  (repeats the A-P0-2 lost-update race). See R1 above.
- Created this `memory.md`. Logged R1 cross-app inventory sync request.
- **Unsettled entries excluded from totals.** `settled === false` no longer
  counts toward Income/Expense/Net or the cashflow chart; pending amounts
  shown separately. Predicate `settled !== false` so legacy/null rows still
  count. (`c7ca553`)
- **Ledger Reversal Entry.** No delete; tapping a row opens a detail sheet
  with "Reversal entry" which posts an equal opposing entry
  (`source:"reversal"`, `ref:<original id>`) and flags the original
  `reversed:true`. Reversals and already-reversed rows can't be re-reversed.
  Needs the `reversed` column. (`f0302ad`)
- `android-sync.md` created — tracks which web changes need porting to the
  Capacitor Android app. (`a64bf70`)
- Google Translate top banner killed (modern GT injects a bare
  `iframe.skiptranslate` under body). (`2c666a9`, `f692f19`)
- Header "Gavthan Manager" -> "Gavthan"; language dropdown replaced by a
  single EN/Marathi toggle button driven by the `googtrans` cookie.
  (`3e497e8`)

### 2026-07-07 and earlier
- **Top-3 audit P0 fixes** (`3fdce64`): realtime refresh no longer unmounts
  open sheets and wipes typed input; supplier purchase posts as `expense`
  not `credit` (was counted as income); dates use local calendar via
  `localISO()` not UTC (late-night IST entries were filing to the previous
  day/month). Also added `supabase-rls.sql`.
- Fixed blank page when using filters with Google Translate active
  (patched `Node.removeChild`/`insertBefore`). (`d12511e`)
- Favicon/crest branding, Marathi widget, Dr/Cr columns widened to 76px for
  6-digit figures, rupee symbol removed from table cells only. (`96a8ddf`)
- Modern minimal UI refresh, settle-status filter, login cleanup.
  (`8f1aac4`)
- Accessibility pass: keyboard nav, focus rings, SVG icons replacing emoji,
  tabular figures, 44px touch targets. (`68acbb0`)

---

## OPEN QUESTIONS FOR USER
1. R1 blockers 1–4 above — especially: do bill line items have a stable menu
   item id, and does the billing app already touch stock today?
2. Has the `reversed` column been added to `mh_ledger` yet?
3. Has `supabase-rls.sql` been reviewed/applied? Still the top launch
   blocker.
