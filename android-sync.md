# android-sync.md

Web app (`index.html`, branch `spatial-ui-design`) changed independent of
Capacitor Android app. Log changes here needing port. Update per commit.

Format: `[STATUS] change - port note`
STATUS: TODO / DONE / SKIP (web-only, no android need)

---

## Design system

- [TODO] Spatial UI → flat minimal redesign (dark/light tokens, shadows,
  buttons, cards, sheets, tabs). Port CSS tokens + component styles to
  android app's theme/stylesheet equivalent.
- [TODO] SVG icon set replaces emoji (Lucide-style paths, `Icon` component).
  Port icon set to android drawables/vector assets.
- [TODO] Tabular-nums on money columns, 76px Dr/Cr column width (6-digit
  support), currency symbol removed from table cells only (kept on stat
  tiles/sheets). Port to android list/table row layout.
- [TODO] Header "Gavthan Manager" → "Gavthan". Port string change.
- [TODO] Header removed "Khata"/"Stock" prefix from subtitle
  ("Khata · Receivables & Payables" → "Receivables & Payables"; same for
  Inventory). Port string change.
- [TODO] Brand crest = favicon.svg (dark tile/ledger/coin icon), replaces
  green "G" circle on Login, boot screen, Ledger/Inventory header. Port
  icon asset + swap in android app bar / splash / login.
- [SKIP] favicon.svg / favicon.png browser-tab icon — web only.

## Features

- [TODO] **Flexible staff attribution — credit at payment time, not import.**
  Biggest behavioural change; port carefully. Web commit `8098160`.

  *Model.* Three fields on `mh_ledger`:
  - `created_by` — import/creation attribution. **Now nullable.**
  - `settled_by` — who actually collected the payment. Set at settle time.
  - `imported_by` — who ran the import. Pure audit, never credits anyone.

  Effective credit is `settled_by ?: created_by` (web helper `creditOf()`).
  Use it everywhere staff is displayed or filtered — staff filter, list-row
  subtitle, Net tile label, export. Do NOT read `created_by` directly for
  crediting any more.

  *Import.* Bulk and one-by-one both gain a "leave unassigned" option
  alongside "each bill's original staff" and the per-staff choices. Picking
  unassigned writes `created_by = null`. `imported_by` is stamped with the
  current user on every import regardless of the choice.

  *Payment.* Tapping the settle toggle from No → Yes must no longer settle
  silently. It opens a "Payment received" sheet with a staff picker
  (admin: any staff or leave unassigned; non-admin: locked to themselves —
  same gate the entry sheet already uses). Confirming writes
  `settled = true, settled_by = <chosen>`. Yes → No writes
  `settled = false, settled_by = null` — the receipt no longer stands, so
  the collector is cleared. No sheet needed for un-settling.

  *Reassign.* Entry detail sheet gets a "Credited to" dropdown (admin only;
  non-admin sees read-only text). Changing it writes `settled_by` alone —
  never touches `settled` or `created_by`. Below it, show the import
  attribution and collector as separate read-only lines.

  *Audit surfaces.* Row subtitle shows the effective credit, or "unassigned"
  when there is none, plus a small marker when `settled_by` differs from
  `created_by` (web uses "⇄"). Staff filter gains an "Unassigned" bucket
  matching rows with no effective credit. Export splits into four columns:
  Credited to / Created by / Collected by / Imported by.

  *Migration (shared DB — applies to both apps):*
  ```sql
  ALTER TABLE mh_ledger ADD COLUMN IF NOT EXISTS settled_by  TEXT;
  ALTER TABLE mh_ledger ADD COLUMN IF NOT EXISTS imported_by TEXT;
  ```
  Until these exist the settle write fails. Reads should treat missing as
  null so old rows keep crediting `created_by` exactly as before.

  *Test vectors (verified on web):*
  | scenario | created_by | settled_by | credited |
  |---|---|---|---|
  | import "original staff" | bill's staff | — | bill's staff |
  | import "unassigned" | null | — | unassigned |
  | unassigned, then collected by Raviraj | null | raviraj | raviraj |
  | imported to Nilesh, collected by Raviraj | nilesh | raviraj | **raviraj** |
  | that row, then un-settled | nilesh | null | nilesh |

  Last two rows are the point of the feature — filtering by Raviraj must
  show the handover row; filtering by Nilesh must not.

