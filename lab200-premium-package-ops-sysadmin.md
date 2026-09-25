# Premium Package for i — Ops & System Admin Lab

> **Audience:** IBM i Operations & System Administrators
> **Mode:** IBM i Database / IBM i Developer
> **Pre-requisites:** Active IBM i connection in VS Code with Code for IBM i; IBM Bob Premium Package for i installed

## Bob for Ops — Beyond the SDLC

While the primary use case of **IBM Bob Premium Package for i (PPi)** is software development lifecycle (SDLC) — generating, compiling, testing, and modernizing IBM i code — Bob is equally valuable for **Operations and System Administration** tasks.

Operations personnel who want to understand, troubleshoot, and fix issues on their systems can leverage Bob as a knowledgeable assistant. The Premium Package for i enriches Bob with a deep IBM i knowledge base — backed by IBM i documentation through RAG (Retrieval-Augmented Generation) — and a full set of MCP tools that give Bob direct, live access to the system: executing SQL, running CL commands, reading job logs, writing IFS files, and more.

Beyond IBM i itself, Bob can be a relevant assistant for **Power Systems operations in general** — covering AIX, Linux on Power, IBM i, HMC, and VIOS. The broader the context you give Bob (custom skills, modes, and tools tailored to your infrastructure), the more effective it becomes. Purpose-built custom modes and skills for HMC REST API operations, VIOS management, or AIX diagnostics can take Bob well beyond its defaults. 

> These labs are an **introduction**. They demonstrate what is possible out of the box with the Premium Package for i. Building dedicated skills, modes, and tooling for your specific Ops workflows will unlock significantly more value.

---

| # | Exercise | Bob Tools & Skills | IBM i Service / Scope |
|---|---|---|---|
| 1.1 | PTF Status Report | `execute_sql_statement`, `db2-sql-primer` | `QSYS2.PTF_INFO`, `QSYS2.GROUP_PTF_INFO` |
| 1.2 | Security Audit | `execute_sql_statement`, `db2-security-best-practices` | `QSYS2.USER_INFO`, `QSYS2.OBJECT_PRIVILEGES` |
| 1.3 | Save Report to IFS | `write_stream_file`, `execute_pase_command` | IFS home directory |
| 2.1 | Top CPU Jobs | `execute_sql_statement`, `db2-sql-primer` | `QSYS2.ACTIVE_JOB_INFO` |
| 2.2 | Job Investigation | `execute_sql_statement`, `read_stream_file`, `search_ifs` | `QSYS2.JOBLOG_INFO`, FFDC logs |
| 2.3 | Performance Collection | `execute_sql_statement`, `execute_cl_command` | `QSYS2.COLLECTION_SERVICES_INFO` |
| 3.1 | Top SQL by CPU | `execute_sql_statement`, `db2-sql-performance-analysis` | `ACTIVE_JOB_INFO`, Plan Cache |
| 3.2 | Index Recommendations | `execute_sql_statement`, `db2-sql-index-strategy` | `QSYS2.SYSIXADV` |
| 4 | PTF Automation with Ansible | Custom mode `ansible-for-i`, `execute_pase_command` | Ansible `ibm.power_ibmi` collection |
| 5 | HMC Operations with Bob | Bob Agent mode, HMC REST API, custom `hmc-operator` mode | HMC / Power Systems infrastructure |

---

## Exercise 1 — Security & PTF Reporting

### Context

IBM i system administrators regularly need to audit PTF (Program Temporary Fix) levels and security posture. Bob can generate these reports instantly using Db2 Services and system commands — no green screen required.

### 1.1 PTF Status Report

Ask Bob:

> *"Generate a PTF status report for my IBM i system. Show me missing PTFs, their descriptions, and whether they require an IPL."*

**Premium Package tools & skills:** `execute_sql_statement` · skill `db2-sql-primer` · `QSYS2.PTF_INFO`, `QSYS2.GROUP_PTF_INFO`

**Expected results:**
- PTFs ranked by status (`NOT APPLIED`, `APPLY PENDING`, `APPLIED`) with IPL-required flags
- Group PTF levels (e.g., SF99xxx Db2, SF99722 Java)

**Sample prompt refinements:**
- *"Which PTFs are loaded but not yet applied?"*
- *"Show me the current Group PTF levels for Db2 and Java."*
- *"Are there any PTFs that require an IPL to take effect?"*

