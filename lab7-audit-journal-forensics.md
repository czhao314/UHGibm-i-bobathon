# Lab 7: Audit Journal Forensics on IBM i with IBM Bob

**Duration:** 25 minutes  
**Difficulty:** Intermediate  
**Version:** 1 — June 2026

---

## Introduction

IBM i keeps a detailed security audit trail in the system journal **QAUDJRN** in library QSYS. Every object access, profile change, failed signon, authority failure, and command execution can be captured there — but the raw journal format is notoriously hard to query. IBM i ships a set of SQL table functions under the `SYSTOOLS` schema — the `SYSTOOLS.AUDIT_JOURNAL_*` family — that surface those same entries as plain SQL result sets.

This lab teaches you to query the audit journal using **natural language with IBM Bob**, interpret the most security-critical entry types, correlate findings into a vulnerability picture, and hand off remediation actions to Bob or to an Ansible playbook. You'll also configure a lightweight **custom sysadmin agent mode** so Bob can answer "what happened on this system last night?" without you writing a single line of SQL by hand.

**Objectives:**
- Understand the `SYSTOOLS.AUDIT_JOURNAL_*` table function family and the entry types they expose
- Use Bob (IBM i Database mode) to run forensic queries in plain English
- Identify failed logon storms, authority violations, object deletions, and profile changes
- Correlate findings across entry types to build a timeline
- Feed audit findings into an Ansible remediation playbook
- Configure a Bob custom sysadmin agent mode with pre-loaded forensics context

---

## Prerequisites

### IBM i System Requirements
- IBM i 7.4 or higher (7.3 is supported but some `SYSTOOLS.AUDIT_JOURNAL_*` functions require 7.4+)
- `QAUDJRN` journal active with at minimum the following entry types enabled:
  - `*AUTFAIL` — authority failures
  - `*PGMADP` — program-adopted authority use
  - `*SIGNON` — signon/signoff events
  - `*OBJMGT` — object management (create, delete, move)
  - `*SYSMGT` — system value changes
  - `*SECURITY` — user profile changes
- User profile with `*ALLOBJ` or `*AUDIT` special authority to query audit journal data
- Mapepire server running on port 8076 (configured in Lab 4)

### Verify Audit Journal Configuration

Ask Bob's IBM i Database mode to run:

```sql
-- Check audit journal configuration
SELECT JOURNAL_LIBRARY, JOURNAL_NAME, JOURNAL_TYPE, JOURNAL_STATE,
       JOURNAL_TEXT, JOURNALED_OBJECTS, JOURNALED_FILES,
       JOURNALED_MEMBERS, JOURNALED_DATA_AREAS
FROM   QSYS2.JOURNAL_INFO
WHERE  JOURNAL_NAME = 'QAUDJRN'
```

If `QAUDJRN` is not active, ask your system administrator to run:
```
CHGSECAUD QAUDLVL(*AUTFAIL *SIGNON *OBJMGT *SYSMGT *SECURITY *PGMADP)
```

### Bob Requirements
- IBM Bob installed with IBM i Database mode configured (Lab 4)
- **IBM i Database mode** active (for SQL forensic queries)
- **IBM i Developer mode** available (for CL commands and IFS operations)

---

## The `SYSTOOLS.AUDIT_JOURNAL_*` Family

IBM i ships the following SQL table functions that wrap `QAUDJRN` entries:

| Function | Entry Type | What It Captures |
|---|---|---|
| `SYSTOOLS.AUDIT_JOURNAL_AF` | `AF` | Authority failures — someone tried to access something they couldn't |
| `SYSTOOLS.AUDIT_JOURNAL_ZR` | `ZR` | Object access — read/write to objects by authorized users |
| `SYSTOOLS.AUDIT_JOURNAL_PW` | `PW` | Invalid password / signon attempts |
| `SYSTOOLS.AUDIT_JOURNAL_CP` | `CP` | User profile changes (create, change, delete, restore) |
| `SYSTOOLS.AUDIT_JOURNAL_SV` | `SV` | System value changes |
| `SYSTOOLS.AUDIT_JOURNAL_OM` | `OM` | Object management — object created, deleted, moved, renamed |
| `SYSTOOLS.AUDIT_JOURNAL_CA` | `CA` | Command (audited CL command) executions |
| `SYSTOOLS.AUDIT_JOURNAL_DO` | `DO` | Object ownership changes |
| `SYSTOOLS.AUDIT_JOURNAL_AD` | `AD` | Adopted authority use |

