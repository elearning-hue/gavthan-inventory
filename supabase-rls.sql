-- ============================================================================
--  Gavthan Manager — Row Level Security policies
--  Fix for audit finding #1 (P0): the web app's admin gating and identity
--  attribution are CLIENT-SIDE ONLY. Anyone with a login (the anon key is
--  public in index.html) can call the REST API directly and forge `created_by`,
--  run "admin" imports, or delete any row — UNLESS these policies enforce it.
--
--  Paste into Supabase → SQL editor. REVIEW every table/column name against your
--  actual schema before running — this reflects what the app reads/writes, which
--  may differ from your DB. Test with a non-admin account before launch.
--
--  Model:
--    * Only ACTIVE users in mh_users may read/write anything.
--    * A row's `created_by` must equal the caller's own email on INSERT,
--      UNLESS the caller is an admin (admins may attribute to anyone — needed
--      for Excel import and the "recorded by / reassign sales" features).
--    * Owners may update/settle their own rows; admins may update/delete any.
--    * Deactivation (mh_users.active=false) instantly removes ALL access,
--      because these functions re-check on every request (fixes finding C2).
-- ============================================================================

-- ---- helper functions (SECURITY DEFINER so they can read mh_users) ----------
-- Caller's email from the JWT. Supabase exposes it via auth.jwt().
create or replace function public.mh_email() returns text
  language sql stable
  as $$ select lower(nullif(auth.jwt() ->> 'email', '')) $$;

create or replace function public.mh_is_active() returns boolean
  language sql stable security definer set search_path = public
  as $$
    select exists (
      select 1 from public.mh_users u
      where lower(u.email) = public.mh_email()
        and coalesce(u.active, true) = true
    )
  $$;

create or replace function public.mh_is_admin() returns boolean
  language sql stable security definer set search_path = public
  as $$
    select exists (
      select 1 from public.mh_users u
      where lower(u.email) = public.mh_email()
        and u.role = 'admin'
        and coalesce(u.active, true) = true
    )
  $$;

-- ---- mh_ledger --------------------------------------------------------------
alter table public.mh_ledger enable row level security;

create policy mh_ledger_select on public.mh_ledger
  for select using ( public.mh_is_active() );

-- INSERT: staff may only insert rows attributed to themselves; admins may set
-- created_by to anyone (Excel import, reassignment).
create policy mh_ledger_insert on public.mh_ledger
  for insert with check (
    public.mh_is_active()
    and ( public.mh_is_admin() or lower(created_by) = public.mh_email() )
  );

-- UPDATE: owner may edit/settle their own row; admin may edit any. Prevent an
-- owner from re-attributing a row to someone else.
create policy mh_ledger_update on public.mh_ledger
  for update using (
    public.mh_is_active() and ( public.mh_is_admin() or lower(created_by) = public.mh_email() )
  ) with check (
    public.mh_is_admin() or lower(created_by) = public.mh_email()
  );

-- DELETE: admins only.
create policy mh_ledger_delete on public.mh_ledger
  for delete using ( public.mh_is_admin() );

-- ---- mh_inventory_items -----------------------------------------------------
alter table public.mh_inventory_items enable row level security;

create policy mh_items_select on public.mh_inventory_items
  for select using ( public.mh_is_active() );

create policy mh_items_insert on public.mh_inventory_items
  for insert with check ( public.mh_is_active() );

-- Any active staff may edit items and archive (active=false); tighten to
-- mh_is_admin() here if only managers should edit the catalogue.
create policy mh_items_update on public.mh_inventory_items
  for update using ( public.mh_is_active() ) with check ( public.mh_is_active() );

create policy mh_items_delete on public.mh_inventory_items
  for delete using ( public.mh_is_admin() );

-- ---- mh_stock_moves (audit trail: insert-only for staff) ---------------------
alter table public.mh_stock_moves enable row level security;

create policy mh_moves_select on public.mh_stock_moves
  for select using ( public.mh_is_active() );

create policy mh_moves_insert on public.mh_stock_moves
  for insert with check (
    public.mh_is_active()
    and ( public.mh_is_admin() or lower(created_by) = public.mh_email() )
  );

-- Movements are an audit trail — no edits/deletes except by admins.
create policy mh_moves_update on public.mh_stock_moves
  for update using ( public.mh_is_admin() ) with check ( public.mh_is_admin() );
create policy mh_moves_delete on public.mh_stock_moves
  for delete using ( public.mh_is_admin() );

-- ---- mh_parties (suppliers) -------------------------------------------------
alter table public.mh_parties enable row level security;
create policy mh_parties_select on public.mh_parties for select using ( public.mh_is_active() );
create policy mh_parties_write  on public.mh_parties for all
  using ( public.mh_is_active() ) with check ( public.mh_is_active() );

-- ---- mh_users (profiles/roles) ---------------------------------------------
-- Everyone active may read profiles (the app builds staff dropdowns from them),
-- but ONLY admins may change roles / active flags. A user must never be able to
-- promote themselves to admin or re-activate their own disabled account.
alter table public.mh_users enable row level security;
create policy mh_users_select on public.mh_users for select using ( public.mh_is_active() );
create policy mh_users_admin_write on public.mh_users for all
  using ( public.mh_is_admin() ) with check ( public.mh_is_admin() );

-- ---- mh_customers (bills, read-only from this app) --------------------------
-- The manager app only SELECTs bills to import sales. Writes come from the
-- separate billing app; do not grant write here unless that app shares this role.
alter table public.mh_customers enable row level security;
create policy mh_customers_select on public.mh_customers
  for select using ( public.mh_is_active() );

-- ============================================================================
--  RECOMMENDED companion constraints (belt-and-suspenders for the data-integrity
--  findings #4 / #5 — stop double-imports at the DB, not just the UI):
--
--    create unique index if not exists mh_ledger_source_ref_uniq
--      on public.mh_ledger (source, ref) where ref is not null;
--
--  Then the app's importSales / Excel import should upsert with
--  on_conflict=source,ref and ignore duplicates.
-- ============================================================================
