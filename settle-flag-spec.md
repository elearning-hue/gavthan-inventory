# Functional spec — settle flag excludes amounts from totals

Shipped on web (`index.html`, commit `c7ca553`). Port to Android/Capacitor app.

## Rule

Settle flag = money actually received or paid.

An entry flagged **No** is *pending*. It must NOT count toward **Income**,
**Expense** or **Net** — nor the cashflow chart — until flipped to **Yes**.

Pending money is not hidden: it is reported separately so nothing silently
disappears.

---

## The predicate (get this exactly right)

```
isSettled(entry) = (entry.settled != false)
```

**Use `!= false`, NOT `== true`.**

`mh_ledger.settled` is nullable. Legacy rows and imported bills were created
before the flag existed, so their value is `null` / absent. Those must keep
counting exactly as they always did.

| stored value | counts in totals? | why |
|---|---|---|
| `true` | yes | explicitly settled |
| `null` / missing | **yes** | legacy or imported — never toggled |
| `false` | **no** | explicitly marked unsettled |

Using `== true` would drop every historic row from the totals overnight.

---

## Calculations

Given `periodEntries` = entries already filtered by the screen's date range,
staff, category and search text:

```
kindOf(e)       = (e.entry_type == "expense") ? "expense" : "income"

settledList     = periodEntries.filter(isSettled)
unsettledList   = periodEntries.filter(not isSettled)

income          = sum(amount) of settledList   where kindOf == "income"
expense         = sum(amount) of settledList   where kindOf == "expense"
net             = income - expense

pendingIncome   = sum(amount) of unsettledList where kindOf == "income"
pendingExpense  = sum(amount) of unsettledList where kindOf == "expense"
unsettledCount  = count(unsettledList)
```

Amount parsing must tolerate nulls/garbage: non-numeric → 0.

---

## Chart

The cashflow chart's source list must apply the **same** `isSettled` filter,
otherwise the chart contradicts the tiles sitting directly above it.

Web equivalent:
```
chartBase = allEntries.filter(isSettled AND matchStaff AND matchCategory AND matchText)
```
Note the chart deliberately ignores the screen's date mode (it has its own
1W/15D/1M/6M/1Y period selector) — only the settle filter is added here.

---

## UI changes

1. **Income tile** — under the value, if `pendingIncome > 0`:
   `+₹<pendingIncome> pending`
2. **Expense tile** — under the value, if `pendingExpense > 0`:
   `+₹<pendingExpense> pending`
3. **Net tile** — under the value, if `unsettledCount > 0`:
   `Settled only · N unsettled entries excluded`
   (singular "entry" when N == 1)

Styling of those sub-lines (web `.stat .pend`): ~10.5px, weight 600,
muted-secondary colour, 3px top margin. Android: small caption below the
figure, `textColorTertiary`.

Currency symbol **is** shown on these pending lines (they are standalone
figures, not table cells — see `inn.md` §11 for where ₹ is dropped).

---

## What does NOT change

- **Row list is unaffected.** The ledger table still shows unsettled rows
  normally. Only the aggregate tiles + chart exclude them.
- **The 3-state settle filter button** (All → Unsettled → Settled) keeps its
  existing behaviour — it filters which rows are listed, independent of this.
- **Excel export** still totals the rows currently visible, honouring the
  settle *filter*, not the settled-only rule. Left deliberately — flag if the
  export should split settled vs pending.
- Toggling the flag on a row is unchanged: optimistic UI update, revert on
  server error.

---

## Test vectors

Feed these five entries, expect the stated output.

| entry_type | amount | settled |
|---|---|---|
| income | 1000 | true |
| income | 500 | **false** |
| income | 250 | *(null)* |
| expense | 300 | true |
| expense | 200 | **false** |

Expected:

```
income          = 1250      (1000 + 250 legacy null; the 500 is excluded)
expense         =  300
net             =  950
pendingIncome   =  500
pendingExpense  =  200
unsettledCount  =    2
```

Tiles read:
```
Income   ₹1,250      +₹500 pending
Expense  ₹300        +₹200 pending
Net      ₹950        Settled only · 2 unsettled entries excluded
```

The `income == 1250` assertion is the important one — it proves the
null-flag legacy row was not dropped.