Each function accepts a mandatory time range, for example:

```sql
SELECT *
FROM   TABLE(
         SYSTOOLS.AUDIT_JOURNAL_AF(
           STARTING_TIMESTAMP => CURRENT_TIMESTAMP - 24 HOURS,
           ENDING_TIMESTAMP   => CURRENT_TIMESTAMP
         )
       ) AS AF
FETCH FIRST 20 ROWS ONLY
```

---

## Part 1: Natural Language Forensic Queries with Bob

### Step 1: Activate IBM i Database Mode

- Open Bob and expand the **mode dropdown** beneath the chat input
- Select **IBM i Database**

This mode loads Bob with full knowledge of Db2 for i SQL services, including the `SYSTOOLS.AUDIT_JOURNAL_*` family. Bob can translate your security questions directly into optimised SQL and run them live against your system.

---

### Step 2: Failed Signon Investigation

Paste this into the Bob chat:

```
Query SYSTOOLS.AUDIT_JOURNAL_PW for the last 24 hours.
Show me: user profile attempted, workstation or IP address, timestamp, and how many attempts per user.
Order by attempt count descending so the worst offenders are at the top.
Then execute the query.
```

Bob will generate and execute a query similar to:

```sql
SELECT
    AUDIT_USER_NAME                        AS USER_PROFILE_ATTEMPTED,
    COALESCE(DEVICE_NAME, '(unknown)')     AS WORKSTATION_OR_IP,
    ENTRY_TIMESTAMP                        AS ATTEMPT_TIMESTAMP,
    VIOLATION_TYPE_DETAIL                  AS VIOLATION_REASON,
    COUNT(*) OVER (
        PARTITION BY AUDIT_USER_NAME
    )                                      AS ATTEMPTS_FOR_USER
FROM TABLE(
    SYSTOOLS.AUDIT_JOURNAL_PW(
        STARTING_TIMESTAMP => CURRENT TIMESTAMP - 24 HOURS
    )
) AS PW
ORDER BY ATTEMPTS_FOR_USER DESC,
         AUDIT_USER_NAME,
         ENTRY_TIMESTAMP DESC
```

**What to look for:**
- Any user with **5+ failed attempts within a short window** — potential credential stuffing
- Attempts against service accounts (`QSECOFR`, `QTCP`, application IDs) — high risk
- Unfamiliar IP addresses — may indicate external access attempts

---

### Step 3: Authority Failure Analysis

Ask Bob:

```
Show me all authority failures from SYSTOOLS.AUDIT_JOURNAL_AF in the last 48 hours.
Group by the user and the object they were denied access to.
Flag anything where the denied object is in QSYS, QGPL, or a library starting with Q.
```

Bob's generated SQL will be similar to:

```sql
SELECT   USER_NAME,
         OBJECT_LIBRARY,
         OBJECT_NAME,
         OBJECT_TYPE,
         COUNT(*)      AS FAILURE_COUNT,
         MAX(ENTRY_TIMESTAMP) AS MOST_RECENT
FROM     TABLE(
           SYSTOOLS.AUDIT_JOURNAL_AF(
             STARTING_TIMESTAMP => CURRENT_TIMESTAMP - 48 HOURS,
             ENDING_TIMESTAMP   => CURRENT_TIMESTAMP
           )
         ) AS AF
GROUP BY USER_NAME, OBJECT_LIBRARY, OBJECT_NAME, OBJECT_TYPE
ORDER BY FAILURE_COUNT DESC
```

**What to look for:**
- Repeated access denials to the same object from a single user — possible probing
- Authority failures against `QSYS`, `QGPL`, or `QUSRSYS` — attempts to access OS internals
- Failures on production data libraries — may indicate a misconfigured application profile

