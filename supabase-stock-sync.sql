-- ============================================================================
--  R1 — Cross-app inventory sync on bill settlement
--
--  Architecture (decided 2026-07-08, see memory.md):
--    Billing app INITIATES on settle -> calls mh_apply_bill_stock(bill_id).
--    This RPC EXECUTES atomically: inserts stock moves, decrements qty,
--    writes an audit row. Client never writes mh_inventory_items directly.
--
--  Confirmed inputs (2026-07-08):
--    * Bill lines carry MENU NAMES only (no stable menu item id) -> map on name.
--    * A bill never holds the same menu item as two separate lines.
--    * Billing app does NOT currently touch stock -> no double-deduction risk.
--    * Category source of truth = mh_categories (never hardcode names).
--
--  VERIFIED 2026-07-09: mh_categories is (id text, list jsonb) — the whole
--  category list sits inside one JSON column, so it is a pick-list source only.
--  The armed set lives in mh_stock_categories (created below).
--  Adjust the ALTER + joins below if the real shape differs.
--
--  REVIEW EVERY TABLE/COLUMN NAME AGAINST THE LIVE SCHEMA BEFORE RUNNING.
--  Run in a transaction on a staging copy first.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. REPAIR — only needed if an earlier version of this file was already run.
--    That version declared bill ids as uuid, which is wrong: mh_customers.id
--    is TEXT here, so every "c.id = p_bill_id" raised
--      ERROR: 42883: operator does not exist: text = uuid
--    Postgres will not change a function's parameter type via CREATE OR
--    REPLACE, so the old uuid-signature functions must be dropped first or
--    both signatures end up defined and calls stay ambiguous.
--    Safe to run on a clean database too — all three are IF EXISTS.
-- ---------------------------------------------------------------------------
drop function if exists public.mh_apply_bill_stock(uuid);
drop function if exists public.mh_preview_bill_stock(uuid);

do $$
begin
  if exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='mh_stock_sync_log'
       and column_name='bill_id' and data_type='uuid'
  ) then
    alter table public.mh_stock_sync_log alter column bill_id type text using bill_id::text;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Which categories deduct stock.
--
--    NOTE: mh_categories cannot hold this flag. It is not a row-per-category
--    table — its shape is (id text, list jsonb), i.e. the billing app stores
--    the entire category list inside one JSON column. There is no per-category
--    row to add a boolean to.
--
--    So the armed set lives in its own table, keyed by normalised name. The
--    admin screen writes it; mh_categories stays read-only to this app and is
--    used only to populate the pick-list.
-- ---------------------------------------------------------------------------
create table if not exists public.mh_stock_categories (
  name_norm  text primary key,
  created_at timestamptz not null default now()
);

-- Arm the initial four. Safe to re-run.
insert into public.mh_stock_categories(name_norm)
values ('starter'), ('cold drinks'), ('water bottle'), ('cigarette')
on conflict (name_norm) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Name normalization helper — one definition used by both the mapping
--    table and the lookup, so they can never disagree.
-- ---------------------------------------------------------------------------
create or replace function public.mh_norm(txt text)
  returns text language sql immutable
  as $$ select nullif(regexp_replace(lower(trim(coalesce(txt,''))), '\s+', ' ', 'g'), '') $$;

-- ---------------------------------------------------------------------------
-- 3. Menu item -> inventory item mapping (+ conversion ratio)
--    e.g. menu "Aquafina 1L" -> inventory "Water Bottle 1L", qty_per_unit 1
--         menu "Cigarette pack" -> inventory "Cigarette", qty_per_unit 20
--    Two different menu names MAY map to the same inventory item.
-- ---------------------------------------------------------------------------
create table if not exists public.mh_item_map (
  id                bigserial primary key,
  menu_name         text        not null,
  menu_name_norm    text        generated always as (public.mh_norm(menu_name)) stored,
  inventory_item_id uuid        not null references public.mh_inventory_items(id),
  qty_per_unit      numeric     not null default 1 check (qty_per_unit > 0),
  active            boolean     not null default true,
  created_by        text,
  created_at        timestamptz not null default now()
);

-- One active mapping per menu name.
create unique index if not exists mh_item_map_name_uniq
  on public.mh_item_map (menu_name_norm) where active;

-- ---------------------------------------------------------------------------
-- 4. Deduction audit log — one row per bill line actually deducted.
--    Idempotency key is (bill_id, menu_name_norm): a bill never repeats a menu
--    item, and this still allows two menu names on one bill to hit the SAME
--    inventory item (which a (bill_id, inventory_item_id) key would wrongly
--    reject).
-- ---------------------------------------------------------------------------
create table if not exists public.mh_stock_sync_log (
  id                bigserial primary key,
  -- mh_customers.id is TEXT in this schema, not uuid. Declaring this uuid makes
  -- every "c.id = p_bill_id" comparison fail with 42883 (text = uuid).
  bill_id           text        not null,
  menu_name         text        not null,
  menu_name_norm    text        not null,
  inventory_item_id uuid        references public.mh_inventory_items(id),
  bill_qty          numeric     not null,
  qty_deducted      numeric     not null,
  move_id           uuid        references public.mh_stock_moves(id),
  status            text        not null,   -- 'applied' | 'unmapped'
  created_at        timestamptz not null default now()
);