- [DONE] Reversal pairs excluded from totals + Partial settlement — ported
  FROM android (`web-changes-since-2.9.1.md`), web now matches. No port back
  needed. Needs `mh_ledger.partially_settled` column in DB.
- [TODO] Unsettled entries excluded from totals — **full spec in
  `settle-flag-spec.md`** (formulas, UI text, test vectors). Summary:
  `settled === false` rows no
  longer count toward Income / Expense / Net stat tiles or the cashflow
  chart — they are pending, not realized. Shown separately as
  "+X pending" under each tile, plus "N unsettled entries excluded" under
  Net. Rows with `settled` null/undefined (legacy/imported) still COUNT
  (predicate is `settled !== false`, not `settled === true`) — do not
  change this or historic rows vanish from totals. Port same predicate.
- [TODO] Settle-status filter button beside Export in ledger header.
  Cycles All → Unsettled (red, shows count) → Settled (green). Filters
  entry list, resets pagination on change. Port filter logic + 3-state
  toggle UI.
- [TODO] Google Translate EN⇄Marathi toggle button (header, next to
  theme toggle). Web-only mechanism (googtrans cookie + reload) — DO NOT
  port the cookie approach. Android needs native i18n (strings.xml
  mr/en resource sets) instead. Flag for separate localization task.
- [SKIP] Google Translate banner suppression CSS — web-only artifact.
- [TODO] Stock moves paginated 10/page with clickable page numbers (same
  pager as the ledger: Prev/Next, 5-button sliding window, page index
  clamped when the list shrinks). Card previously showed a hard-coded 6
  newest moves. Reaching the last page auto-fetches the next 300 by growing
  the fetch limit — grow the LIMIT, don't append to the loaded list, or a
  realtime refresh silently discards the older pages already paged into.
- [TODO] Ledger reconciliation now resolves differences instead of just
  reporting them. Per-bill drift (bill total vs what is actually posted) is
  computed and a Sync action rewrites that bill's ledger row to the current
  total. Sync is withheld when a bill has more than one ledger row
  (duplicate import — needs manual cleanup). Reversed bill entries are
  excluded from the imported total, and a "No longer on record" section
  lists bill-sourced rows whose bill was deleted or un-settled.
- [TODO] Removed `mh_parties` (supplier) dependencies — **already done on
  android**, see PR #6 on `inventory_android_app` (branch
  `claude/drop-mh-parties`). Not merged/compiled yet: needs a build before
  merge. Details + drop SQL in `drop-mh-parties.md`.

## Stock sync admin (web-only feature — port only if android needs the
## same admin surface; this whole screen didn't exist on android before)

- [TODO] **SCHEMA TRUTHS — verified against the live DB 2026-08-12. Do not
  re-derive these on android; all three cost a debugging cycle on web.**

  1. **Bill line items key the category as `cat`, NOT `category`.** Real row
     from bill #125:
     ```json
     { "id": "d4", "cat": "Cold Drinks", "qty": 1, "name": "सोडा", "price": 40,
       "times": ["2026-08-11T12:45:54.482Z"] }
     ```
     Reading `category` returns null for every line, which matches no armed
     category, so the bill silently deducts nothing AND disappears from the
     pending list (both counters read 0 at once — that is the signature of
     this bug, not of "nothing to do"). Web reads
     `coalesce(cat, category)` on both the SQL and client side.
     Other keys confirmed: `name`, `qty`, `price`, `id`, `times`.

  2. **`mh_customers.id` is TEXT, not uuid.** Values look like uuids
     (`74ffaa0b-d818-...`) but the column is text. Any RPC parameter or
     column holding a bill id must be text or Postgres fails with
     `42883: operator does not exist: text = uuid`.
     By contrast `mh_inventory_items.id` and `mh_stock_moves.id` really are
     uuid — confirmed by their foreign keys being accepted.

  3. **Category names themselves are fine.** `"Cold Drinks"` / `"Water
     Bottle"` on bills match `mh_stock_categories` exactly after
     normalising. Do not add fuzzy/plural matching — the mismatch that
     looked like a naming problem was actually truth 1 above.

