# Lab 8: PTF Impact Analysis Agent on IBM i with IBM Bob

**Duration:** 25 minutes  
**Difficulty:** Intermediate  
**Version:** 1 — June 2026

---

## Introduction

Knowing *which* PTFs are missing is only half the job. Before you schedule a maintenance window, you need to know: How far behind are your PTF groups? Which missing fixes carry pre-requisites or supersede chains you must apply first? Which ones require an IPL — and which can go in immediately? And can you produce a change document your CAB (Change Advisory Board) will actually approve?

This lab turns IBM Bob into a **PTF Impact Analysis Agent**. Using Bob in **IBM i Database mode**, you'll query `QSYS2.GROUP_PTF_INFO` and `QSYS2.PTF_INFO` in plain English, trace dependency and supersede chains, generate a sequenced deployment plan, and have Bob author a formal change request document — ready for approval. An optional final section shows how to hand the plan off to the Ansible playbooks built in Lab 5.

**Objectives:**
- Query `QSYS2.GROUP_PTF_INFO` to inventory installed PTF groups, their levels, and when they were last applied
- Use `QSYS2.PTF_INFO` to analyse individual PTF status, IPL requirements, and supersede relationships
- Trace pre-requisite and supersede chains to establish correct application order
- Have Bob generate a sequenced, human-readable deployment plan
- Have Bob author a complete AI-written change request document
- (Optional) Feed the deployment plan into an Ansible `ibmi_fix` playbook from Lab 5

---

## Prerequisites

### IBM i System Requirements
- IBM i 7.6 (V7R6M0) — this lab uses `QSYS2.GROUP_PTF_INFO`, which is available on this system
- User profile with `*ALLOBJ` or `*IOSYSCFG` authority to query PTF services
- Mapepire server running on port 8076 (configured in Lab 4)

### Bob Requirements
- IBM Bob installed with IBM i Database mode configured (Lab 4)
- **IBM i Database mode** active — this is where all queries in Parts 1–4 run
- **IBM i Developer mode** available for the optional Ansible section (Part 5)

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

### Step 4: Surface All Unapplied PTFs

```
Query QSYS2.PTF_INFO for all PTFs that are NOT in status APPLIED or ON ORDER.
Show PTF ID, product, status, whether an IPL is required, and the load date.
Sort by load date so the oldest unaddressed PTFs are first.
```

Expected SQL pattern:

```sql
SELECT   PTF_IDENTIFIER,
         PRODUCT_ID,
         PTF_STATUS,
         IPL_REQUIRED,
         LOAD_DATE,
         SUPERSEDED_BY_PTF_ID
FROM     QSYS2.PTF_INFO
WHERE    PTF_STATUS NOT IN ('APPLIED', 'ON ORDER', 'SUPERSEDED')
ORDER BY LOAD_DATE ASC
```

**Status values and what they mean:**

| `PTF_STATUS` | Meaning | Action |
|---|---|---|
| `NOT APPLIED` | Loaded on disk, not yet applied | Schedule for apply |
| `APPLY PENDING` | Queued, waiting for IPL or delayed apply | Check `IPL_REQUIRED` |
| `LOADED` | Transferred to system, not yet applied | Apply immediately or at next window |
| `SUPERSEDED` | A newer PTF replaces this one | Apply the superseding PTF instead |
| `TEMPORARILY APPLIED` | Applied but not permanent | Confirm or make permanent |


---

## Part 3: Dependency and Supersede Chain Analysis

### Step 6: Trace the Supersede Chain

PTFs supersede each other in chains. Applying an older PTF when a newer one supersedes it wastes time and may leave the system in an inconsistent state.

```
For each unapplied PTF that has a SUPERSEDED_BY_PTF_ID, show me the full
supersede chain — PTF A superseded by B, B superseded by C — until we reach
the terminal (non-superseded) PTF. That terminal one is what I actually need
to apply.
```

Bob will produce a recursive CTE:

