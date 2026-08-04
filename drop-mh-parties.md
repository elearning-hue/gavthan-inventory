# Dropping `mh_parties` — removal spec

`mh_parties` (suppliers) is being dropped. Web app is done (this repo).
Android app still depends on it — sites listed below.

## What the feature actually was

1. **Supplier field on a stock item** — optional dropdown on the Item sheet,
   stored as `mh_inventory_items.supplier_id`.
2. **"Also add ₹X to <supplier>'s ledger"** — a checkbox on the stock-movement
   sheet, shown only for a Purchase (`in`) on an item that had a supplier set.
   Ticking it posted an extra `mh_ledger` expense row carrying
   `party_id = supplier_id`.

Both are gone once the table goes. **Feature loss to be aware of:** there is
no longer any way to auto-post a stock purchase into the cashbook — after this
change, recording a purchase updates stock only, and the money side has to be
entered manually via Add income/expense. Say so if you want that re-added as a
supplier-free "also record this as an expense" checkbox; it doesn't need
`mh_parties` to work, it only needed it for the party link and the label.

---

## Web app (this repo) — DONE

All references removed from `index.html`:

| what | where it was |
|---|---|
| `suppliers` state | `Inventory` |
| `mh_parties` query in the parallel load | `Inventory.load` |
| `setSuppliers` | `Inventory.load` |
| `suppliers=` prop | `ItemSheet` + `MoveSheet` mounts |
| `suppliers` param, `supplier_id` form field, supplier `<select>` | `ItemSheet` |
| `suppliers` param, `supplierLedger` state, supplier lookup, ledger-post block, checkbox UI | `MoveSheet` |

Verified: zero matches for `mh_parties|supplier|party_id` in `index.html`,
app boots with no console errors.

Left alone deliberately: the `--av-sup` colour token and `.av.sup` CSS class.
Dead styling, not a table dependency, harmless.

---

## Android app (`inventory_android_app`) — TODO

Checked branch `claude/great-sanderson-23abf1`. **8 files** reference it.
(Note: the GitHub code-search API returns 0 hits on this private repo — it
isn't indexed. Clone and grep locally, don't trust the search API.)

| file | what to remove |
|---|---|
| `data/Models.kt:141,155` | `supplierId` field + its `supplier_id` parse |
| `data/Models.kt:188` | the whole `mh_parties` / `Party` model block |
| `data/Repos.kt:97` | `suppliers: List<Party>` in the state holder |
| `data/Repos.kt:114-115,122` | the `mh_parties` query + `suppliers = sD.await()` |
| `data/Repos.kt:140,150,186-192` | `supplierLedger` param on `recordMove`, and the `party_id` ledger-post block |
| `ui/inventory/InventoryScreen.kt:95,206,213` | `val suppliers` + both `suppliers =` args |
| `ui/inventory/ItemSheet.kt:49,65,79,156-160` | `suppliers` param, `supplierId` state, `supplier_id` put, supplier dropdown |
| `ui/inventory/MoveSheet.kt:48,56,64,84,142-149` | `suppliers` param, supplier lookup, `supplierLedger` state, arg, checkbox UI |
| `ui/components/Common.kt:446,452` | `Avatar(supplier: Boolean)` flag + `c.avSup` branch (optional — dead styling, same as web) |
| `res/values/strings.xml:124,125,146,147` | `field_supplier_opt`, `supplier_none`, `move_supplier_ledger`, `supplier_fallback` |
| `res/values-mr/strings.xml:124,125,146,147` | the same four Marathi strings |
| `README.md:123,161` | drop the supplier-ledger row and `mh_parties` from the table list |

Line numbers are from that branch at time of writing — re-grep before editing.

---

## Database

Drop only after both apps ship without these references, or the supplier
dropdown will error on load.

```sql
-- 1. column that pointed at it (both apps must stop reading it first)
ALTER TABLE mh_inventory_items DROP COLUMN IF EXISTS supplier_id;

-- 2. mh_ledger.party_id — CHECK FIRST. Historic purchase rows may still carry
--    supplier ids. Dropping the column destroys that link permanently.
--    Keep the column (harmless, just unreferenced) unless you're sure.
-- ALTER TABLE mh_ledger DROP COLUMN IF EXISTS party_id;

-- 3. the table itself
DROP TABLE IF EXISTS mh_parties;
```

`mh_ledger.party_id` is left in place on purpose above — historic rows written
by the old supplier-ledger checkbox still reference supplier ids, and those
ledger entries are real money that stays in the books. Dropping `mh_parties`
orphans the reference; dropping the column erases it. Decide which you want
before running step 2.