create unique index if not exists mh_stock_sync_log_bill_item_uniq
  on public.mh_stock_sync_log (bill_id, menu_name_norm);

create index if not exists mh_stock_sync_log_bill_idx
  on public.mh_stock_sync_log (bill_id);

-- ---------------------------------------------------------------------------
-- 5. Resolve a bill's lines against the mapping.
--    Returns every line in a deducting category, mapped or not, so the client
--    can prompt the user about unmapped items BEFORE applying.
--    Read-only: safe to call as often as the UI likes.
-- ---------------------------------------------------------------------------
create or replace function public.mh_preview_bill_stock(p_bill_id text)
returns table (
  menu_name          text,
  category           text,
  bill_qty           numeric,
  inventory_item_id  uuid,
  inventory_name     text,
  qty_per_unit       numeric,
  qty_to_deduct      numeric,
  already_applied    boolean,
  is_mapped          boolean
)
language sql stable security definer set search_path = public
as $$
  with lines as (
    select
      nullif(trim(li ->> 'name'), '')          as menu_name,
      -- The billing app writes the category under "cat". "category" is kept as
      -- a fallback only; reading the wrong key yields NULL, which silently
      -- matches no armed category and makes the whole bill look like it has
      -- nothing to deduct.
      nullif(trim(coalesce(li ->> 'cat', li ->> 'category')), '') as category,
      coalesce((li ->> 'qty')::numeric, 0)     as bill_qty
    from public.mh_customers c
    cross join lateral jsonb_array_elements(
      case jsonb_typeof(c.items::jsonb)
        when 'array' then c.items::jsonb
        else '[]'::jsonb
      end
    ) as li
    where c.id = p_bill_id
  )
  select
    l.menu_name,
    l.category,
    l.bill_qty,
    m.inventory_item_id,
    ii.name                                    as inventory_name,
    m.qty_per_unit,
    round(l.bill_qty * coalesce(m.qty_per_unit, 0), 3) as qty_to_deduct,
    (sl.id is not null)                        as already_applied,
    (m.id is not null)                         as is_mapped
  from lines l
  -- only categories the admin screen has armed
  join public.mh_stock_categories cat
    on cat.name_norm = public.mh_norm(l.category)
  left join public.mh_item_map m
    on m.menu_name_norm = public.mh_norm(l.menu_name)
   and m.active
  left join public.mh_inventory_items ii
    on ii.id = m.inventory_item_id
  left join public.mh_stock_sync_log sl
    on sl.bill_id = p_bill_id
   and sl.menu_name_norm = public.mh_norm(l.menu_name)
  where l.menu_name is not null
    and l.bill_qty > 0;
$$;

-- ---------------------------------------------------------------------------
-- 6. Apply the deduction. ATOMIC + IDEMPOTENT.
--
--    * Skips bills dated before the cutoff (historical orders untouched).
--    * Skips bills that are not settled.
--    * Decrements with `qty = qty - x` — never a client read-then-write, so
--      two terminals settling at once cannot lose an update.
--    * The unique index on (bill_id, menu_name_norm) means a re-settle,
--      double-tap, or retry cannot double-deduct: the second attempt hits
--      ON CONFLICT DO NOTHING and applies nothing.
--    * Unmapped lines are recorded with status 'unmapped' and NOT deducted,
--      so nothing fails silently — they show up in the reconcile view.
-- ---------------------------------------------------------------------------
create or replace function public.mh_apply_bill_stock(p_bill_id text)
returns table (applied integer, unmapped integer, skipped_reason text)
language plpgsql security definer set search_path = public
as $$
declare
  -- Cutoff: orders on/after this date sync. Earlier bills are historical.
  c_cutoff   constant date := date '2026-07-08';
  v_bill     public.mh_customers%rowtype;
  v_date     date;
  v_actor    text := coalesce(auth.jwt() ->> 'email', 'system');
  r          record;
  v_move_id  uuid;
  v_applied  integer := 0;
  v_unmapped integer := 0;