- [TODO] **`mh_categories` real schema — read this before touching sync on
  android at all.** It is `(id text, list jsonb)`, NOT row-per-category. The
  billing app's entire category list sits inside one JSON column on what is
  effectively a single settings row. There is no `name` column, no per-row
  category, nothing to add a boolean flag to. Confirmed against the actual
  Postgres error (`42703: column cat.name does not exist`) and a direct
  `information_schema.columns` query — don't re-guess this.
  - Category list must be read by flattening `list`: handle array-of-strings,
    array-of-objects (look for a `name`/`title`/`label`-ish key), an
    object keyed by category name, and the case where `list` is JSON stored
    as a string rather than native jsonb.
  - Which categories currently deduct stock is tracked in a SEPARATE table,
    `mh_stock_categories (name_norm text primary key)` — one row per armed
    category, keyed by the same normalized-name function used everywhere
    else (`lowercase, trim, collapse whitespace`). Arming/disarming = insert/
    delete a row. This table is the source of truth for the sync RPC, not
    `mh_categories`.
- [TODO] Dynamic category toggle UI — list every category found in
  `mh_categories.list`, each with Turn on/off + "deducting stock" /
  "not deducting" status, backed by `mh_stock_categories` above. An armed
  category whose name no longer appears in the flattened list (renamed or
  removed upstream) must stay visible and toggleable, or it keeps deducting
  with no way to turn it off.
- [TODO] Proactive item-mapping UI (menu item → inventory item + ratio),
  addable before anything sells unmapped, not just from the reactive
  unmapped-items queue. No menu table exists in this schema — menu names are
  derived from distinct item names found in settled bills' `items` JSON.
  Saving a mapping should replay any bills already waiting on that name.
