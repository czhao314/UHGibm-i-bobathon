# Lab 9: Predictive Operational Health Monitoring on IBM i with IBM Bob

**Duration:** 25 minutes  
**Difficulty:** Intermediate  
**Version:** 1 — June 2026

---

## Introduction

Reactive troubleshooting — waiting for a user to report slowness, then hunting for the hot job — is the most common IBM i operational pattern. But the data to catch problems *before* users notice has always been there: IBM i continuously exposes system metrics through `QSYS2` SQL services and captures multi-interval performance history via Collection Services. The gap has been the effort required to query, interpret, and act on that data.

This lab turns IBM Bob into a **Predictive Operational Health Monitor**. Using Bob in **IBM i Database mode**, you'll establish a current-state baseline across CPU, disk, memory pools, and active jobs; compare snapshots across time to detect trends; identify resources approaching saturation; and have Bob produce a capacity forecast and a prioritised health report. You'll also configure a **custom health monitor agent mode** so any team member can ask "how is this system going to look next week?" and get a data-backed answer.

**Objectives:**
- Take and interpret real-time health snapshots using `QSYS2.SYSTEM_STATUS_INFO`, `QSYS2.SYSDISKSTAT`, and `QSYS2.MEMORY_POOL_INFO`
- Read Collection Services history from `QSYS2.COLLECTION_SERVICES_INFO` and `QPFRDATA`
- Detect anomalies by comparing current metrics against a rolling baseline
- Identify resources trending toward saturation and forecast when thresholds will be breached
- Have Bob generate a prioritised health report with risk ratings and recommended actions
- Configure a Bob custom health monitor agent mode for standing operational use

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
STRPFRCOL COLLNAME(*GEN) INTERVAL(15) TYPE(*STANDARDP)
```

> **Note:** `*STANDARDP` captures system-level metrics (`*SYSLVL`, `*DISK`, `*JOBMI`) at 15-minute intervals — sufficient for trend analysis. For this lab, even a collection started a few minutes before the exercises will generate enough data to work with.

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
| `QSYS2.JOBLOG_INFO` | Full job message log — escape messages, FFDC references, runtime errors |

---

## Part 1: Current-State Health Snapshot

### Step 1: Activate IBM i Database Mode

- Expand the **mode dropdown** beneath the Bob chat input
- Select **IBM i Database**

### Step 2: Full System Health Snapshot

Start with a single comprehensive prompt to establish the current baseline:

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

### Step 3: Identify the Top Resource Consumers Right Now

```
Show me the top 10 active jobs by current elapsed CPU percentage.
For each job, also show thread count, temporary storage used, and current wait reason.
Flag any job over 20% elapsed CPU as a potential concern.
```

Bob queries `QSYS2.ACTIVE_JOB_INFO` with `ELAPSED_CPU_PERCENTAGE` ordered descending. This gives you the live picture to compare against the pool and disk metrics from Step 2.

---

## Part 2: Trend Analysis with Collection Services

A single snapshot tells you the state *now*. Trends tell you where the system is *going*.

### Step 4: Read Collection Services History

```
Query QSYS2.COLLECTION_SERVICES_INFO to show me the active collection name,
profile, and start time. Then query QPFRDATA.QAPMJSUM for system-level CPU
samples over the last 2 hours. Sum all job-group buckets per interval to get
the system total. Show timestamp, CPU ms per second, and interval duration.
I want to see whether CPU is trending up, flat, or down.
```

Bob will query the Collection Services `QPFRDATA` library directly — `SYSTOOLS.METRICS_*` views are not available on this system:

```sql
-- System-level CPU per 15-minute interval
-- Sum all JSCBKT buckets per interval to get the full-system total
SELECT   DATETIME                                               AS INTERVAL_TS,
         INTSEC                                                 AS INTERVAL_SEC,
         SUM(JSCPU)                                            AS TOTAL_CPU_MS,
         DECIMAL(SUM(JSCPU) / NULLIF(INTSEC, 0), 12, 2)       AS CPU_MS_PER_SEC
