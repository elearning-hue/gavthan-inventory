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

- [TODO] Settle-status filter button beside Export in ledger header.
  Cycles All → Unsettled (red, shows count) → Settled (green). Filters
  entry list, resets pagination on change. Port filter logic + 3-state
  toggle UI.
- [TODO] Google Translate EN⇄Marathi toggle button (header, next to
  theme toggle). Web-only mechanism (googtrans cookie + reload) — DO NOT
  port the cookie approach. Android needs native i18n (strings.xml
  mr/en resource sets) instead. Flag for separate localization task.
- [SKIP] Google Translate banner suppression CSS — web-only artifact.

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

## Accessibility (port if android app shares web component patterns)

- [TODO] 44×44px minimum touch targets (icon buttons, settle/edit
  buttons) — verify android already meets platform minimum (48×48dp).
- [SKIP] Keyboard nav / focus-visible rings / ARIA labels — web-only,
  android uses native focus/TalkBack instead.

## Server-side (applies to BOTH apps — shared Supabase backend)

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