---

### Step 4: Object Deletion Forensics

Ask Bob:

```
Query SYSTOOLS.AUDIT_JOURNAL_OM for the last 7 days.
Filter for DELETE and RENAME operations only.
Show the object name, library, the user who did it, and the timestamp.
Sort by timestamp descending.
```

Expected SQL(Or similar):

> **Note:** Deletes and renames live in separate journal entry types. `AUDIT_JOURNAL_DO` captures object deletions; `AUDIT_JOURNAL_OM` captures moves and renames. Bob will `UNION ALL` both to give a unified view.

```sql
-- DELETE operations (AUDIT_JOURNAL_DO)
SELECT
    ENTRY_TIMESTAMP,
    'DELETE'                              AS OPERATION,
    USER_NAME,
    OBJECT_LIBRARY,
    OBJECT_NAME,
    OBJECT_TYPE,
    ENTRY_TYPE_DETAIL                     AS OPERATION_DETAIL,
    CAST(NULL AS VARCHAR(10))             AS NEW_LIBRARY,
    CAST(NULL AS VARCHAR(10))             AS NEW_NAME
FROM TABLE(
    SYSTOOLS.AUDIT_JOURNAL_DO(
        STARTING_TIMESTAMP => CURRENT TIMESTAMP - 7 DAYS
    )
) AS DO_ENTRIES

UNION ALL

-- RENAME and MOVE operations (AUDIT_JOURNAL_OM)
SELECT
    ENTRY_TIMESTAMP,
    CASE ENTRY_TYPE WHEN 'R' THEN 'RENAME' WHEN 'M' THEN 'MOVE' ELSE ENTRY_TYPE END
                                          AS OPERATION,
    USER_NAME,
    PREV_LIBRARY_NAME                     AS OBJECT_LIBRARY,
    PREV_OBJECT_NAME                      AS OBJECT_NAME,
    OBJECT_TYPE,
    ENTRY_TYPE_DETAIL                     AS OPERATION_DETAIL,
    LIBRARY_NAME                          AS NEW_LIBRARY,
    OBJECT_NAME                           AS NEW_NAME
FROM TABLE(
    SYSTOOLS.AUDIT_JOURNAL_OM(
        STARTING_TIMESTAMP => CURRENT TIMESTAMP - 7 DAYS
    )
) AS OM

ORDER BY ENTRY_TIMESTAMP DESC
```

**What to look for:**
- Production objects deleted outside of a change window
- Objects renamed to obscure their identity (a known data exfiltration step)
- Batch job users performing object management — they normally shouldn't

---

### Step 5: System Value Change Audit

Ask Bob:

```
Show all system value changes from SYSTOOLS.AUDIT_JOURNAL_SV in the last 30 days.
Include who changed it, the system value name, the old value, and the new value.
```

Expected SQL(Or similar):

```sql
SELECT   ENTRY_TIMESTAMP,
         USER_NAME,
         SYSTEM_VALUE_NAME,
         OLD_VALUE,
         NEW_VALUE
FROM     TABLE(
           SYSTOOLS.AUDIT_JOURNAL_SV(
             STARTING_TIMESTAMP => CURRENT_TIMESTAMP - 30 DAYS,
             ENDING_TIMESTAMP   => CURRENT_TIMESTAMP
           )
         ) AS SV
ORDER BY ENTRY_TIMESTAMP DESC
```

**What to look for:**
- Changes to `QSECURITY` — lowering from 50 is a serious policy violation
- Changes to `QMAXSIGN` — increasing allowed signon attempts weakens brute-force protection
- Changes to `QALWOBJRST` — allowing object restores from untrusted sources is a common attack vector
- Any change made outside of a documented change window

---

### Step 6: User Profile Change Timeline

Ask Bob:

```
Query SYSTOOLS.AUDIT_JOURNAL_CP for the last 14 days.
Show me all profile creates, changes, and deletes.
Include who performed the action and what profile was affected.
```

Expected SQL (Or similar):