FROM     QPFRDATA.QAPMJSUM
WHERE    DATETIME >= CURRENT_TIMESTAMP - 2 HOURS
GROUP BY DATETIME, INTSEC
ORDER BY DATETIME
```

> **Tip:** `JSCPU` is total CPU milliseconds consumed by all jobs in the interval. Dividing by `INTSEC` normalises across any variable-length intervals. If only 1–2 intervals have been collected (collection just started), widen the window to `CURRENT_TIMESTAMP - 30 MINUTES` and note that the trend window is short.

### Step 5: Detect CPU Trend Direction

```
From the CPU samples we just retrieved, calculate using window arithmatic:
1. The average CPU over the full window
2. The average CPU for the first half vs the second half of the window
3. Whether the trend is rising (second half > first half by more than 5%), falling, or flat
4. The peak CPU sample and when it occurred
```

Bob will apply window arithmetic to the sample set and classify the trend — this is the core of anomaly detection without requiring a dedicated monitoring tool.

### Step 6: Disk I/O Trend

```
From Collection Services data, show me disk I/O request rates and average
response times sampled over the last 2 hours. Flag any interval where
average response time exceeded 20ms — that threshold indicates I/O pressure.
```

Bob will query `QPFRDATA.QAPMDISK` — `SYSTOOLS.METRICS_DISK` does not exist on this system:

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
FROM     QPFRDATA.QAPMDISK
WHERE    DATETIME >= CURRENT_TIMESTAMP - 2 HOURS
ORDER BY DATETIME, DSARM
```

---

## Part 3: Anomaly Detection

### Step 7: Compare Current Metrics to the Sampled Baseline

```
Using the Collection Services samples from QPFRDATA.QAPMJSUM and QPFRDATA.QAPMDISK
over the last 2 hours as a baseline, compare the current snapshot values to that baseline.

For each metric (CPU ms/sec, disk I/O ops/sec, pool fault rate):
- Show the baseline average across all sampled intervals
- Show the current value from the most recent interval
- Calculate the deviation (current minus baseline average)
- Flag as ANOMALY if the current value is more than 2 standard deviations above
  the baseline average, or more than 25% above it in absolute terms
```

Bob will calculate rolling statistics across the sample set and compare point-in-time values — surfacing genuine deviations rather than normal variance. Example output structure Bob will produce:

| Metric | Baseline Avg | Current | Deviation | Status |
|---|---|---|---|---|
| CPU Utilisation % | 34.2 | 71.5 | +37.3 pts | ⚠️ ANOMALY |
| Active Jobs | 412 | 418 | +6 | Normal |
| Disk Arm 1 Utilisation % | 28.1 | 29.4 | +1.3 pts | Normal |
| *BASE Pool Faults/sec | 0.3 | 14.7 | +14.4 | ⚠️ ANOMALY |

### Step 8: Root-Cause the Anomalies

For each flagged anomaly, ask Bob to correlate with the active job picture:

```
CPU is anomalously high right now compared to the 2-hour baseline.
Cross-reference with the active job snapshot — which jobs started or
significantly increased their CPU consumption within the last 30 minutes?
```

Bob will join `ACTIVE_JOB_INFO` job start times against the baseline window to identify new or escalating jobs as the likely cause. Once a specific job is identified, move to Step 9 to diagnose it in depth.

### Step 9: Deep Job Investigation

The anomaly pointed you at a specific job. Now find out exactly what it is doing and why.

```
The anomaly detection flagged job [JOB_NAME] as the likely cause of the CPU spike.
Investigate this job fully:
1. Pull its job log — show all escape messages, warnings, and any FFDC references
2. Show its current runtime context: thread count, memory use, subsystem, pool,
   and how long it has been running
3. If it is a PASE process, check the IFS for its executable path, working
   directory, and any open log files
4. Based on what you find, give me no more than two recommendations.
Distinguish facts from inferences.
```

Bob will combine `QSYS2.JOBLOG_INFO`, `QSYS2.ACTIVE_JOB_INFO`, and `search_ifs` to build a complete picture of the job. The `QSYS2.JOBLOG_INFO` query it uses:

```sql
SELECT   MESSAGE_TIMESTAMP,
         MESSAGE_TYPE,
         MESSAGE_ID,
         MESSAGE_TEXT,
         MESSAGE_SECOND_LEVEL_TEXT
FROM     QSYS2.JOBLOG_INFO
WHERE    JOB_NAME = '[JOB_NAME]'
  AND    MESSAGE_TYPE IN ('*ESCAPE', '*DIAGNOSTIC', '*COMPLETION')
ORDER BY MESSAGE_TIMESTAMP DESC
FETCH FIRST 50 ROWS ONLY
```

**What to look for in the job log:**

