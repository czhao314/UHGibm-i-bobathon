# Lab 9: Predictive Operational Health Monitoring on IBM i with IBM Bob

**Duration:** 20 minutes
**Difficulty:** Intermediate  
**Version:** 1 — June 2026

---

## Introduction

Reactive troubleshooting — waiting for a user to report slowness, then hunting for the hot job — is the most common IBM i operational pattern. But the data to catch problems *before* users notice has always been there: IBM i continuously exposes system metrics through `QSYS2` SQL services and captures multi-interval performance history via Collection Services. The gap has been the effort required to query, interpret, and act on that data.

This lab turns IBM Bob into a **Predictive Operational Health Monitor**. Using Bob in **IBM i Database mode**, you'll establish a current-state baseline across CPU, disk, memory pools, and active jobs; compare snapshots across time to detect trends; identify resources approaching saturation; and have Bob produce a capacity forecast and a prioritised health report.

**Objectives:**
- Take and interpret real-time health snapshots using `QSYS2.SYSTEM_STATUS_INFO`, `QSYS2.SYSDISKSTAT`, and `QSYS2.MEMORY_POOL_INFO`
- Read Collection Services history from `QSYS2.COLLECTION_SERVICES_INFO` and `QPFRDATA`
- Detect anomalies by comparing current metrics against a rolling baseline
- Identify resources trending toward saturation and forecast when thresholds will be breached
- Have Bob generate a prioritised health report with risk ratings and recommended actions

---

## Prerequisites

### IBM i System Requirements
- IBM i 7.3 or higher
- User profile with `*ALLOBJ` or `*IOSYSCFG` authority to query system services
- Collection Services started (instructions below if not active)

### Bob Requirements
- IBM Bob installed with IBM i Database mode configured (Lab 4)
- **IBM i Database mode** active for all SQL queries
- **IBM i Developer mode** available for CL commands

### Verify and Start Collection Services

Switch to **IBM i Developer mode** and ask Bob:

```
Check if Collection Services is currently running on this system.
Show the collection name, profile, start time, and what categories are being collected.
```

Bob will query `QSYS2.COLLECTION_SERVICES_INFO`. If nothing is returned, start a collection:

```
Start a Collection Services collection on this system using the *STANDARDP profile.
```

Bob will execute:
```
STRPFRCOL COLPRF(*STANDARDP)
```

> **Note:** `*STANDARDP` captures system-level metrics (`*SYSLVL`, `*DISK`, `*JOBMI`). The default collection interval is 15 minutes, which is sufficient for trend analysis (`*DISK` is always collected at 5 minutes or less). To use a shorter interval, run `CFGPFRCOL INTERVAL(5)`; the change takes effect immediately. For this lab, even a collection started a few minutes before the exercises will generate enough data to work with.

---

## Key SQL Services Used in This Lab

| View | What It Provides |
|---|---|
| `QSYS2.SYSTEM_STATUS_INFO` | Point-in-time: CPU utilisation, active jobs, ASP usage, temp storage |
| `QSYS2.SYSDISKSTAT` | Per-disk-arm: storage used %, I/O request counts, elapsed busy %, service time |
| `QSYS2.MEMORY_POOL_INFO` | Per-pool: size, elapsed fault counts, active/ineligible threads, defined size |
| `QSYS2.ACTIVE_JOB_INFO` | Live job snapshot: CPU%, thread count, memory, wait reason |
| `QSYS2.COLLECTION_SERVICES_INFO` | Collection state, profile, interval, categories |
| `QPFRDATA.QAPMJSUM` | Collection Services history — CPU ms per interval by job group (15-min intervals) |
| `QPFRDATA.QAPMDISK` | Collection Services history — per-disk I/O counts, service time, utilisation per interval |

---

## Part 1: Current-State Health Snapshot

### Step 1: Full System Health Snapshot

First, expand the **mode dropdown** beneath the Bob chat input and select **IBM i Database**. Then start with a single comprehensive prompt to establish the current baseline:

