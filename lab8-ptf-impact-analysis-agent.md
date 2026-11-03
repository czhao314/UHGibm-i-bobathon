# Lab 8: PTF Impact Analysis Agent on IBM i with IBM Bob

**Duration:** 25 minutes  
**Difficulty:** Intermediate  
**Version:** 1 — June 2026

---

## Introduction

A fully patched system is not a finished system. Before you schedule the next maintenance window, you need to know: Is anything actually waiting to be applied? Which fixes are applied only temporarily and still need to be made permanent? Do the supersede chains all end in an installed PTF? Which PTF groups have drifted behind? And can you produce a change document your CAB (Change Advisory Board) will actually approve?

This lab turns IBM Bob into a **PTF Impact Analysis Agent**. Using Bob in **IBM i Database mode**, you'll query `QSYS2.GROUP_PTF_INFO` and `QSYS2.PTF_INFO` in plain English, confirm nothing is pending, audit supersede chains, generate a sequenced maintenance plan, and have Bob author a formal change request document — ready for approval.

**Objectives:**
- Query `QSYS2.GROUP_PTF_INFO` to inventory installed PTF groups, their levels, and when they were last applied
- Use `QSYS2.PTF_INFO` to confirm nothing is pending and to find PTFs applied only temporarily
- Audit supersede chains to prove every superseded PTF has an installed replacement
- Have Bob generate a sequenced maintenance plan (permanent apply plus PTF group refresh)
- Have Bob author a complete AI-written change request document

---

## Prerequisites

### IBM i System Requirements
- IBM i 7.6 (V7R6M0) — this lab uses `QSYS2.GROUP_PTF_INFO`, which is available on this system
- User profile with `*ALLOBJ` or `*IOSYSCFG` authority to query PTF services
- Mapepire server running on port 8076 (configured in Lab 4)

### Bob Requirements
- IBM Bob installed with IBM i Database mode configured (Lab 4)
- **IBM i Database mode** active — this is where all queries and documents in Parts 1–5 are produced

### Verify PTF Service Availability

Switch to IBM i Database mode and ask Bob:

```
Run a quick check to confirm QSYS2.GROUP_PTF_INFO and QSYS2.PTF_INFO
are accessible on this system and return their column lists.
```

---

## Key SQL Services Used in This Lab

| View / Function | What It Provides |
|---|---|
| `QSYS2.GROUP_PTF_INFO` | Each PTF group's name, description, installed level, target release, status, and apply timestamp — the primary currency source on this system (IBM i 7.6) |
| `QSYS2.PTF_INFO` | Every PTF on the system: status, IPL required flag, superseded-by ID, product, release, load/apply dates |
| `QSYS2.PTF_PRODUCT_INFO` | Cross-reference: which licensed programs are affected by a given PTF |

---

## Part 1: Group PTF Group Level Analysis

### Step 1: Activate IBM i Database Mode

- Expand the **mode dropdown** beneath the Bob chat input
- Select **IBM i Database**

### Step 2: Ask Bob for the Full PTF Group Picture

Paste this prompt:

```
Query QSYS2.GROUP_PTF_INFO and show me every PTF group on this system
that has a status of INSTALLED.
For each group, show the group name, description, installed level,
and when it was last applied. Sort by last applied date, oldest first.
```

Bob will generate and run something like:

```sql
SELECT   PTF_GROUP_NAME,
         PTF_GROUP_DESCRIPTION,
         MAX(PTF_GROUP_LEVEL)            AS INSTALLED_LEVEL,
         MAX(PTF_GROUP_APPLY_TIMESTAMP)  AS LAST_APPLIED
FROM     QSYS2.GROUP_PTF_INFO
WHERE    PTF_GROUP_STATUS = 'INSTALLED'
GROUP BY PTF_GROUP_NAME, PTF_GROUP_DESCRIPTION
ORDER BY LAST_APPLIED ASC
```