| Message pattern | Likely meaning |
|---|---|
| `MCH` prefix messages | Machine check — memory or pointer errors |
| `SQL` prefix messages | Db2 errors — query failures, lock waits, SQL0501 cursor issues |
| `CPF` prefix escape messages | OS-level errors — authority failures, object not found |
| References to `/tmp/` or `/var/log/` IFS paths | PASE application — check those files for stack traces |
| `FFDC` in message text | Java/JVM crash — IFS dump file generated, Bob can read it |

> **Key insight:** The job log is the bridge between the trending anomaly (CPU spiked at 13:58) and the root cause (a SQL cursor loop that was never closed). Without it, you'd have the symptom but not the fix.

---

## Part 4: Capacity Forecasting

### Step 10: ASP Usage Forecast

ASP (Auxiliary Storage Pool) usage grows monotonically unless objects are deleted or saved-and-freed. It's the most forecastable metric on the system.

```
Query QSYS2.SYSTEM_STATUS_INFO for current ASP usage.
Then query Collection Services for ASP usage samples over the last 7 days.
Calculate the average daily growth rate in GB.
Project forward: at the current growth rate, how many days until ASP reaches
85%? And how many days until it reaches 95%?
Flag if either threshold is within 30 days.
```

Bob will fit a linear projection to the ASP samples:

```sql
-- Daily ASP usage from QSYS2.ASP_INFO (current snapshot)
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

For the growth trend, use the LPAR-level disk capacity from Collection Services history:

```sql
-- Daily ASP capacity snapshots from QPFRDATA.QAPMLPAR
-- LPCAP = total disk capacity bytes, LPAVL = available bytes
SELECT   DATE(DATETIME)                                             AS SAMPLE_DATE,
         MIN(LPAVL)     / 1073741824.0                             AS MIN_FREE_GB,
         MAX(LPAVL)     / 1073741824.0                             AS MAX_FREE_GB,
         (MAX(LPCAP) - MIN(LPAVL)) / 1073741824.0                 AS USED_GB
FROM     QPFRDATA.QAPMLPAR
WHERE    DATETIME >= CURRENT_TIMESTAMP - 7 DAYS
GROUP BY DATE(DATETIME)
ORDER BY SAMPLE_DATE
```

> **Note:** If `QPFRDATA.QAPMLPAR` has no rows (the `*LPAR` category is not being collected), use the current `QSYS2.ASP_INFO` snapshot combined with a hypothetical growth rate, or enable the `*LPAR` category with `CHGPFRCOL CGTLIST(*ADD *LPAR)`.

Then reason over the trend:
> *"ASP is currently at 73.4% (892 GB of 1,216 GB). Over the last 7 days it grew by an average of 4.2 GB/day. At that rate: 85% threshold (1,034 GB) will be reached in approximately **34 days**. 95% threshold (1,155 GB) will be reached in approximately **63 days**. The 85% threshold is within the 30-day warning window — **flag as Medium risk**."*

### Step 11: Memory Pool Sizing Forecast

```
For each memory pool with a fault rate above 1 fault/second in the Collection
Services data, show the current pool size, the defined (minimum) size, and
calculate how much additional memory would be needed to bring the fault rate
to near zero based on IBM's general guidance of 10% headroom above working set.
```

Bob will reason against pool fault rates and IBM's documented pool-sizing heuristics to recommend concrete `CHGSHRPOOL` or `WRKSHRPOOL` adjustments.

---

## Part 5: Health Report Generation

### Step 12: Consolidated Health Report

```
Based on everything we've found — the current snapshot, trend analysis,
anomaly detections, job investigation, SQL diagnosis, and capacity forecasts —
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

Format as Markdown.
```

> **Tip:** Ask Bob to save the report to the IFS once generated: *"Save that report to `/home/ITZUSER/HEALTHREPORTS/health_report_<today's date>_<yourname>.md`"*

---

## Common Troubleshooting

