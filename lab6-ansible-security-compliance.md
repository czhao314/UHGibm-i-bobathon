# Lab 6: Automated Security Auditing & Active Remediation on IBM i with IBM Bob & Ansible

**Duration:** 25 minutes  
**Difficulty:** Advanced-Beginner to Intermediate   
**Version:** 2 - September 2026


## Introduction

While passive currency checking (Lab 5) is essential for software maintenance, establishing an active security baseline is paramount for system integrity. Static reports can drift quickly; automated auditing combined with active self-healing remediation ensures your servers remain aligned with security policies.

This lab guides you through leveraging **IBM Bob** and the **IBM i Ansible Collection** to audit system configurations against standard security guidelines (such as the CIS IBM i Benchmark) and automatically remediate vulnerabilities. You'll learn to check and enforce system values, audit user profile compliance, restrict object authorities, and use dynamic privilege elevation.

**Objectives:**
- Audit critical IBM i system values (e.g., `QSECURITY`, `QINACTMSGQ`, `QMAXSIGN`, `QALWOBJRST`)
- Audit user profiles for default password vulnerabilities and excessive privileges
- Inspect and restrict public authorities on a critical application library using `ibmi_object_authority`
- Execute dynamic "self-healing" remediation to bring non-compliant systems into policy compliance automatically

---

## Prerequisites

This lab builds directly on top of the environment configured in **Lab 5**. Ensure the following are active:

### IBM i System Requirements
- IBM i 7.3 or higher
- A user profile with `*ALLOBJ` and `*SECADM` authorities (necessary for altering security values and user profiles)
- Python 3.9 installed on the target IBM i system (`/QOpenSys/pkgs/bin/python3.9`)
- Public SSH key-based authentication successfully configured (completed in Lab 5)

### Bob Workstation Requirements
- Ansible 2.9+ installed and configured
- `ibm.power_ibmi:3.3.0` collection installed — **pin the version**, later versions switch SQL drivers and break on IBM i PASE sessions:
  ```bash
  ansible-galaxy collection install 'ibm.power_ibmi:3.3.0' --force
  ```
- Project structure `./ansible` (created in Lab 5) with `inventories/development/hosts.yml`

Verify your setup:
```bash
# Confirm collection version is 3.3.0
ansible-galaxy collection list | grep ibm.power_ibmi

# Ping the target system
ansible ibmi_systems -i ansible/inventories/development/hosts.yml -m ansible.builtin.ping
```

---

## Lab Environment Setup (Run Before Students Arrive)

> **Instructor step:** Run this once to create a separate non-compliant baseline for each of up to 20 students (`01`–`20`). Each student gets their own library `MYAPP_DB<NN>` and user profile `LAB6USR<NN>`, so students can audit and remediate at the same time on the shared system without affecting each other. Each student is told their number and passes it as `-e student=<NN>`.

```bash
for n in $(seq -w 1 20); do
  # Student library (CRTLIB fails harmlessly if it already exists)
  ansible ibmi_systems -i ansible/inventories/development/hosts.yml \
    -m ibm.power_ibmi.ibmi_cl_command \
    -a "{\"cmd\":\"CRTLIB LIB(MYAPP_DB${n}) TEXT('Lab 6 Student ${n}')\"}" || true

  # Non-compliant: *PUBLIC has *CHANGE
  ansible ibmi_systems -i ansible/inventories/development/hosts.yml \
    -m ibm.power_ibmi.ibmi_object_authority \
    -a "object_name=MYAPP_DB${n} object_type=*LIB user=*PUBLIC operation=grant authority=*CHANGE"

  # Student profile with no password (CRTUSRPRF fails harmlessly if it already exists)
  ansible ibmi_systems -i ansible/inventories/development/hosts.yml \
    -m ibm.power_ibmi.ibmi_cl_command \
    -a "{\"cmd\":\"CRTUSRPRF USRPRF(LAB6USR${n}) PASSWORD(*NONE) STATUS(*ENABLED) TEXT('Lab 6 Student ${n}')\"}" || true

  # Non-compliant: profile is enabled
  ansible ibmi_systems -i ansible/inventories/development/hosts.yml \
    -m ibm.power_ibmi.ibmi_cl_command \
    -a "cmd='CHGUSRPRF USRPRF(LAB6USR${n}) STATUS(*ENABLED)'"
done
```

> System values (`QINACTMSGQ`, `QALWOBJRST`, ...) are system-wide, so the setup does **not** change them. Students only audit them.

---

## Custom Mode Configuration

We will continue using the `ansible-for-i` custom mode defined in `./.bob/custom_modes.yaml`.

If you haven't set it up yet, refer to the Custom Mode Configuration section in Lab 5.