**What to look for:**
- Groups with the **oldest `LAST_APPLIED` dates** — these have gone longest without an update and carry the most accumulated risk
- `SF99960` (Db2 for i) and `SF99967` (Technology Refresh) are the most operationally critical
- `PTF_GROUP_STATUS` of `NOT INSTALLED` means the group has never been applied — maximum risk
- Groups applied within the last 30 days are current — no action needed

### Step 3: Focus on the Highest-Risk Groups

Follow up with:

```
From those results, which groups were last applied more than 6 months ago?
Show the group name, installed level, and last applied date.
```

Bob will filter the `GROUP_PTF_INFO` results already returned to highlight the groups most overdue for attention and narrow to your most critical licensed programs.

---

## Part 2: Individual PTF Status Inventory

### Step 4: Find PTFs That Are Applied Only Temporarily

```
Query QSYS2.PTF_INFO for all PTFs whose PTF_LOADED_STATUS is APPLIED
(temporarily applied - not yet permanent).
Show product, PTF ID, status, IPL required type, and the status timestamp.
Sort by status timestamp, oldest first.
```

Expected SQL pattern:

```sql
SELECT   PTF_PRODUCT_ID,
         PTF_IDENTIFIER,
         PTF_LOADED_STATUS,
         PTF_IPL_REQUIRED,
         PTF_STATUS_TIMESTAMP
FROM     QSYS2.PTF_INFO
WHERE    PTF_LOADED_STATUS = 'APPLIED'
ORDER BY PTF_STATUS_TIMESTAMP ASC, PTF_PRODUCT_ID
```

On the lab system this returns **151 PTFs**, all applied on 2025-11-25 (134 `IMMEDIATE`, 17 `DELAYED`). They are active but can still be removed - making them permanent is the open work item.

**`PTF_LOADED_STATUS` values seen on this system:**

| `PTF_LOADED_STATUS` | Meaning | Action |
|---|---|---|
| `PERMANENTLY APPLIED` | Applied and made permanent | None |
| `APPLIED` | Applied temporarily - still removable | Soak, then make permanent |
| `SUPERSEDED` | A newer PTF replaces this one | Verify the replacement is installed (Step 6) |
| Any other value (e.g. loaded but not applied) | Waiting to be applied | Schedule for apply |

### Step 5: Confirm Nothing Is Waiting to Be Applied

```
Query QSYS2.PTF_INFO and count PTFs that are not APPLIED, PERMANENTLY APPLIED
or SUPERSEDED, or that have an action pending or are on order.
Then summarise the APPLIED PTFs by IPL required type.
```

Expected SQL pattern:

```sql
SELECT COUNT(*) AS PENDING_PTFS
FROM   QSYS2.PTF_INFO
WHERE  PTF_LOADED_STATUS NOT IN ('APPLIED', 'PERMANENTLY APPLIED', 'SUPERSEDED')
   OR  PTF_ACTION_PENDING = 'YES'
   OR  PTF_ON_ORDER = 'YES'
```

**Expected result: `PENDING_PTFS = 0`.** There is no apply backlog - that is a valid audit finding, and it changes the plan Bob builds in Step 7.


---

## Part 3: Dependency and Supersede Chain Analysis

### Step 6: Audit the Supersede Chains

PTFs supersede each other in chains. A healthy system has an installed PTF at the end of every chain. A chain that ends in a PTF that is not on the system is a hidden gap.

```
For every PTF with PTF_LOADED_STATUS = SUPERSEDED, follow the supersede chain
(PTF A superseded by B, B superseded by C) to the terminal PTF. Summarise by
chain depth and by the loaded status of the terminal PTF, including any
terminal PTF that is not on this system at all.
```

Bob will produce a recursive CTE:

```sql
WITH SUPERSEDE_CHAIN (START_PTF, PRODUCT, CURRENT_PTF, CHAIN_STEP) AS (
  -- Base: superseded PTFs and the PTF that replaces them
  SELECT   PTF_IDENTIFIER, PTF_PRODUCT_ID, PTF_SUPERSEDED_BY_PTF, 1
  FROM     QSYS2.PTF_INFO
  WHERE    PTF_LOADED_STATUS = 'SUPERSEDED'
    AND    PTF_SUPERSEDED_BY_PTF <> ''

  UNION ALL

  -- Recursive: follow the chain
  SELECT   SC.START_PTF, SC.PRODUCT, P.PTF_SUPERSEDED_BY_PTF, SC.CHAIN_STEP + 1
  FROM     SUPERSEDE_CHAIN SC
  JOIN     QSYS2.PTF_INFO P
    ON     P.PTF_IDENTIFIER = SC.CURRENT_PTF
    AND    P.PTF_PRODUCT_ID = SC.PRODUCT
  WHERE    P.PTF_SUPERSEDED_BY_PTF <> ''
    AND    SC.CHAIN_STEP < 10
)
SELECT   SC.CHAIN_STEP                                   AS CHAIN_DEPTH,
         COALESCE(T.PTF_LOADED_STATUS, 'NOT ON SYSTEM')  AS TERMINAL_STATUS,
         COUNT(*)                                        AS PTF_COUNT
FROM     SUPERSEDE_CHAIN SC
LEFT JOIN QSYS2.PTF_INFO T
  ON     T.PTF_IDENTIFIER = SC.CURRENT_PTF
  AND    T.PTF_PRODUCT_ID = SC.PRODUCT
WHERE    SC.CHAIN_STEP = (SELECT MAX(X.CHAIN_STEP)
                          FROM   SUPERSEDE_CHAIN X
                          WHERE  X.START_PTF = SC.START_PTF
                            AND  X.PRODUCT   = SC.PRODUCT)
GROUP BY SC.CHAIN_STEP, COALESCE(T.PTF_LOADED_STATUS, 'NOT ON SYSTEM')
ORDER BY CHAIN_DEPTH DESC
```

**Expected result on the lab system:**

| CHAIN_DEPTH | TERMINAL_STATUS | PTF_COUNT |
|---|---|---|
| 2 | PERMANENTLY APPLIED | 64 |
| 2 | APPLIED | 179 |
| 1 | PERMANENTLY APPLIED | 111 |
| 1 | APPLIED | 92 |

> **Tip:** Every chain is 2 deep or less and every terminal PTF is installed - there are no `NOT ON SYSTEM` rows, so no superseded PTF needs action. A `CHAIN_DEPTH > 3`, or any `NOT ON SYSTEM` row, would indicate a real backlog.


---

## Part 4: Maintenance Plan Generation

With the group review, pending-PTF check, and supersede audit complete, ask Bob to synthesise everything into the plan for the next maintenance cycle.

### Step 7: Generate the Sequenced Maintenance Plan

```
Based on everything we've found - the PTF group levels and apply dates, the
temporarily applied PTFs, the zero-pending result, and the supersede chain
audit - generate a sequenced PTF maintenance plan for this system.

Structure it as:
1. Phase 1: Make the temporarily applied PTFs permanent (after a soak-period check)
2. Phase 2: Refresh the stale PTF groups - name the groups and levels to order,
   with a recommended maintenance window duration estimate
3. Confirmation that no superseded PTF needs action (cite the chain audit)
4. A summary risk statement: what is the exposure if we defer this work?
```

Bob will reason across all the query results from Parts 1–3 and produce a structured plan like:

---

**Example Bob output (abbreviated):**