```
Take a full health snapshot of this IBM i system right now. I want:
1. Overall CPU utilisation and how many jobs are active vs. waiting
2. ASP usage percentage and how much free space remains
3. The top 3 memory pools by fault rate
4. The top 3 disk arms by utilisation percentage
5. Any metric that is already above 80% — flag those as critical

Present the results as a structured health dashboard summary.
```

Bob will run several queries in sequence and synthesise the results. The underlying SQL for each component:

**CPU and job counts:**
```sql
SELECT   ELAPSED_CPU_USED                                        AS CPU_PCT,
         ACTIVE_JOBS_IN_SYSTEM,
         BATCH_RUNNING,
         BATCH_WAITING_TO_RUN,
         SYSTEM_ASP_USED                                         AS ASP_PCT_USED,
         TOTAL_AUXILIARY_STORAGE                                 AS ASP_TOTAL_MB,
         SYSTEM_ASP_STORAGE                                      AS SYSTEM_ASP_TOTAL_MB,
         TOTAL_JOBS_IN_SYSTEM,
         MAIN_STORAGE_SIZE                                       AS MAIN_MEMORY_KB
FROM     QSYS2.SYSTEM_STATUS_INFO
```

**Disk arm utilisation:**
```sql
-- QSYS2.SYSDISKSTAT is the correct view (QSYS2.DISK_STATISTICS does not exist)
SELECT   UNIT_NUMBER,
         DISK_TYPE,
         DISK_MODEL,
         SERIAL_NUMBER,
         PERCENT_USED                                            AS STORAGE_USED_PCT,
         ELAPSED_PERCENT_BUSY                                    AS ARM_BUSY_PCT,
         ELAPSED_IO_REQUESTS                                     AS IO_OPS_PER_SEC,
         HARDWARE_STATUS
FROM     QSYS2.SYSDISKSTAT
ORDER BY COALESCE(ELAPSED_PERCENT_BUSY, -1) DESC
FETCH FIRST 3 ROWS ONLY
```

**Memory pool fault rates:**
```sql
SELECT   POOL_NAME,
         CURRENT_SIZE                                            AS CURRENT_SIZE_MB,
         DEFINED_SIZE                                            AS DEFINED_SIZE_MB,
         ELAPSED_DATABASE_FAULTS                                 AS DB_FAULTS,
         ELAPSED_NON_DATABASE_FAULTS                             AS NON_DB_FAULTS,
         ELAPSED_TOTAL_FAULTS                                    AS TOTAL_FAULTS,
         CURRENT_THREADS,
         CURRENT_INELIGIBLE_THREADS
FROM     QSYS2.MEMORY_POOL_INFO
ORDER BY ELAPSED_TOTAL_FAULTS DESC
FETCH FIRST 3 ROWS ONLY
```

**What to look for:**
- `ELAPSED_CPU_USED > 80` — system is CPU-constrained; batch jobs may be competing with interactive
- `SYSTEM_ASP_USED > 85` — disk space risk; journals and save files consume headroom quickly
- `ELAPSED_PERCENT_BUSY > 70` — I/O bottleneck risk on that arm (note: NULL for SAN/virtual disks — use `PERCENT_USED` instead)
- `ELAPSED_TOTAL_FAULTS` elevated in `*BASE` or `*INTERACT` pool — memory pressure causing paging

### Step 2: Identify the Top Resource Consumers Right Now

```
Show me the top 10 active jobs by current elapsed CPU percentage.
For each job, also show thread count, temporary storage used, and current wait reason.
Flag any job over 20% elapsed CPU as a potential concern.
```

Bob queries `QSYS2.ACTIVE_JOB_INFO` with `ELAPSED_CPU_PERCENTAGE` ordered descending. This gives you the live picture to compare against the pool and disk metrics from Step 2.

---

## Part 2: Trend Analysis with Collection Services

A single snapshot tells you the state *now*. Trends tell you where the system is *going*.