```sql
WITH SUPERSEDE_CHAIN (START_PTF, CURRENT_PTF, CHAIN_STEP) AS (
  -- Base: unapplied PTFs that are superseded
  SELECT   PTF_IDENTIFIER, SUPERSEDED_BY_PTF_ID, 1
  FROM     QSYS2.PTF_INFO
  WHERE    PTF_STATUS NOT IN ('APPLIED', 'ON ORDER')
    AND    SUPERSEDED_BY_PTF_ID IS NOT NULL

  UNION ALL

  -- Recursive: follow the chain
  SELECT   SC.START_PTF, P.SUPERSEDED_BY_PTF_ID, SC.CHAIN_STEP + 1
  FROM     SUPERSEDE_CHAIN SC
  JOIN     QSYS2.PTF_INFO P
    ON     SC.CURRENT_PTF = P.PTF_IDENTIFIER
  WHERE    P.SUPERSEDED_BY_PTF_ID IS NOT NULL
    AND    SC.CHAIN_STEP < 10
)
SELECT   START_PTF    AS ORIGINAL_PTF,
         CURRENT_PTF  AS TERMINAL_PTF_TO_APPLY,
         CHAIN_STEP   AS CHAIN_DEPTH
FROM     SUPERSEDE_CHAIN
WHERE    (START_PTF, CHAIN_STEP) IN (
           SELECT START_PTF, MAX(CHAIN_STEP)
           FROM   SUPERSEDE_CHAIN
           GROUP BY START_PTF
         )
ORDER BY CHAIN_DEPTH DESC
```

> **Tip:** A `CHAIN_DEPTH > 3` is a sign the system has been going without PTFs for a long time — the backlog has compounded.


---

## Part 4: Deployment Plan Generation

With the gap analysis, IPL split, and supersede chains checks complete, ask Bob to synthesise everything into an actionable deployment plan.

### Step 8: Generate the Sequenced Deployment Plan

```
Based on everything we've found — the PTF group levels and apply dates, the unapplied PTFs,
the IPL requirements, the supersede chains — generate
a sequenced PTF deployment plan for this system.

Structure it as:
1. Phase 1: Immediate applies (no IPL)
2. Phase 2: IPL-required applies with a
   recommended maintenance window duration estimate
3. PTFs to skip because they are superseded (list the terminal replacement)
4. A summary risk statement: what is the exposure if we defer this work?
```

Bob will reason across all the query results from Parts 1–3 and produce a structured plan like:

---

**Example Bob output (abbreviated):**

> **PTF Deployment Plan — IBMI-PROD01 — Generated 2026-06-15**
>
> **Phase 1 — Immediate Applies (no IPL required) — 14 PTFs**
> Apply in this order:
> 1. SI88234 (5770SS1) — pre-req for SI88901
> 2. SI88901 (5770SS1)
> 3. SI87612 (5770DB1)
> …
>
> **Phase 2 — IPL-Required Applies — 7 PTFs**
> Recommended maintenance window: **45–60 minutes** (includes IPL cycle)
> Apply in this order:
> 1. SI89001 (5770TC1) — no pre-reqs
> 2. SI89412 (5770SS1) — pre-req: SI89001 (Phase 2 item 1)
> …
>
> **Superseded — Skip These, Apply Terminal Instead**
> - SI85001 → superseded by SI87444 (already in Phase 1)
>
> **Risk Statement**
> SF99960 (Db2 for i) was last applied in November 2025. Three of the
> missing PTFs address SQL query performance regressions affecting high-volume
> batch jobs. SF99967 (Technology Refresh) was last applied in November 2025; two missing PTFs
> include security fixes for privilege escalation CVEs. Deferring beyond the
> next scheduled maintenance window carries **High** operational and security risk.

---

### Step 9: Save the Deployment Plan to IFS

```
Save the deployment plan as a Markdown file to the IFS at
/home/ITZUSER/PTFREPORTS/deployment_plan_<today's date>_<yourname>.md
```

Bob uses `write_stream_file` to persist the plan, creating the directory if needed.

---

## Part 5: AI-Authored Change Request Document