> **PTF Maintenance Plan — IBMI-PROD01 — Generated 2026-06-15**
>
> **Current state:** 0 PTFs pending apply. 151 PTFs temporarily applied since 2025-11-25.
>
> **Phase 1 — Make Permanent — 151 PTFs (134 IMMEDIATE, 17 DELAYED)**
> Confirm no regressions since 2025-11-25, then make permanent product by
> product (5770SS1 first). After this step the PTFs can no longer be removed.
>
> **Phase 2 — PTF Group Refresh — Order from Fix Central**
> Recommended maintenance window: **45–60 minutes** (includes IPL cycle)
> 1. SF99761 (All PTF Groups) — installed level 7, last applied 2025-02-27
> 2. SF99963 (Performance Tools) and SF99411 (POWER11 GA) — last applied 2025-08-06
> 3. SF99760 (Cumulative) — installed level 25312; order the current level
>
> **Superseded PTFs — No Action**
> All 446 superseded PTFs have an installed replacement (0 missing terminals).
>
> **Risk Statement**
> No fix is currently waiting, so the exposure is drift rather than a backlog.
> The last full patch cycle was November 2025, and SF99761 dates from February 2025.
> Leaving the 151 temporary PTFs unmade-permanent also complicates the next
> cumulative apply. Deferring beyond the next scheduled maintenance window carries
> **Moderate** risk.

---

### Step 8: Save the Maintenance Plan to IFS

```
Save the maintenance plan as a Markdown file to the IFS at
/home/ITZUSER/PTFREPORTS/maintenance_plan_<today's date>_<yourname>.md
```

Bob uses `write_stream_file` to persist the plan, creating the directory if needed.

---

## Part 5: AI-Authored Change Request Document

### Step 9: Generate the Change Request

The maintenance plan is the technical artefact. The change request is the governance artefact. Ask Bob to write it:

```
Using the maintenance plan we just generated, write a formal IT change request
document suitable for submission to a Change Advisory Board (CAB).

Include:
- Change title and reference number (use today's date as the reference)
- Executive summary (2–3 sentences, non-technical)
- Systems affected (hostname, OS release, product IDs)
- Change description: what will be applied, in what order, and why
- Business justification: risk of deferral
- Implementation plan with phases, estimated durations, and responsible party placeholders
- Rollback plan: how to back out if something goes wrong
- Pre-change verification checks
- Post-change verification checks
- Approver signature block

Format it as a Markdown document.
```

**Example sections Bob will author:**

---

**Change Title:** PTF Permanent Apply and Group Refresh — IBMI-PROD01
**Change Reference:** CHG-2026-0615-001  
**Classification:** Standard — Scheduled Maintenance

**Executive Summary**
This change makes 151 temporarily applied Program Temporary Fixes (PTFs) permanent on IBM i system IBMI-PROD01 and refreshes the PTF groups that have fallen behind (SF99761, SF99963, SF99411, and the cumulative package SF99760). No fixes are currently waiting to be applied; this change closes out the November 2025 patch cycle and prevents drift. The group refresh requires an IPL and will be done during the next scheduled maintenance window.

**Rollback Plan**
Temporarily applied PTFs can be removed with `RMVPTF`, but **making them permanent removes that option**, so Phase 1 is performed only after the soak-period check passes. Phase 2 (group refresh) is preceded by a full `SAVSYS` to tape/SAVF to enable point-in-time recovery.

**Post-Change Verification**
- Confirm all Phase 1 PTFs show `PTF_LOADED_STATUS = 'PERMANENTLY APPLIED'` in `QSYS2.PTF_INFO`
- Confirm `PTF_GROUP_STATUS = 'INSTALLED'` and `PTF_GROUP_APPLY_TIMESTAMP` is updated for SF99761, SF99963, SF99411 and SF99760 in `QSYS2.GROUP_PTF_INFO`
- Re-run the Step 5 pending-PTF check and confirm it still returns 0
- Validate critical batch jobs complete normally within the first 24 hours post-change

---

### Step 10: Save the Change Document

```
Save the change request document to the IFS at
/home/ITZUSER/PTFREPORTS/change_request_CHG-2026-<today's date>_<yourname>.md
and also write it to the local workspace as
./ptf-reports/change_request_<today's date>_<yourname>.md
```

