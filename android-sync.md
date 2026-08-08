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
  schema + RPCs, drafted, NOT applied. Verify `mh_categories` column names
  and the `mh_customers.items` JSON keys before running.
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