### Step 3: Point at the Latest Collection

`QPFRDATA.QAPMJSUM` and `QPFRDATA.QAPMDISK` hold one member per collection. A plain `FROM QPFRDATA.QAPMJSUM` reads only the oldest member, so you need aliases for the newest one.

```
Find the most recent member of QPFRDATA.QAPMJSUM and QPFRDATA.QAPMDISK
using QSYS2.SYSPARTITIONSTAT (highest CREATE_TIMESTAMP). Create QTEMP aliases
called JSUM and DISK that point at those members. Use them in the next steps.
```

Bob will run, for both files:

```sql
SELECT TABLE_NAME, TABLE_PARTITION AS LATEST_MEMBER, NUMBER_ROWS
FROM (SELECT TABLE_NAME, TABLE_PARTITION, NUMBER_ROWS,
             ROW_NUMBER() OVER (PARTITION BY TABLE_NAME
                                ORDER BY CREATE_TIMESTAMP DESC) AS RN
      FROM QSYS2.SYSPARTITIONSTAT
      WHERE TABLE_SCHEMA = 'QPFRDATA'
        AND TABLE_NAME IN ('QAPMJSUM', 'QAPMDISK')) X
WHERE RN = 1
```

and then, using the member names it returns:

```sql
CREATE OR REPLACE ALIAS QTEMP.JSUM FOR QPFRDATA.QAPMJSUM (<latest member>)
CREATE OR REPLACE ALIAS QTEMP.DISK FOR QPFRDATA.QAPMDISK (<latest member>)
```

> **Note:** `QTEMP` aliases last only for the current job. If Bob reports `QTEMP.JSUM not found` later, repeat this step.

### Step 4: Read Collection Services History and Detect the CPU Trend

```
Query QSYS2.COLLECTION_SERVICES_INFO to show me the active collection name,
profile, and start time. Then query QTEMP.JSUM for system-level CPU
samples over the most recent 2 hours of collected data. Sum all job-group buckets per interval to get
the system total. Show timestamp, CPU ms per second, and interval duration.

Then, using window arithmetic on those samples, tell me:
1. The average CPU over the full window
2. The average CPU for the first half vs the second half of the window
3. Whether the trend is rising (second half > first half by more than 5%), falling, or flat
4. The peak CPU sample and when it occurred
```

Bob will query the Collection Services data through the alias — `SYSTOOLS.METRICS_*` views are not available on this system:

```sql
-- System-level CPU per 15-minute interval
-- Sum all JSCBKT buckets per interval to get the full-system total
SELECT   DATETIME                                               AS INTERVAL_TS,
         INTSEC                                                 AS INTERVAL_SEC,
         SUM(JSCPU)                                            AS TOTAL_CPU_MS,
         DECIMAL(SUM(JSCPU) / NULLIF(INTSEC, 0), 12, 2)       AS CPU_MS_PER_SEC
FROM     QTEMP.JSUM
WHERE    DATETIME >= (SELECT MAX(DATETIME) - 2 HOURS FROM QTEMP.JSUM)
GROUP BY DATETIME, INTSEC
ORDER BY DATETIME
```

> **Tip:** `JSCPU` is total CPU milliseconds consumed by all jobs in the interval. Dividing by `INTSEC` normalises across any variable-length intervals. The window is anchored to the newest collected interval (`MAX(DATETIME)`) rather than the clock, so the query works whether the data is minutes or days old. If only 1–2 intervals have been collected (collection just started), narrow the window to `MAX(DATETIME) - 30 MINUTES` and note that the trend window is short.

Bob will apply window arithmetic to the sample set and classify the trend — this is the core of anomaly detection without requiring a dedicated monitoring tool.

### Step 5: Disk I/O Trend

```
From Collection Services data, show me disk I/O request rates and average
response times sampled over the most recent 2 hours of collected data. Flag any interval where
average response time exceeded 20ms — that threshold indicates I/O pressure.
```