begin
  select * into v_bill from public.mh_customers where id = p_bill_id;
  if not found then
    return query select 0, 0, 'bill not found'::text; return;
  end if;

  if coalesce(v_bill.status,'') <> 'settled' then
    return query select 0, 0, 'bill not settled'::text; return;
  end if;

  v_date := coalesce(v_bill.date::date, v_bill.created_at::date);
  if v_date < c_cutoff then
    return query select 0, 0, 'before cutoff'::text; return;
  end if;

  for r in select * from public.mh_preview_bill_stock(p_bill_id) loop
    -- already handled on a previous call -> skip entirely (idempotent)
    continue when r.already_applied;

    if not r.is_mapped then
      insert into public.mh_stock_sync_log
        (bill_id, menu_name, menu_name_norm, inventory_item_id,
         bill_qty, qty_deducted, move_id, status)
      values
        (p_bill_id, r.menu_name, public.mh_norm(r.menu_name), null,
         r.bill_qty, 0, null, 'unmapped')
      on conflict (bill_id, menu_name_norm) do nothing;
      v_unmapped := v_unmapped + 1;
      continue;
    end if;

    insert into public.mh_stock_moves
      (item_id, move_type, qty, note, move_date, created_by)
    values
      (r.inventory_item_id, 'out', r.qty_to_deduct,
       'Auto: bill ' || coalesce(v_bill.bill_no::text, p_bill_id::text)
         || ' — ' || r.menu_name,
       v_date, v_actor)
    returning id into v_move_id;

    -- atomic decrement, no read-modify-write
    update public.mh_inventory_items
       set qty        = coalesce(qty,0) - r.qty_to_deduct,
           updated_at = now()
     where id = r.inventory_item_id;

    insert into public.mh_stock_sync_log
      (bill_id, menu_name, menu_name_norm, inventory_item_id,
       bill_qty, qty_deducted, move_id, status)
    values
      (p_bill_id, r.menu_name, public.mh_norm(r.menu_name), r.inventory_item_id,
       r.bill_qty, r.qty_to_deduct, v_move_id, 'applied')
    on conflict (bill_id, menu_name_norm) do nothing;

    v_applied := v_applied + 1;
  end loop;

  return query select v_applied, v_unmapped, null::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Safety net — settled bills at/after cutoff that never synced.
--    Catches bills settled outside the app path (direct DB edit, other client,
--    app closed mid-settle). Surface this in the Inventory app the same way
--    "Reconcile bills" already works for ledger sales import.
-- ---------------------------------------------------------------------------
--    A bill only belongs here if it actually HAS a line in a stock-deducting
--    category. Without that test, a bill of purely non-deducting items (say a
--    food-only bill when only drinks deduct) has nothing to log, so it never
--    gets a row in mh_stock_sync_log and sits in this view for ever while
--    "Apply" does nothing — the bill #117 case.
create or replace view public.mh_stock_sync_pending as
select c.id            as bill_id,
       c.bill_no,
       c.name          as customer,
       c.date,
       c.status
  from public.mh_customers c
 where c.status = 'settled'
   and coalesce(c.date::date, c.created_at::date) >= date '2026-07-08'
   and not exists (select 1 from public.mh_stock_sync_log l where l.bill_id = c.id)
   and exists (
     select 1
       from jsonb_array_elements(
              case jsonb_typeof(c.items::jsonb) when 'array' then c.items::jsonb else '[]'::jsonb end
            ) as li
       join public.mh_stock_categories cat
         on cat.name_norm = public.mh_norm(coalesce(li ->> 'cat', li ->> 'category'))
   );

-- ---------------------------------------------------------------------------
-- 8. RLS — these functions are SECURITY DEFINER, so they bypass RLS by design.
--    Lock down who may call them and who may edit the mapping.
--    NOTE: supabase-rls.sql (base policies) is still NOT applied — do that
--    first, otherwise the tables below are open regardless of this section.
-- ---------------------------------------------------------------------------
alter table public.mh_item_map        enable row level security;
alter table public.mh_stock_sync_log  enable row level security;

-- Any active staff may read mappings + sync history.
create policy mh_item_map_select on public.mh_item_map
  for select using ( public.mh_is_active() );
create policy mh_sync_log_select on public.mh_stock_sync_log
  for select using ( public.mh_is_active() );

-- Only admins may create/edit mappings (a bad mapping silently misprices
-- stock, so treat it as an admin action).
create policy mh_item_map_admin_write on public.mh_item_map
  for all using ( public.mh_is_admin() ) with check ( public.mh_is_admin() );

-- The log is written only by the SECURITY DEFINER function; no direct writes.
revoke insert, update, delete on public.mh_stock_sync_log from anon, authenticated;

revoke all on function public.mh_apply_bill_stock(text) from public, anon;
grant execute on function public.mh_apply_bill_stock(text)   to authenticated;
grant execute on function public.mh_preview_bill_stock(text) to authenticated;

-- ============================================================================
--  BILLING APP CALL SEQUENCE (on settle)
--    1. select * from mh_preview_bill_stock(:bill_id);
--       -> if any row has is_mapped = false, prompt the user
--          ("Map now" writes mh_item_map, "Skip once" proceeds).
--    2. select * from mh_apply_bill_stock(:bill_id);
--       -> returns (applied, unmapped, skipped_reason). Safe to call twice.
--  Inventory app: show mh_stock_sync_pending + unmapped log rows for cleanup.
-- ============================================================================