The deployment plan is the technical artefact. The change request is the governance artefact. Ask Bob to write it:

```
Using the deployment plan we just generated, write a formal IT change request
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

**Change Title:** PTF Group Level Remediation — IBMI-PROD01
**Change Reference:** CHG-2026-0615-001  
**Classification:** Standard — Scheduled Maintenance

**Executive Summary**
This change applies 21 Program Temporary Fixes (PTFs) to IBM i system IBMI-PROD01 to address outstanding PTF group levels for Db2 for i (SF99960) and Technology Refresh (SF99967), neither of which has been updated since November 2025. Two PTFs in scope address published security vulnerabilities. The change is decomposed into an immediate phase (no system restart) and a planned IPL phase during the next scheduled maintenance window.

**Rollback Plan**  
IBM i PTFs can be removed using `RMVPTF` for temporarily-applied fixes. Permanently-applied PTFs can be backed out to the previous PTF save file if one was captured before this change. The Phase 1 (immediate) applies will be performed with `DELAYED(*YES)` to allow inspection before permanent activation. The Phase 2 IPL applies will be preceded by a full `SAVSYS` to tape/SAVF to enable point-in-time recovery.

**Post-Change Verification**  
- Confirm all Phase 1 PTFs show `PTF_STATUS = 'APPLIED'` in `QSYS2.PTF_INFO`  
- Confirm `PTF_GROUP_STATUS = 'INSTALLED'` and `PTF_GROUP_APPLY_TIMESTAMP` is updated for SF99960 and SF99967 in `QSYS2.GROUP_PTF_INFO`
- Run the Lab 5 PTF compliance Ansible playbook to generate an updated compliance report
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
| `GROUP_PTF_INFO` returns no rows | No PTF groups installed | Apply a cumulative PTF package first: `ibmi_fix` with a SF99760 group fix |
| `PTF_INFO` shows `ON ORDER` for many PTFs | PTF ordering via ECS is pending | Check WRKPTFGRP output; PTFs may still be downloading from IBM |
| Supersede chain query runs slowly | Large PTF_INFO table with no index hint | Add `FETCH FIRST 50 ROWS ONLY` during investigation to limit scope |
| `ibmi_fix` Ansible module fails with `CPF3634` | PTF save files not present on system | Use `ibmi_fix_repo_lkup` first to confirm PTF is available locally |

---

## Conclusion

You've built a complete PTF Impact Analysis Agent on IBM i using Bob as the natural language interface. The capabilities delivered:

- **`QSYS2.GROUP_PTF_INFO`** as the currency gap source of truth — installed level, status, and apply timestamp at a glance (IBM i 7.6; `GROUP_PTF_CURRENCY` not available on this release)
- **`QSYS2.PTF_INFO`** for individual PTF status, IPL requirements, and supersede/pre-requisite chains
- **Deployment plan generation** — phased, ordered, and risk-rated, produced by Bob in one conversational exchange
- **AI-authored change documents** — CAB-ready, with rollback plan and post-change verification queries
- **Custom PTF Impact Agent mode** — makes this analysis available to anyone on your team in natural language
- **Ansible handoff** — plan approved, execution automated via `ibmi_fix` with phased staging

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

### Seeding a Realistic Gap

To give students something to find, deliberately leave the system a few levels behind by not applying the latest cumulative. On a lab system this is the natural state — no action usually needed.

To verify the gap students will see:

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

> **Note:** `GROUP_PTF_INFO` does not include IBM's current shipped level (`IBM_LEVEL`) or a pre-computed `GAP` column. The "gap" for student exercises is demonstrated by comparing installed levels against IBM Fix Central or by showing that SF99761 (All PTF Groups) is at level 7 while SF99969 (Group HIPER) is at level 14, illustrating uneven application.

### Ansible Section Note

Part 7 (Ansible handoff) reuses the Lab 5 inventory and collection setup. Confirm `ibm.power_ibmi:3.3.0` is still installed on the Ansible controller before the session:

```bash
ansible-galaxy collection list | grep ibm.power_ibmi
```