```sql
SELECT   ENTRY_TIMESTAMP,
         USER_NAME          AS CHANGED_BY,
         PROFILE_NAME       AS AFFECTED_PROFILE,
         OPERATION,
         SPECIAL_AUTHORITIES,
         PASSWORD_SET
FROM     TABLE(
           SYSTOOLS.AUDIT_JOURNAL_CP(
             STARTING_TIMESTAMP => CURRENT_TIMESTAMP - 14 DAYS,
             ENDING_TIMESTAMP   => CURRENT_TIMESTAMP
           )
         ) AS CP
ORDER BY ENTRY_TIMESTAMP DESC
```

**What to look for:**
- Profiles granted `*ALLOBJ` or `*SECADM` outside of an approved provisioning process
- Profile creates from non-admin users — lateral privilege escalation
- Deleted profiles with recent job activity — could be covering tracks

---

## Part 2: Building a Timeline — Correlating Entry Types

A single entry type rarely tells the full story. A realistic attack pattern looks like:

1. **Multiple `PW` entries** — attacker guesses a password
2. **One or more `AF` entries** — attacker gains access but hits access control limits
3. **`CP` entry** — attacker or insider elevates a profile
4. **`OM` entries** — objects are deleted or moved to cover the activity

Ask Bob to build a correlated timeline:

```
I want to investigate the user SVCTEST across all audit journal entry types
for the last 48 hours. Build a unified timeline showing every PW, AF, CP, OM,
and SV event involving that user, ordered by timestamp. 
```

Bob will produce a `UNION ALL` query across multiple `SYSTOOLS.AUDIT_JOURNAL_*` functions:

```sql
-- PW: password violations attempted against or by SVCTEST
SELECT
    ENTRY_TIMESTAMP,
    'PW'                                                         AS JOURNAL_TYPE,
    AUDIT_USER_NAME                                              AS USER_NAME,
    VIOLATION_TYPE_DETAIL                                        AS DETAIL,
    COALESCE(DEVICE_NAME, '(unknown)')                           AS CONTEXT
FROM TABLE(
    SYSTOOLS.AUDIT_JOURNAL_PW(
        STARTING_TIMESTAMP => CURRENT TIMESTAMP - 48 HOURS,
        USER_NAME          => 'SVCTEST'
    )
) AS PW

UNION ALL

-- AF: authority failures by SVCTEST
SELECT
    ENTRY_TIMESTAMP,
    'AF'                                                         AS JOURNAL_TYPE,
    USER_NAME,
    VIOLATION_TYPE_DETAIL                                        AS DETAIL,
    COALESCE(OBJECT_LIBRARY, '') CONCAT '/' CONCAT
        COALESCE(OBJECT_NAME, '') CONCAT ' ' CONCAT
        COALESCE(OBJECT_TYPE, '')                                AS CONTEXT
FROM TABLE(
    SYSTOOLS.AUDIT_JOURNAL_AF(
        STARTING_TIMESTAMP => CURRENT TIMESTAMP - 48 HOURS,
        USER_NAME          => 'SVCTEST'
    )
) AS AF

UNION ALL

-- CP: profile actions performed by SVCTEST, or SVCTEST as the affected profile
SELECT
    ENTRY_TIMESTAMP,
    'CP'                                                         AS JOURNAL_TYPE,
    USER_NAME,
    ENTRY_TYPE_DETAIL                                            AS DETAIL,
    'Affected profile: ' CONCAT COALESCE(USER_PROFILE, '?')
        CONCAT ' | cmd: ' CONCAT COALESCE(COMMAND_TYPE, '?')    AS CONTEXT
FROM TABLE(
    SYSTOOLS.AUDIT_JOURNAL_CP(
        STARTING_TIMESTAMP => CURRENT TIMESTAMP - 48 HOURS
    )
) AS CP
WHERE USER_NAME = 'SVCTEST'
   OR USER_PROFILE = 'SVCTEST'

UNION ALL

-- OM: object move/rename performed by SVCTEST
SELECT
    ENTRY_TIMESTAMP,
    'OM'                                                         AS JOURNAL_TYPE,
    USER_NAME,
    ENTRY_TYPE_DETAIL                                            AS DETAIL,
    COALESCE(PREV_LIBRARY_NAME, '') CONCAT '/' CONCAT
        COALESCE(PREV_OBJECT_NAME, '') CONCAT ' -> ' CONCAT
        COALESCE(LIBRARY_NAME, '') CONCAT '/' CONCAT
        COALESCE(OBJECT_NAME, '')                                AS CONTEXT
FROM TABLE(
    SYSTOOLS.AUDIT_JOURNAL_OM(
        STARTING_TIMESTAMP => CURRENT TIMESTAMP - 48 HOURS,
        USER_NAME          => 'SVCTEST'
    )
) AS OM

UNION ALL

-- SV: system value changes made by SVCTEST
SELECT
    ENTRY_TIMESTAMP,
    'SV'                                                         AS JOURNAL_TYPE,
    USER_NAME,
    ENTRY_TYPE_DETAIL                                            AS DETAIL,
    SYSTEM_VALUE CONCAT ': ' CONCAT
        COALESCE(OLD_VALUE, '?') CONCAT ' -> ' CONCAT
        COALESCE(NEW_VALUE, '?')                                 AS CONTEXT
FROM TABLE(
    SYSTOOLS.AUDIT_JOURNAL_SV(
        STARTING_TIMESTAMP => CURRENT TIMESTAMP - 48 HOURS,
        USER_NAME          => 'SVCTEST'
    )
) AS SV

ORDER BY ENTRY_TIMESTAMP
```