---

## Security Playbook Creation

### Setup: Add Your Library to the User Library List

In the **IBM i** extension on the sidebar, go to **User Library List** → click the **+** icon → type `MYAPP_DB<NN>` (replace `<NN>` with your student number, e.g. `MYAPP_DB07`) → press Enter.

### Part 1: Using Bob to Generate the Playbooks

**Step 1: Activate the mode**
- Expand the modes dropdown beneath the chat input
- Select `ℹ️ Ansible for i`

**Step 2: Have Bob check the module parameters first**

Before generating anything, ask Bob to look up the real parameters in the installed collection. This avoids the most common mistakes (wrong parameter names, using a read-only module to change something). Paste this prompt into the Bob chat:

```
Before we build anything, I want to make sure we use the right module parameters. First activate
the Python virtual environment for this project (source .venv/bin/activate) and keep using it for
every Ansible command in this lab, since that's where Ansible and the ibm.power_ibmi collection are
installed. Then use ansible-doc to look up ibm.power_ibmi.ibmi_sysval, ibm.power_ibmi.ibmi_user_compliance_check,
ibm.power_ibmi.ibmi_object_authority and ibm.power_ibmi.ibmi_cl_command. For each one, tell me
the required parameters and what they're called, and whether the module can read, change, or
both. Also confirm the installed version of the ibm.power_ibmi collection is 3.3.0.
```

Review Bob's answer before continuing. Bob should activate the `.venv` first (your terminal prompt will show `(.venv)`). You should see that `ibmi_sysval` takes a `sysvalue` list and is read-only, `ibmi_user_compliance_check` takes `users` and `fields`, and `ibmi_object_authority` supports the `display` operation.

**Step 3: Ask Bob to generate the security compliance project**

Now paste the following prompt into the Bob chat. Replace `07` with your student number:

```
Now build the security compliance project using what you just looked up.

I'm student 07 and I want to build a small security compliance project for our shared IBM i
system, using the ibm.power_ibmi collection (version 3.3.0).

Create two playbooks, audit_security.yml and remediate_security.yml. Both should take my student
number as an extra variable (-e student=07). My objects are the library MYAPP_DB07 and the user
profile LAB6USR07. The system is shared, so please don't change any system values or touch
anything that belongs to other students.

The audit should check the QSECURITY, QINACTMSGQ, QMAXSIGN and QALWOBJRST system values (report
only), whether my LAB6USR07 profile is disabled, and what public authority is set on my
MYAPP_DB07 library. Have it write a JSON compliance scorecard on my local machine to
./ansible/reports/security_compliance_report.json, using a Jinja2 template at
./ansible/templates/security_report.json.j2.

The remediation should disable my profile and lock down my library so *PUBLIC has no access.
```

**Step 4: Review Bob's generated files**

Bob will create the following files in your project:

| File | Purpose |
|---|---|
| `./ansible/playbooks/audit_security.yml` | Checks system values, user profiles, and library authority |
| `./ansible/playbooks/remediate_security.yml` | Applies corrective changes to bring the system into compliance |
| `./ansible/templates/security_report.json.j2` | Jinja2 template that renders the compliance scorecard as JSON |

Verify they appear in the file explorer before continuing.

**Step 5: Customize the inventory**

The `hosts.yml` from Lab 5 is reused as-is. Confirm your `ansible/inventories/development/hosts.yml` still points to the correct IBM i system:

```yaml
all:
  children:
    ibmi_systems:
      hosts:
        ibmi_dev01:
          ansible_host: <IBMi_IP_address>
          ansible_user: <IBMi_User>
          ansible_python_interpreter: /QOpenSys/pkgs/bin/python3.9
          ansible_ssh_private_key_file: ~/.ssh/id_rsa
          ansible_connection: ssh
```

---

## Playbook Execution & Self-Healing

### Step 1: Run the Audit Playbook

Ask Bob to run the audit playbook for you:

```
Run the security audit playbook
```

Or run it directly from the terminal (replace `07` with your student number):

```bash
ansible-playbook -i ansible/inventories/development/hosts.yml \
  ansible/playbooks/audit_security.yml -e student=07
```

> Bob may iterate on the playbook a few times to adapt to your system. Let it self-correct — review its explanations for each change.

**What to look for in the output:**

Review the `PLAY RECAP` at the end. With the non-compliant baseline in place, you should see `failed=0` (tasks use `failed_when: false`) but the generated compliance report will surface the findings.

Open the generated JSON scorecard at `./ansible/reports/security_compliance_report.json`. It should show two failing **student-specific** items:

| Object | Current Value | Target Value | Status |
|---|---|---|---|
| `MYAPP_DB<NN> *PUBLIC` | `*CHANGE` | `*EXCLUDE` | **FAIL** |
| `LAB6USR<NN>` status | `*ENABLED` | `*DISABLED` | **FAIL** |

The scorecard also lists the system-wide values (`QSECURITY`, `QINACTMSGQ`, `QMAXSIGN`, `QALWOBJRST`). The IBM i system is shared, so these are **audit-only**: they are reported as findings but the remediation playbook does not change them.

---

### Step 2: Run the Remediation Playbook

Ask Bob to apply the fixes:

```
Run the remediation playbook for my student number to fix the non-compliant findings
```

Or run directly (replace `07` with your student number):

```bash
ansible-playbook -i ansible/inventories/development/hosts.yml \
  ansible/playbooks/remediate_security.yml -e student=07
```

**What this changes on the system:**

| Setting | Before | After |
|---|---|---|
| `MYAPP_DB<NN> *PUBLIC` | `*CHANGE` | `*EXCLUDE` |
| `LAB6USR<NN>` status | `*ENABLED` | `*DISABLED` |

Review the `PLAY RECAP`. All tasks should complete with `changed=3` and `failed=0` (revoke, grant, disable).

> **Note:** Remediation only touches your own `MYAPP_DB<NN>` and `LAB6USR<NN>`, so other students on the shared system are unaffected.

---

### Step 3: Re-Audit and Verify Compliance

Ask Bob to run the audit a second time to confirm the remediation worked, then compare the results (replace `07` with your student number):

```
Re-run the security audit playbook with student=07, then compare the two compliance report files and summarize what changed
```

Or run the audit directly:

```bash
ansible-playbook -i ansible/inventories/development/hosts.yml \
  ansible/playbooks/audit_security.yml -e student=07
```

Open the updated `./ansible/reports/security_compliance_report.json`. Both student-specific items should now show **PASS** and the score for your `MYAPP_DB<NN>` and `LAB6USR<NN>` controls should read **100%**. System-wide values are still reported as-is.

Bob will diff the before and after JSON reports and produce a human-readable summary of the remediation.

---

### Step 4: Reset Your Environment (Optional)

To put **your own** library and profile back into their non-compliant state (replace `07` with your student number). Only `MYAPP_DB<NN>` and `LAB6USR<NN>` are touched, so other students are not affected:

```bash
# Restore MYAPP_DB07 to *PUBLIC *CHANGE
ansible ibmi_systems -i ansible/inventories/development/hosts.yml \
  -m ibm.power_ibmi.ibmi_object_authority \
  -a "object_name=MYAPP_DB07 object_type=*LIB user=*PUBLIC operation=grant authority=*CHANGE"

# Re-enable LAB6USR07
ansible ibmi_systems -i ansible/inventories/development/hosts.yml \
  -m ibm.power_ibmi.ibmi_cl_command \
  -a "cmd='CHGUSRPRF USRPRF(LAB6USR07) STATUS(*ENABLED)'"
```

---

## Common Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `CWBNL0203` / `cwbodmsg.dll` error | `ibm.power_ibmi` 3.5.x uses pyodbc which fails in PASE SSH sessions | Pin to `ibm.power_ibmi:3.3.0` |
| `parameter 'sysval' is not supported` | Wrong parameter name in playbook | Use `sysvalue` (list of dicts) |
| `invalid operation: query` | Wrong operation on `ibmi_object_authority` | Use `operation: display` to read authority |
| `check_type is not a valid parameter` | Wrong parameter on `ibmi_user_compliance_check` | Use `users` + `fields` parameters |
| `MYAPP_DB<NN> not found` / `CPF9801` | Wrong student number, or the instructor setup has not been run | Check your number (`01`–`20`) or ask the instructor to run the setup block |

---

## Conclusion

You have successfully built and run an automated security compliance and self-healing remediation assistant on IBM i using Bob and Ansible.

**What you achieved:**
- Used Bob's `ℹ️ Ansible for i` mode to generate audit and remediation playbooks from a single prompt
- Audited core system values using `ibmi_sysval` with the correct `sysvalue` parameter
- Checked user profiles for weak password configurations using `ibmi_user_compliance_check`
- Enforced zero-trust access permissions on a database library using `ibmi_object_authority`
- Applied self-healing remediation and verified 100% compliance on a re-audit

**Next Steps:**
- Integrate the compliance audit playbook into a weekly CI/CD cron job or scheduled pipeline
- Expand checking rules to match full regulatory standards like PCI-DSS or HIPAA
- Combine PTF management (Lab 5), security compliance (Lab 6), and the observability dashboard (Lab 7) into a consolidated "System Integrity Portal"