Bob will use `write_stream_file` for the IFS copy and the workspace file tools for the local copy — giving you both a system-side record and a local copy to paste into your ITSM tool.

---


## Common Troubleshooting

| Error | Likely Cause | Resolution |
|---|---|---|
| `SQL0204 — QSYS2.GROUP_PTF_CURRENCY not found` | `GROUP_PTF_CURRENCY` does not exist on IBM i 7.6 | Use `QSYS2.GROUP_PTF_INFO` — all lab queries have been updated to this service |
| `SQL0206 — column PTF_STATUS / IPL_REQUIRED / LOAD_DATE / SUPERSEDED_BY_PTF_ID not found` | Column names differ on IBM i 7.6 | Use `PTF_LOADED_STATUS`, `PTF_IPL_REQUIRED`, `PTF_STATUS_TIMESTAMP`, `PTF_SUPERSEDED_BY_PTF` |
| `GROUP_PTF_INFO` returns no rows | No PTF groups installed | Part 1 returns an empty result set; continue with `QSYS2.PTF_INFO` in Parts 2–3 |
| Step 5 returns `PENDING_PTFS = 0` | The system has no apply backlog | Expected on the lab system — this is a valid audit finding; continue with the permanent-apply and group-refresh plan |
| Supersede chain query runs slowly | Large PTF_INFO table with no index hint | Add `FETCH FIRST 50 ROWS ONLY` during investigation to limit scope |

---

## Conclusion

You've built a complete PTF Impact Analysis Agent on IBM i using Bob as the natural language interface. The capabilities delivered:

- **`QSYS2.GROUP_PTF_INFO`** as the PTF group currency source of truth — installed level, status, and apply timestamp at a glance (IBM i 7.6; `GROUP_PTF_CURRENCY` not available on this release)
- **`QSYS2.PTF_INFO`** to prove nothing is pending, find temporarily applied PTFs, and audit supersede chains
- **Maintenance plan generation** — permanent apply plus PTF group refresh, phased and risk-rated, produced by Bob in one conversational exchange
- **AI-authored change documents** — CAB-ready, with rollback plan and post-change verification queries

**Next Steps:**
- Connect the Lab 7 (Audit Journal) sysadmin agent mode with this PTF agent — security findings that map to CVEs can trigger an immediate PTF gap check
- Schedule the Group Currency query as a nightly Bob task and pipe the risk summary to Slack/Teams
- Extend the change document template with your organisation's specific CAB fields and ITSM tool format
- Explore `QSYS2.PTF_INFO.HIPER` column — High Impact PERvasive PTFs should always bypass normal deferral policies