Bob will query `QTEMP.DISK` — `SYSTOOLS.METRICS_DISK` does not exist on this system:

```sql
-- Per-disk I/O rate and average response time from Collection Services
-- DSSRVT = total service time ms across all ops in the interval
-- DSWT   = total queue wait time ms across all ops in the interval
SELECT   DATETIME                                                         AS INTERVAL_TS,
         DSARM                                                            AS DISK_UNIT,
         DECIMAL((DSRDS + DSWRTS) / NULLIF(INTSEC, 0), 10, 2)           AS IO_OPS_PER_SEC,
         DECIMAL(DSRDS            / NULLIF(INTSEC, 0), 10, 2)            AS READ_OPS_PER_SEC,
         DECIMAL(DSWRTS           / NULLIF(INTSEC, 0), 10, 2)            AS WRITE_OPS_PER_SEC,
         DECIMAL((DSSRVT + DSWT)  / NULLIF(DSRDS + DSWRTS, 0), 10, 3)  AS AVG_RESP_MS,
         CASE
           WHEN (DSSRVT + DSWT) / NULLIF(DSRDS + DSWRTS, 0) > 20
           THEN '🚨 PRESSURE'
           ELSE '✅ OK'
         END                                                              AS IO_FLAG
FROM     QTEMP.DISK
WHERE    DATETIME >= (SELECT MAX(DATETIME) - 2 HOURS FROM QTEMP.DISK)
ORDER BY DATETIME, DSARM
```

---

## Part 3: Anomaly Detection

### Step 6: Compare Current Metrics to the Sampled Baseline

```
Using the Collection Services samples from QTEMP.JSUM and QTEMP.DISK
over the most recent 2 hours of collected data, treat all intervals except the latest
as the baseline and the latest interval as "current".

For each metric (CPU ms/sec and disk I/O ops/sec):
- Show the baseline average across all sampled intervals
- Show the current value from the most recent interval
- Calculate the deviation (current minus baseline average)
- Flag as ANOMALY if the current value is more than 2 standard deviations above
  the baseline average, or more than 25% above it in absolute terms
- Also identify the single most unusual interval in the window (highest value
  relative to the average) and say whether it is a meaningful anomaly or normal variance
```

> **Note:** A healthy system will often show no anomaly. "Normal variance" is a valid finding.

Bob will calculate rolling statistics across the sample set and compare point-in-time values — surfacing genuine deviations rather than normal variance. Example output structure Bob will produce (values will differ on your system):

| Metric | Baseline Avg | Current | Deviation | Status |
|---|---|---|---|---|
| CPU ms/sec | 1.2 | 1.4 | +0.2 | Normal |
| Disk I/O ops/sec | 28.1 | 29.4 | +1.3 | Normal |

---

## Part 4: Capacity Forecasting

### Step 7: ASP Usage Forecast

ASP (Auxiliary Storage Pool) usage grows monotonically unless objects are deleted or saved-and-freed. It's the most forecastable metric on the system. Collection Services does not hold a long enough ASP history for a fitted trend in this lab, so you will project from the current snapshot and a stated growth assumption.

```
Query QSYS2.ASP_INFO for the current system ASP (ASP 1) usage.
Assume the ASP grows by 2 GB per day.
Project forward: how many days until ASP reaches 85%? And how many days
until it reaches 95%?
Flag if either threshold is within 30 days.
```

Bob will query the current ASP snapshot and apply a linear projection:

```sql
-- Current ASP usage from QSYS2.ASP_INFO (current snapshot)
-- TOTAL_CAPACITY and TOTAL_CAPACITY_AVAILABLE are in MB
SELECT   ASP_NUMBER,
         ASP_TYPE,
         TOTAL_CAPACITY                                              AS TOTAL_MB,
         TOTAL_CAPACITY_AVAILABLE                                    AS FREE_MB,
         (TOTAL_CAPACITY - TOTAL_CAPACITY_AVAILABLE)                AS USED_MB,
         DECIMAL((TOTAL_CAPACITY - TOTAL_CAPACITY_AVAILABLE) * 100.0
                 / NULLIF(TOTAL_CAPACITY, 0), 5, 2)                AS USED_PCT,
         STORAGE_THRESHOLD_PERCENTAGE                               AS THRESHOLD_PCT
FROM     QSYS2.ASP_INFO
ORDER BY ASP_NUMBER
```