| Error | Likely Cause | Resolution |
|---|---|---|
| `QSYS2.DISK_STATISTICS` not found | This view does not exist — correct name is `QSYS2.SYSDISKSTAT` | Replace all references with `QSYS2.SYSDISKSTAT` |
| `QSYS2.COLLECTION_SERVICES_INFO` returns no rows | No collection running | Run `STRPFRCOL COLLNAME(*GEN) TYPE(*STANDARDP)` |
| Collection data only covers a few minutes | Collection just started | Wait 2–3 intervals (30–45 mins at 15-min interval) or reduce interval to 5 mins for lab: `STRPFRCOL COLLNAME(*GEN) INTERVAL(5)` |
| `QSYS2.SYSDISKSTAT` columns `ELAPSED_PERCENT_BUSY` / `ELAPSED_IO_REQUESTS` are NULL | Disk is SAN/virtual (e.g. IBM 2145) — hypervisor does not expose arm-level I/O counters | Use `PERCENT_USED` for storage utilisation; arm-level busy % is not available for virtual disks |
| `QPFRDATA.QAPMLPAR` returns no rows | `*LPAR` category not enabled in Collection Services | Run `CHGPFRCOL CGTLIST(*ADD *LPAR)` to start collecting LPAR-level data |
| `MEMORY_POOL_INFO` fault rates all zero | System is lightly loaded | Fault rates of zero are valid — the health story is "all green" |
| ASP query returns multiple rows | Multiple ASPs configured | Add `WHERE ASP_NUMBER = 1` to focus on the system ASP |

---

## Conclusion

You've built a complete end-to-end Predictive Operational Health Monitor on IBM i using Bob as the analysis and reporting engine. The full diagnostic chain covered:

- **Real-time snapshots** across CPU, disk, memory pools, and jobs — the current-state baseline
- **Collection Services trend data** pulled into conversational analysis — no dedicated monitoring console needed
- **Anomaly detection** by comparing current values to a rolling sample baseline, with statistical flagging
- **Job drill-down** — once an anomaly is attributed to a job, `QSYS2.JOBLOG_INFO` and IFS inspection identify the root cause without leaving Bob
- **Capacity forecasting** with days-to-threshold projections for ASP and memory pools
- **AI-generated health reports** — executive-ready, with the full chain from anomaly to capacity risk in one document

**Next Steps:**
- Combine with Lab 7 (Audit Journal): correlate security events with performance anomalies — a CPU spike coinciding with after-hours `OM` journal entries is a high-confidence incident indicator
- Combine with Lab 8 (PTF Impact): before a PTF maintenance window, run a health snapshot to establish the pre-change baseline; run it again post-IPL to confirm no regressions
- Extend the `ibmi-health-monitor` mode with organisation-specific thresholds (your system's normal CPU baseline may be 60%, not 34%)
- Schedule a daily Collection Services review as a Bob task and route the summary to a Teams/Slack channel via webhook

**Resources:**
- [IBM i Collection Services — IBM Docs](https://www.ibm.com/docs/en/i/7.4?topic=services-collection)
- [QSYS2.SYSTEM_STATUS_INFO — IBM Docs](https://www.ibm.com/docs/en/i/7.4?topic=services-system-status-info)
- [QSYS2.SYSDISKSTAT — IBM Docs](https://www.ibm.com/docs/en/i/7.4?topic=services-sysdiskstat)
- [QSYS2.MEMORY_POOL_INFO — IBM Docs](https://www.ibm.com/docs/en/i/7.4?topic=services-memory-pool-info)
- [QSYS2.JOBLOG_INFO — IBM Docs](https://www.ibm.com/docs/en/i/7.4?topic=services-joblog-info)
- [IBM i Performance Capabilities Reference](https://www.ibm.com/docs/en/i/7.4?topic=performance)

---

## Lab Instructor Guide

### Prerequisites on the IBM i Target

Start Collection Services at least 30 minutes before students arrive so there is meaningful trend data:

```
STRPFRCOL COLPRF(*STANDARDP)
```

> **Note:** The collection interval is configured in Collection Services via `CFGPFRCOL` or IBM Navigator for i. The default interval is 5 minutes, which gives students 6 data points in 30 minutes — enough to demonstrate trending.

### Seeding Interesting Data

To give students an anomaly to find, run a CPU-intensive query a few minutes before the session:

```sql
-- Run this to spike CPU temporarily (safe on any IBM i)
SELECT COUNT(*)
FROM TABLE(QSYS2.OBJECT_STATISTICS('*ALL', '*PGM')) AS obj_stats
```

Or start a CPU-consuming job via CL:
```
SBMJOB CMD(CALL PGM(QSYS/QCMD)) JOBD(QBATCH) JOBQ(QBATCH)
```

### ASP Forecasting Without 7 Days of Data

If Collection Services was just started, students can still do ASP forecasting using:

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

Tell students to assume a hypothetical growth rate of 5 GB/day and have Bob project from the current snapshot — the forecasting logic is the same, the data window is just shorter.

### Resetting Between Sessions

Stop and restart the collection to clear the sample window:

```
ENDPFRCOL
STRPFRCOL COLPRF(*STANDARDP)
```
