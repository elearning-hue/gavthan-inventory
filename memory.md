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
  (web→Capacitor change log), `supabase-rls.sql` (drafted, NOT applied).

### Known DB tables (as used by this app)
| Table | Purpose | Key columns seen |
|---|---|---|
| `mh_ledger` | cashbook | entry_type (income/expense), amount, category, note, entry_date, mode, source, ref, created_by, settled, reversed |
| `mh_inventory_items` | stock catalogue | name, category, unit, qty, reorder_level, cost_price, supplier_id, active, created_by |
| `mh_stock_moves` | stock audit trail | item_id, move_type (in/out/waste/adjust), qty, unit_cost, note, move_date, created_by |
| `mh_customers` | bills from billing app | status ("settled"), items (JSON), bill_no, name, phone, added_by, date, discount_on, discount_pct, adjustment_on, adjustment |
| `mh_users` | staff profiles | email, display_name, role (admin/staff), active |
| `mh_parties` | suppliers | id, name, type |

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

**Decisions still needed (blockers):**
1. Do bill line items carry a stable menu-item id, or only a name string?
   If name-only, `category_item_mappings` must key on normalized name, not
   `gavthan_item_id`. **Verify in billing app repo / DB before schema work.**
2. Where does the trigger run? Options: Postgres trigger/function on
   `mh_customers` update (best — atomic, works even if either client is
   closed), Supabase Edge Function, or client-side in billing app (worst —
   only fires if that app is open, and duplicates on retry).
   **Recommendation: DB-side trigger + function.**
3. Idempotency: a bill can be re-settled/edited. Deduction must not double
   apply. Needs unique constraint on (bill_id, item_id) in the deduction
   audit log, or a `synced_at` flag on the bill.
4. Does the billing app already deduct anything today? If yes, avoid double
   deduction.

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
- [ ] `supabase-rls.sql` policies (see A-P0-1).
- [ ] unique index `mh_ledger (source, ref) where ref is not null`.
- [ ] R1 mapping + deduction-audit tables (schema TBD, see blockers).

---

## ACTIONS TAKEN (newest first)

### 2026-07-08
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