Then reason over the projection:
> *"ASP 1 is currently at 35.42% (66.0 GB of 186.4 GB). Assuming 2 GB/day growth: the 85% threshold (158.5 GB) will be reached in approximately **46 days**, and the 95% threshold (177.1 GB) in approximately **56 days**. Neither is within the 30-day warning window — **Low risk**. Note the system's own storage threshold is 90%."*

---

## Part 5: Health Report Generation

### Step 8: Consolidated Health Report

```
Based on everything we've found — the current snapshot, trend analysis,
anomaly detection, and capacity forecast —
generate a comprehensive operational health report for this IBM i system.

Structure it as:
1. Executive Summary (3 sentences, non-technical)
2. Health Dashboard — one row per metric with current value, trend, and status
   (Green / Yellow / Red)
3. Anomalies Detected — what is unusual right now and the likely cause
4. Capacity Forecasts — resources approaching limits with days-to-threshold
5. Recommended Actions — prioritised list (Critical / High / Medium / Low)
   with specific commands or queries to execute
6. Monitoring Recommendations — what to watch over the next 24–72 hours

If no anomaly was found, state that clearly and mark the dashboard Green.

Format as Markdown.
```

> **Tip:** Ask Bob to save the report to the IFS once generated: *"Save that report to `/home/ITZUSER/HEALTHREPORTS/health_report_<today's date>_<yourname>.md`"*

---

## Common Troubleshooting

| Error | Likely Cause | Resolution |
|---|---|---|
| `QSYS2.DISK_STATISTICS` not found | This view does not exist — correct name is `QSYS2.SYSDISKSTAT` | Replace all references with `QSYS2.SYSDISKSTAT` |
| `QSYS2.COLLECTION_SERVICES_INFO` returns no rows | No collection running | Run `STRPFRCOL COLPRF(*STANDARDP)` |
| Collection data only covers a few minutes | Collection just started | Wait 2–3 intervals (30–45 mins at 15-min interval) or reduce interval to 5 mins for lab: `CFGPFRCOL INTERVAL(5)` |
| `QSYS2.SYSDISKSTAT` columns `ELAPSED_PERCENT_BUSY` / `ELAPSED_IO_REQUESTS` are NULL | Disk is SAN/virtual (e.g. IBM 2145) — hypervisor does not expose arm-level I/O counters | Use `PERCENT_USED` for storage utilisation; arm-level busy % is not available for virtual disks |
| `QTEMP.JSUM` or `QTEMP.DISK` not found | QTEMP aliases last only for the current job | Repeat Step 3 to recreate them |
| `MEMORY_POOL_INFO` fault rates all zero | System is lightly loaded | Fault rates of zero are valid — the health story is "all green" |
| ASP query returns multiple rows | Multiple ASPs configured | Add `WHERE ASP_NUMBER = 1` to focus on the system ASP |

---

## Conclusion

You've built a complete end-to-end Predictive Operational Health Monitor on IBM i using Bob as the analysis and reporting engine. The full diagnostic chain covered:

- **Real-time snapshots** across CPU, disk, memory pools, and jobs — the current-state baseline
- **Collection Services trend data** pulled into conversational analysis — no dedicated monitoring console needed
- **Anomaly detection** by comparing current values to a rolling sample baseline, with statistical flagging
- **Capacity forecasting** with days-to-threshold projections for the ASP
- **AI-generated health reports** — executive-ready, with the full chain from anomaly to capacity risk in one document