---

### 1.2 Security Audit Report

Ask Bob:

> *"Run a security audit on my IBM i. Check for user profiles with default passwords, profiles with *ALLOBJ authority, and any publicly accessible sensitive objects."*

**Premium Package tools & skills:** `execute_sql_statement` · skill `db2-security-best-practices` · `QSYS2.USER_INFO`, `QSYS2.OBJECT_PRIVILEGES`

**Expected results:**
- User profiles with expired or default passwords, inactive for 90+ days
- Profiles holding `*ALLOBJ`, `*SECADM`, or `*JOBCTL` special authorities
- Objects with `*PUBLIC *CHANGE` or `*PUBLIC *ALL` authority flagged as risks

**Sample prompt refinements:**
- *"Which user profiles have not logged in for more than 90 days?"*
- *"Show me all profiles with *ALLOBJ authority that are not IBM-supplied."*
- *"Are there any objects in production libraries accessible to *PUBLIC?"*

---

### 1.3 Generate a Markdown Report

Ask Bob:

> *"Write a concise Markdown security and PTF summary report and save it to the IFS under my home directory."*

**Premium Package tools:** `write_stream_file` · `execute_pase_command`

**Expected result:** A `.md` file saved to `/home/<your_user>/` containing PTF gap and security findings tables, ready to share with your team.

---

## Exercise 2 — CPU Troubleshooting: Investigating a Hot Job

### Context

A user reports sluggish response times. One job is consuming a disproportionate amount of CPU. Bob identifies it, pulls its job log, and diagnoses root causes — all in natural language.

### 2.1 Identify the Top CPU Consumers

Ask Bob:

> *"Show me the top 10 jobs consuming the most CPU on this system."*

**Premium Package tools & skills:** `execute_sql_statement` · skill `db2-sql-primer` · `QSYS2.ACTIVE_JOB_INFO`

**Expected results:**
- Ranked active jobs with `CPU_TIME`, `THREAD_COUNT`, `TEMPORARY_STORAGE`, job name/user/type/status

> 💡 `CPU_TIME` is cumulative since job start. Check `ELAPSED_CPU_PERCENTAGE` for real-time activity.

---

### 2.2 Drill Down on a Suspicious Job

Pick the top CPU-consuming non-system job. Ask Bob:

> *"What is going on with job [JOB_NAME]? Investigate its logs, runtime context, and give me recommendations."*

**Premium Package tools & skills:** `execute_sql_statement` · `read_stream_file` · `search_ifs` · skill `db2-sql-debugging` · `QSYS2.JOBLOG_INFO`

**Expected results:**

| Area | What to look for |
|---|---|
| **Runtime** | Language/framework, JVM version, server type |
| **Job details** | Thread count, memory, subsystem, pool |
| **Job log errors** | Escape messages (`*ESCAPE`), FFDC incidents |
| **Recommendations** | Concrete fixes ranked by priority |

---

### 2.3 Check if a Performance Collection is Running

Ask Bob:

> *"Is there a performance data collection running on this system?"*

**Premium Package tools:** `execute_sql_statement` · `execute_cl_command` · `QSYS2.COLLECTION_SERVICES_INFO`

**Expected results:**
- Active collection name, profile (`*STANDARDP`, `*EXTD2`), start time, and interval
- Categories collected (`*SYSLVL`, `*DISK`, `*JOBMI`, `*JOBOS`)

> 💡 Collection Services data is stored as `*MGTCOL` objects in `QPFRDATA`.

---

## Exercise 3 — Database Troubleshooting: Top SQL by CPU

### Context

Once a hot job is identified, Bob queries the Db2 plan cache to surface the top SQL offenders and recommend index improvements.

### 3.1 Top SQL Statements by CPU

Ask Bob:

> *"Which SQL queries have consumed the most CPU over the last 10 minutes?"*

**Premium Package tools & skills:** `execute_sql_statement` · skill `db2-sql-performance-analysis` · `QSYS2.ACTIVE_JOB_INFO` (with `DETAILED_INFO => 'ALL'`), `QSYS2.DUMP_PLAN_CACHE_TOPN`