## Part 3: Feeding Findings into Ansible Remediation

When the audit review surfaces a finding that requires remediation — say, a profile with excessive authority that should be restricted — ask Bob to generate an Ansible task using the Ansible Mode you created in Lab 5!

```
Based on the audit finding that SVCTEST has *ALLOBJ authority and should not,
generate an Ansible playbook task that removes *ALLOBJ from that profile using
ibm.power_ibmi.ibmi_user.
```

Bob will produce:

```yaml
- name: Remove *ALLOBJ special authority from SVCTEST
  ibm.power_ibmi.ibmi_user:
    name: SVCTEST
    special_authority:
      - '*NONE'
  register: profile_update

- name: Confirm authority change
  ibm.power_ibmi.ibmi_sql_query:
    sql: >
      SELECT USER_NAME, SPECIAL_AUTHORITIES
      FROM   QSYS2.USER_INFO
      WHERE  USER_NAME = 'SVCTEST'
  register: verify_result

- name: Display updated profile
  ansible.builtin.debug:
    var: verify_result.row
```

Save this task into `./ansible/playbooks/remediate_audit_findings.yml` alongside the Lab 6 playbooks.


## Additional Forensic Use Cases using IBM i Database Mode

### 1. Detecting Brute-Force Attempts Against a Specific Profile

```
Show me all PW entries for user QSECOFR in the last 7 days,
broken down by hour so I can see if there's a pattern.
```

### 2. Auditing Adopted Authority Usage

```
Query SYSTOOLS.AUDIT_JOURNAL_AD for the last 24 hours.
Show which programs are running under adopted authority and who called them.
Flag any non-IBM programs adopting *ALLOBJ or *SECADM.
```

### 3. After-Hours Activity Report

```
Show me all authority failures and object management events that occurred
between 10 PM and 6 AM local time over the last 30 days.
Exclude known batch job users QBATCH and QTMHHTTP.
```


---

## Common Troubleshooting

| Error | Likely Cause | Resolution |
|---|---|---|
| `SQL0443 — function not found: SYSTOOLS.AUDIT_JOURNAL_PW` | IBM i below 7.4 or PTF not applied | Apply group PTF SF99722 (Db2 for i) or upgrade to 7.4+ |
| `CPF9801 — object QAUDJRN not found in QSYS` | Audit journal not configured | Run `CHGSECAUD QAUDLVL(*AUTFAIL *SIGNON ...)` as `QSECOFR` |
| `SQL0551 — not authorized to object QAUDJRN` | User lacks audit authority | User needs `*AUDIT` or `*ALLOBJ` special authority |
| Empty result set | Entry type not being journaled | Check `QAUDLVL` system value includes the needed entry type |
| `STARTING_TIMESTAMP` parameter error | Incorrect function invocation syntax | Use named parameters: `STARTING_TIMESTAMP =>` not positional |