- [TODO] Bills with nothing to deduct must not sit in "pending" forever. A
  settled bill whose every line is in a non-deducting category never
  produces a sync-log row, so a naive "settled bills with no log row" query
  lists it permanently while there is nothing to apply. Filter it out (or on
  android's own data model, the equivalent condition) both client-side and
  in whatever query defines the pending set.
  **But guard the empty case:** if no category is armed at all, that filter
  classifies *every* bill as inert and the list renders empty exactly when
  the operator still has to arm one. Web treats an empty armed set as
  "nothing can be judged inert" and shows everything, with a banner pointing
  at the Categories tab. Same trap will exist on android.
- [TODO] When fetching bill lines to decide what is actionable, do not use an
  unordered `limit(n)`. PostgREST returns arbitrary rows, so a bill settled
  today can fall outside the sample and be misjudged. Web orders newest-first
  and additionally fetches the pending bill ids explicitly.
- [TODO] Surface the exact category strings found on real bills next to the
  armed list. Without it, a category that never matches is invisible — the
  UI just shows nothing pending and gives no clue why.
- [TODO] Stock-move Excel export button, mirrors the ledger export (.xlsx,
  CSV fallback): date, item, category, movement type, qty, unit, unit cost,
  computed value, note, recorded-by.

## Bug fixes (P0, port to android if same data-layer bug exists)

- [TODO] Supplier-ledger purchase was posted as `entry_type:"credit"`,
  cashbook counted it as income (inflated Income/Net by 2x purchase
  amount). Fixed to `entry_type:"expense"` + category "Supplies /
  Purchase". Check android app's MoveSheet/stock-purchase equivalent for
  same bug.
- [TODO] Dates used `toISOString()` (UTC) — late-night IST entries
  (00:00–05:30) filed to previous day/previous month. Fixed via
  `localISO()` helper (local calendar date, not UTC). Check android
  app's date-of-entry logic for same bug — likely present if it also
  uses `Date.toISOString()` for "today".
- [TODO] Realtime refresh (`load()`) was unmounting open sheets
  (EntrySheet/MoveSheet/ItemSheet) on ANY realtime event, wiping
  in-progress user input. Fixed: full-screen loading spinner now only
  shows on first load (`loadedOnce` ref), not on background refreshes.
  Port same guard if android app has an equivalent "refresh wipes open
  form" bug from its data-sync/observer layer.
- [SKIP] Google Translate causing blank page on filter click (React
  removeChild/insertBefore DOM patch) — web-only, Translate not present
  on android.
- [TODO] Reversed bill entries were still counted as imported sales, so
  deleting a settled bill and reversing its ledger entry left "On record"
  and "Imported" permanently apart by that amount (the reported ₹600 case:
  bill #95 deleted + reversed). Fixed by excluding rows with
  `reversed = true` from the imported-sales total, the per-bill posted
  amount and the per-bill row count. Check the android reconciliation for
  the same bug.

## Accessibility (port if android app shares web component patterns)

- [TODO] 44×44px minimum touch targets (icon buttons, settle/edit
  buttons) — verify android already meets platform minimum (48×48dp).
- [SKIP] Keyboard nav / focus-visible rings / ARIA labels — web-only,
  android uses native focus/TalkBack instead.

## Server-side (applies to BOTH apps — shared Supabase backend)

- [TODO] **Pending column migrations.** None of these are applied yet. Both
  clients degrade rather than crash if a column is missing (treat null as
  false / absent), except `settled_by`, whose absence makes the settle write
  fail outright.
  ```sql
  ALTER TABLE mh_ledger ADD COLUMN IF NOT EXISTS reversed          BOOLEAN NOT NULL DEFAULT FALSE;
  ALTER TABLE mh_ledger ADD COLUMN IF NOT EXISTS partially_settled BOOLEAN NOT NULL DEFAULT FALSE;
  ALTER TABLE mh_ledger ADD COLUMN IF NOT EXISTS settled_by        TEXT;
  ALTER TABLE mh_ledger ADD COLUMN IF NOT EXISTS imported_by       TEXT;
  ```
- [TODO] `supabase-stock-sync.sql` (repo root) — R1 cross-app stock sync
  schema + RPCs, drafted, NOT applied, but now runnable end-to-end (no
  placeholders left). Creates `mh_stock_categories` itself with
  `CREATE TABLE IF NOT EXISTS` and seeds 4 names — **if PR #16's admin
  screen already created that table with a different shape on this DB,
  reconcile before running, don't just execute blind.** `mh_categories`
  column assumption has been corrected (see the Stock sync admin section
  above) — no longer needs verification, it's confirmed `(id text, list
  jsonb)`. Still verify `mh_customers.items` JSON keys (`name`, `qty`,
  `category`) before running.
- [TODO] `supabase-rls.sql` (repo root) — Row Level Security policies
  drafted for finding: client-side-only authorization (any user can
  forge `created_by`, run admin actions via API directly, deactivated
  users keep write access). NOT YET APPLIED to Supabase. Must run before
  launch — protects both web and android clients since RLS is DB-level,
  not per-app. Review column names against real schema before running.

---

## Open items requiring android-side decision

1. Marathi translation on android — cookie-based GT trick doesn't apply.
   Needs native resource-based i18n or a different runtime-translation
   approach for Capacitor (e.g. i18next).
2. RLS policies untested against android app's actual query patterns —
   verify android's Supabase calls don't rely on any permissive-write
   behavior these policies would now block.

## Foreign keys — ON DELETE actions (shared DB, affects android too)

- [TODO] `mh_stock_sync_log` FKs must not pin down the rows they reference.
  Created without an ON DELETE action, Postgres defaults to NO ACTION, and
  `mh_stock_sync_log.move_id -> mh_stock_moves(id)` then blocks **every**
  delete from `mh_stock_moves`:
  ```
  ERROR: 23503: update or delete on table "mh_stock_moves" violates
         foreign key constraint on table "mh_stock_sync_log"
  ```
  The log is an audit trail — it must outlive what it points at. Correct
  actions, now in `supabase-stock-sync.sql` plus a lookup-based repair block
  for databases where the constraints already exist:
  | constraint | action | why |
  |---|---|---|
  | `mh_stock_sync_log.move_id -> mh_stock_moves` | `ON DELETE SET NULL` | keep the audit row, drop the pointer |
  | `mh_stock_sync_log.inventory_item_id -> mh_inventory_items` | `ON DELETE SET NULL` | same |
  | `mh_item_map.inventory_item_id -> mh_inventory_items` | `ON DELETE CASCADE` | column is NOT NULL; a mapping is meaningless without its item |

  Android side: nothing to code, but if it ever deletes stock moves or
  inventory items it will hit the same 23503 until the repair block is run.