**Expected results:**
- Ranked SQL statements with job name, CPU time, I/O counts, statement status (`ACTIVE`, `COMPLETE`)
- Actual SQL text (parameterized with `?` for literals)

---

### 3.2 Interpret & Tune

For each top statement, ask Bob:

> *"This query is doing a full table scan with ORDER BY on an unindexed column. What do you recommend?"*

**Premium Package tools & skills:** `execute_sql_statement` · skills `db2-sql-optimization` · `db2-index-strategy` · `QSYS2.SYSIXADV`

**Expected results:**

| Finding | Recommendation |
|---|---|
| `ORDER BY` on unindexed column | Create an index on the sort column |
| Large JOIN with no index | Review Index Advisor suggestions in `QSYS2.SYSIXADV` |
| High `ELAPSED_SYNC_DISK_IO` | Review disk tier, consider result caching |
| Repeated identical statements | Enable statement caching in the connection pool |

---

## Exercise 4 — PTF Automation with Ansible

### Context

Bob's **Premium Package for i** supports custom modes and the `execute_pase_command` tool, which makes it a natural fit for orchestrating Ansible automation directly from your IDE. This exercise walks through using Bob's `ansible-for-i` custom mode to build a PTF management assistant powered by Ansible and the `ibm.power_ibmi` collection.

> 📘 **Full lab instructions:** [Lab 5 — Building a PTF Management Assistant on IBM i with IBM Bob & Ansible](https://github.com/bmarolleau/IBM-i-Application-Modernization-with-Bob/blob/main/lab5-ansible-ptf-management.md)

### 4.1 Configure the Ansible for i Custom Mode

Follow the lab guide to add the `ansible-for-i` custom mode to your `.bob/custom_modes.yaml`. This mode gives Bob deep knowledge of:
- IBM i-specific Ansible modules (`ibmi_fix`, `ibmi_sql_query`, `ibmi_object_authority`)
- PTF lifecycle and system currency checks
- Jinja2 templating and playbook best practices

**Premium Package capability used:** Custom modes (`.bob/custom_modes.yaml`) — see [Modes](https://bob.ibm.com/docs/ide/premium-packages/bob-for-i/modes)

### 4.2 Generate PTF Compliance Playbooks

Switch to the `ansible-for-i` mode, then ask Bob:

> *"Create an Ansible playbook that checks PTF currency on my IBM i and generates a compliance report."*

**Premium Package tools used:** `execute_pase_command` (to run `ansible-playbook`), `write_stream_file` (to save playbooks to IFS)

**Expected results:**
- A working Ansible playbook using `ibm.power_ibmi` modules
- PTF status queried via `ibmi_sql_query` against `QSYS2.PTF_INFO`
- A formatted Markdown compliance report generated and saved to the IFS

### 4.3 Automate and Schedule

Ask Bob:

> *"How can I schedule this PTF compliance check to run nightly and email the report?"*

**Expected results:**
- A CL command or PASE cron job to schedule the playbook
- Guidance on using `SNDDST` or SMTP to distribute the report

---

## Exercise 5 — HMC Operations with Bob

### Context

IBM i often runs as an LPAR on IBM Power Systems hardware managed by an HMC (Hardware Management Console). While the previous exercises focused on IBM i internals, Bob can also assist with the **infrastructure layer** — querying LPAR states, checking VIOS health, investigating events, and performing dynamic resource operations — all through the HMC REST API.

This exercise points to a dedicated lab that covers HMC operations from first authentication through troubleshooting and DLPAR, using Bob in its default Agent mode. It also shows how a custom `hmc-operator` mode and purpose-built skills can further sharpen Bob's behaviour for Power Systems infrastructure work.

> 📘 **Full lab:** [HMC Operations with IBM Bob](./lab201-hmc.md)

---

> 💬 **Tip:** All exercises use IBM Bob **Premium Package for i** capabilities — the **IBM i Database** and **IBM i Developer** modes, purpose-built tools (`execute_sql_statement`, `execute_cl_command`, `execute_pase_command`, `read_stream_file`, `write_stream_file`), and auto-activated skills (`db2-sql-performance-analysis`, `db2-security-best-practices`, `db2-index-strategy`). Full reference: [IBM Bob Premium Package for i](https://bob.ibm.com/docs/ide/premium-packages/bob-for-i/bob-for-i-index).