---

## Conclusion

You've built a complete audit journal forensics workflow on IBM i using Bob as the natural language interface. The key capabilities covered:

- **`SYSTOOLS.AUDIT_JOURNAL_*`** table functions as the SQL forensics layer over `QAUDJRN`
- **Natural language queries** via Bob's IBM i Database mode — no SQL expertise required for day-to-day investigations
- **Cross-entry-type correlation** to reconstruct user timelines and detect attack patterns
- **Ansible integration** to turn audit findings directly into remediation playbooks
- **Custom sysadmin agent mode** so Bob acts as a standing forensic assistant with the IBM i audit journal as its knowledge source

**Next Steps:**
- Schedule a daily Bob query against `AUDIT_JOURNAL_PW` and `AUDIT_JOURNAL_AF` and pipe results into a Slack/Teams channel via a webhook
- Combine Lab 6 (Ansible self-healing) with this lab's findings: audit journal identifies the problem, Ansible fixes it automatically
- Extend the `ibmi-sysadmin` mode with a custom skill that encodes your organisation's specific compliance policies and naming conventions
- Explore `SYSTOOLS.AUDIT_JOURNAL_ZR` for data access auditing on regulated libraries (HIPAA, PCI-DSS use cases)

**Resources:**
- [IBM i Security Reference — QAUDJRN entry types](https://www.ibm.com/docs/en/i/7.4?topic=security-audit-journal-entry-types)
- [Db2 for i SQL Services — SYSTOOLS schema](https://www.ibm.com/docs/en/i/7.4?topic=services-systools-schema)
- [IBM i Security — Setting the audit level (QAUDLVL)](https://www.ibm.com/docs/en/i/7.4?topic=values-qaudlvl-auditing-level)
- [CIS IBM i Benchmark](https://www.cisecurity.org/benchmark/ibm_os400)

---

## Lab Instructor Guide

Create user SVCTEST with a password. ask bob to give this user *ALLOBJ and *SECADM privileges

### Prerequisites on the IBM i Target

Ensure `QAUDJRN` is active with the entry types needed for each exercise:

```
CHGSECAUD QAUDLVL(*AUTFAIL *OBJMGT *SYSMGT *SECURITY *PGMADP)
```

> **Note:** Sign-on failures and invalid password attempts are captured under `*AUTFAIL` (AF / PW audit journal entries). `*SIGNON` is not a valid `QAUDLVL` parameter value.

Generate seeded forensic data so students have findings to discover: [done on 5250 emulator]

```
/* Seed: multiple failed signon attempts */
/* Run from a second user session, intentionally fail 5+ times for user SVCTEST */

/* Seed: authority failure */
CRTUSRPRF USRPRF(SVCTEST) PASSWORD(*NONE) SPCAUT(*NONE)
GRTOBJAUT OBJ(QGPL/QCLSRC) OBJTYPE(*FILE) USER(SVCTEST) AUT(*EXCLUDE)
/* Then attempt to access QGPL/QCLSRC as SVCTEST */

/* Seed: system value change */
CHGSYSVAL SYSVAL(QINACTMSGQ) VALUE(*ENDJOB)   /* non-compliant */
CHGSYSVAL SYSVAL(QINACTMSGQ) VALUE(*DSCJOB)   /* restore */

/* Seed: object deletion */
CRTPF FILE(QTEMP/TESTOBJ) RCDLEN(80)
DLTF FILE(QTEMP/TESTOBJ)
```

### Resetting Between Sessions

The audit journal entries are permanent (by design) — no reset needed. Simply adjust the `STARTING_TIMESTAMP` window in your demo prompts to match when you seeded the data.

### Inventory Reminder

This lab uses the IBM i Database mode connection established in Lab 4 — no Ansible inventory changes are needed for Parts 1–3. Part 4 (Ansible remediation) reuses the `./ansible/inventories/development/hosts.yml` from Lab 5.