**Resources:**
- [IBM i PTF Management Best Practices](https://www.ibm.com/support/pages/best-practices-ptf-or-fixes-installation)
- [QSYS2.GROUP_PTF_INFO — IBM Docs](https://www.ibm.com/docs/en/i/7.6?topic=services-group-ptf-info)
- [QSYS2.PTF_INFO — IBM Docs](https://www.ibm.com/docs/en/i/7.6?topic=services-ptf-info)
- [IBM i Fix Central](https://www.ibm.com/support/fixcentral/)

---

## Lab Instructor Guide

### Prerequisites on the IBM i Target

The lab system is IBM i **7.6 (V7R6M0)**. `QSYS2.GROUP_PTF_CURRENCY` **does not exist** on this release — all lab queries use `QSYS2.GROUP_PTF_INFO` instead.

Verify PTF groups are installed by running the following SQL (confirmed working as of lab prep):

```sql
SELECT PTF_GROUP_NAME, PTF_GROUP_DESCRIPTION, PTF_GROUP_LEVEL,
       PTF_GROUP_STATUS, PTF_GROUP_APPLY_TIMESTAMP
FROM   QSYS2.GROUP_PTF_INFO
WHERE  PTF_GROUP_STATUS = 'INSTALLED'
ORDER BY PTF_GROUP_NAME, PTF_GROUP_LEVEL
```

**Confirmed installed groups (13 distinct groups, 24 records):**

| Group | Description | Latest Level | Last Applied |
|---|---|---|---|
| SF99411 | IBM i 7.6 POWER11 GA PTF Group | 1 | 2025-08-06 |
| SF99686 | High Availability for IBM i | 3 | 2025-11-25 |
| SF99760 | Cumulative PTF Package | 25312 | 2025-11-25 |
| SF99761 | All PTF Groups (excl. Cumulative & MQ) | 7 | 2025-02-27 |
| SF99960 | DB2 for IBM i | 2 | 2025-11-25 |
| SF99961 | IBM Db2 Mirror for i | 2 | 2025-11-25 |
| SF99962 | IBM HTTP Server for i | 6 | 2025-11-25 |
| SF99963 | Performance Tools | 2 | 2025-08-06 |
| SF99964 | Backup Recovery Solutions | 2 | 2025-11-25 |
| SF99965 | Java | 3 | 2025-11-25 |
| SF99967 | Technology Refresh | 1 | 2025-11-25 |
| SF99968 | Group Security | 8 | 2025-11-25 |
| SF99969 | Group HIPER | 14 | 2025-11-25 |

If this query returns no rows, students can still work with `QSYS2.PTF_INFO` directly for Parts 2–3; Part 1 will return an empty result set.

### Expected State of the Lab System

This system has been fully patched: there are **no PTFs waiting to be applied**. The lab is written around that fact. Students audit the system, find what is still only temporarily applied, prove the supersede chains are healthy, and plan the next maintenance cycle. Verified values (as of lab prep):

| Check | Expected result |
|---|---|
| PTFs not loaded/applied, with an action pending, or on order (Step 5) | **0** |
| `PTF_LOADED_STATUS = 'APPLIED'` (temporary) | **151** (134 `IMMEDIATE`, 17 `DELAYED`), all applied 2025-11-25 |
| `PTF_LOADED_STATUS = 'PERMANENTLY APPLIED'` | 743 |
| `PTF_LOADED_STATUS = 'SUPERSEDED'` | 446 (243 chains of depth 2, 203 of depth 1), 0 with a missing replacement |
| Stalest PTF groups | SF99761 (2025-02-27), SF99963 and SF99411 (2025-08-06) |

> **Optional — demonstrate a real backlog:** to make Steps 4–5 return pending rows, load (but do not apply) a PTF with `LODPTF`. A loaded PTF appears in `QSYS2.PTF_INFO` with a `PTF_LOADED_STATUS` other than `APPLIED`, `PERMANENTLY APPLIED` or `SUPERSEDED`, and `PENDING_PTFS` becomes greater than 0. Remove it afterwards with `RMVPTF` or leave it for a follow-on exercise.

To verify the PTF group state students will see:

```sql
SELECT PTF_GROUP_NAME, PTF_GROUP_DESCRIPTION,
       MAX(PTF_GROUP_LEVEL) AS INSTALLED_LEVEL,
       MAX(PTF_GROUP_APPLY_TIMESTAMP) AS LAST_APPLIED
FROM   QSYS2.GROUP_PTF_INFO
WHERE  PTF_GROUP_STATUS = 'INSTALLED'
GROUP BY PTF_GROUP_NAME, PTF_GROUP_DESCRIPTION
ORDER BY LAST_APPLIED ASC
FETCH FIRST 5 ROWS ONLY
```

> **Note:** `GROUP_PTF_INFO` does not include IBM's current shipped level (`IBM_LEVEL`) or a pre-computed `GAP` column. Group drift for student exercises is demonstrated by comparing apply dates (SF99761 last applied 2025-02-27 versus most groups on 2025-11-25) and by showing that SF99761 (All PTF Groups) is at level 7 while SF99969 (Group HIPER) is at level 14, illustrating uneven application. The level to order is confirmed against IBM Fix Central.