---

## Lab Instructor Guide

### Prerequisites on the IBM i Target

Ensure the following are installed (same as Lab 5):

```bash
/QOpenSys/pkgs/bin/python3.9 -c "import ibm_db_dbi; conn = ibm_db_dbi.connect(); print('OK')"
/QOpenSys/pkgs/bin/python3.9 -c "import itoolkit; print(itoolkit.__version__)"
```

If missing:
```bash
/QOpenSys/pkgs/bin/yum install -y python39-ibm_db python39-itoolkit
```

### Inventory Reminder

The `hosts.yml` from Lab 5 is reused as-is:

```yaml
all:
  children:
    ibmi_systems:
      hosts:
        ibmi_dev01:
          ansible_host: 150.239.181.102
          ansible_user: ITZUSER
          ansible_python_interpreter: /QOpenSys/pkgs/bin/python3.9
          ansible_ssh_private_key_file: ~/.ssh/id_rsa
          ansible_connection: ssh
          ansible_env:
            LANG: EN_US
            PASE_LANG: EN_US
            QIBM_MULTI_THREADED: "Y"
```

### Reset to Non-Compliant Baseline (Run Before Each Student Session)

Re-run the loop from **Lab Environment Setup** above. It is safe to repeat: existing libraries and profiles are kept, `*PUBLIC` is granted `*CHANGE` again, and each `LAB6USR<NN>` profile is set back to `*ENABLED`. No system values are changed, so the shared system is never affected by a student's remediation.

Assign each student a number from `01` to `20`. Students use that number for every command in the lab.

---

## Troubleshooting Help: Key Module Patterns

> **Only use this section if you're having a lot of trouble.** If the playbooks Bob generated keep failing, compare the tasks below with what Bob wrote and ask Bob to correct any that don't match. If your lab is running fine, you can skip this.

### System Value Auditing (`ibmi_sysval`)

> **Important:** The parameter name is `sysvalue` (a list of dicts), **not** `sysval`.

Bob will generate a task that looks like this in `audit_security.yml`:

```yaml
- name: Audit system security values
  ibm.power_ibmi.ibmi_sysval:
    sysvalue:
      - {name: 'QSECURITY',  expect: '50'}
      - {name: 'QINACTMSGQ', expect: '*DSCJOB',  check: 'equal_as_list'}
      - {name: 'QMAXSIGN',   expect: '000003'}
      - {name: 'QALWOBJRST', expect: '*NONE',    check: 'equal_as_list'}
  register: sysval_audit
  failed_when: false
```

The module returns a `fail_list` when values do not match `expect`. Bob will use this list to populate the compliance scorecard.

### User Profile Compliance (`ibmi_user_compliance_check`)

> **Important:** Parameters are `users` (list of names) and `fields` (list of dicts with `name`/`expect`). There is **no** `check_type` parameter.

Each student has their own profile, `LAB6USR<NN>`, created with no password and left enabled. The audit checks only that profile:

```yaml
- name: Check the student profile is disabled
  ibm.power_ibmi.ibmi_user_compliance_check:
    users:
      - "LAB6USR{{ student }}"
    fields:
      - {name: 'STATUS', expect: ['*DISABLED']}
  register: user_compliance
  failed_when: false
```

Non-compliant users are returned in `user_compliance.result_set`. Bob will loop over this list in the compliance report template.

### Library Permissions (`ibmi_object_authority`)

> **Important:** The read operation is `display`, **not** `query`. Valid operations: `grant`, `revoke`, `display`, `grant_autl`, `revoke_autl`, `grant_ref`.

```yaml
- name: Audit public authority on the student library
  ibm.power_ibmi.ibmi_object_authority:
    object_name: "MYAPP_DB{{ student }}"
    object_type: '*LIB'
    user: '*PUBLIC'
    operation: display
  register: myapp_public_auth
  failed_when: false
```

### Remediating the Student Profile (`ibmi_cl_command`)

> **Important:** `ibmi_sysval` only **reads and checks** system values — it cannot change them. System values are system-wide on this shared IBM i, so this lab **audits** them but never changes them. The remediation playbook only changes your own profile and library:

```yaml
- name: Disable the student profile
  ibm.power_ibmi.ibmi_cl_command:
    cmd: "CHGUSRPRF USRPRF(LAB6USR{{ student }}) STATUS(*DISABLED)"
```

> **Note:** On this system `QPWDRULES` is active with `*MINLEN15`, which blocks any direct `CHGSYSVAL` on `QPWDMINLEN` with CPF1058. `QINACTMSGQ` is audited instead as it represents the same CIS benchmark category (session policy controls).