**Next Steps:**
- Combine with Lab 7 (Audit Journal): correlate security events with performance anomalies — a CPU spike coinciding with after-hours `OM` journal entries is a high-confidence incident indicator
- Combine with Lab 8 (PTF Impact): before a PTF maintenance window, run a health snapshot to establish the pre-change baseline; run it again post-IPL to confirm no regressions
- Tune the anomaly thresholds to your own system's normal CPU baseline
- Schedule a daily Collection Services review as a Bob task and route the summary to a Teams/Slack channel via webhook

**Resources:**
- [IBM i Collection Services — IBM Docs](https://www.ibm.com/docs/en/i/7.4?topic=services-collection)
- [QSYS2.SYSTEM_STATUS_INFO — IBM Docs](https://www.ibm.com/docs/en/i/7.4?topic=services-system-status-info)
- [QSYS2.SYSDISKSTAT — IBM Docs](https://www.ibm.com/docs/en/i/7.4?topic=services-sysdiskstat)
- [QSYS2.MEMORY_POOL_INFO — IBM Docs](https://www.ibm.com/docs/en/i/7.4?topic=services-memory-pool-info)
- [IBM i Performance Capabilities Reference](https://www.ibm.com/docs/en/i/7.4?topic=performance)

---

## Lab Instructor Guide

### Prerequisites on the IBM i Target

Start Collection Services at least 4 hours before students arrive so there is meaningful trend data (about 16 intervals at the 15-minute default):

```
STRPFRCOL COLPRF(*STANDARDP)
```

> **Note:** The default collection interval on this system is 15 minutes (900 seconds). Check with `SELECT DEFAULT_COLLECTION_INTERVAL FROM QSYS2.COLLECTION_SERVICES_INFO`. Data in `QPFRDATA` is retained for the number of days in `RETENTION_DAYS`.

### Seeding Interesting Data

No data seeding is required. The lab works on a healthy system: Step 6 reports the most unusual interval even if it is not a real problem. Start Collection Services at least 4 hours before the session so the latest collection member has enough intervals for the 2-hour window and a baseline. If the collection is restarted, a new member is created and starts empty, so Step 3 will point at the new, shorter member.

### ASP Forecasting

Step 7 projects from the current snapshot and an assumed growth rate rather than 7 days of history. Students can use:

```sql
-- SYSTEM_ASP_USED is already a percentage (e.g. 37.68)
-- SYSTEM_ASP_STORAGE is the system ASP size in KB
-- TOTAL_AUXILIARY_STORAGE is total aux storage in KB
SELECT   SYSTEM_ASP_USED                                        AS ASP_USED_PCT,
         SYSTEM_ASP_STORAGE                                     AS SYSTEM_ASP_KB,
         TOTAL_AUXILIARY_STORAGE                                AS TOTAL_AUX_KB,
         MAIN_STORAGE_SIZE                                      AS MAIN_MEM_KB
FROM     QSYS2.SYSTEM_STATUS_INFO
```

For the full ASP picture with free space in MB, use `QSYS2.ASP_INFO`:

```sql
SELECT   TOTAL_CAPACITY                                         AS TOTAL_MB,
         TOTAL_CAPACITY_AVAILABLE                               AS FREE_MB,
         (TOTAL_CAPACITY - TOTAL_CAPACITY_AVAILABLE)           AS USED_MB,
         DECIMAL((TOTAL_CAPACITY - TOTAL_CAPACITY_AVAILABLE) * 100.0
                 / NULLIF(TOTAL_CAPACITY, 0), 5, 2)            AS USED_PCT
FROM     QSYS2.ASP_INFO
WHERE    ASP_NUMBER = 1
```

Tell students to assume a growth rate of 2 GB/day and have Bob project from the current snapshot. On this system (ASP 1 at about 35%) that gives roughly 46 days to 85% and 56 days to 95% — a Low risk result that fits the healthy-system narrative.

### Resetting Between Sessions

Stop and restart the collection to clear the sample window:

```
ENDPFRCOL
STRPFRCOL COLPRF(*STANDARDP)
```
