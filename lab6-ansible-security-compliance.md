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
- IBM i 7.3 or higher with SSH daemon running (`STRTCPSVR SERVER(*SSHD)`)
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

> **Instructor step:** Run this once to create the non-compliant baseline that students will audit and remediate. The `MYAPP_DB` library must exist before the audit playbook runs.

```bash
# Create the test library and put it in a non-compliant state
ansible ibmi_systems -i ansible/inventories/development/hosts.yml \
  -m ibm.power_ibmi.ibmi_cl_command \
  -a "cmd='CRTLIB LIB(MYAPP_DB) TEXT(''Lab 6 Test Library'')'"

ansible ibmi_systems -i ansible/inventories/development/hosts.yml \
  -m ibm.power_ibmi.ibmi_object_authority \
  -a "object_name=MYAPP_DB object_type=*LIB user=*PUBLIC operation=grant authority=*CHANGE"

# Set QINACTMSGQ to a non-compliant value to create a failing sysval
# Note: QPWDMINLEN cannot be changed when QPWDRULES (*MINLEN15) is active on this system
ansible ibmi_systems -i ansible/inventories/development/hosts.yml \
  -m ibm.power_ibmi.ibmi_cl_command \
  -a "cmd='CHGSYSVAL SYSVAL(QINACTMSGQ) VALUE(*ENDJOB)'"
```

---

## Custom Mode Configuration

We will continue using the `ansible-for-i` custom mode defined in `./.bob/custom_modes.yaml`.

If you haven't set it up yet, refer to the Custom Mode Configuration section in Lab 5.

---

## Security Playbook Creation

### Part 1: Using Bob to Generate the Playbooks

**Step 1: Activate the mode**
- Expand the modes dropdown beneath the chat input
- Select `ℹ️ Ansible for i`

**Step 2: Ask Bob to generate the security compliance project**

Paste the following prompt into the Bob chat:

```
Create a security compliance automation project for IBM i using the ibm.power_ibmi collection (version 3.3.0).

Generate two playbooks and a reporting template:

1. A playbook called audit_security.yml that:
   - Audits system values QSECURITY, QINACTMSGQ, QMAXSIGN, QALWOBJRST using ibmi_sysval
     (parameter is 'sysvalue', a list of dicts with 'name' and 'expect' keys)
   - Audits user profiles for default/blank passwords using ibmi_user_compliance_check
     (parameters: 'users' list and 'fields' list of dicts with 'name' and 'expect' keys)
   - Inspects the public authority of library MYAPP_DB using ibmi_object_authority
     with operation=display (NOT 'query' -- valid operations are grant/revoke/display)
   - Saves a JSON compliance report locally using ansible.builtin.template with delegate_to: localhost

2. A playbook called remediate_security.yml that:
   - Sets QINACTMSGQ=*DSCJOB and QALWOBJRST=*NONE using ibmi_cl_command with CHGSYSVAL
     (ibmi_sysval is read-only; QPWDMINLEN cannot be set when QPWDRULES is active)
   - Revokes *PUBLIC *CHANGE authority on MYAPP_DB using ibmi_object_authority operation=revoke
     then grants *PUBLIC *EXCLUDE
   - Uses become_user and become_user_password module arguments (not Ansible's standard become plugin)
     for tasks that require *SECADM authority

3. A Jinja2 template at ./ansible/templates/security_report.json.j2 that outputs a structured
   compliance scorecard. Use delegate_to: localhost on the template task.
```

**Step 3: Review Bob's generated files**

Bob will create the following files in your project:

| File | Purpose |
|---|---|
| `./ansible/playbooks/audit_security.yml` | Checks system values, user profiles, and library authority |
| `./ansible/playbooks/remediate_security.yml` | Applies corrective changes to bring the system into compliance |
| `./ansible/templates/security_report.json.j2` | Jinja2 template that renders the compliance scorecard as JSON |

Verify they appear in the file explorer before continuing.

**Step 4: Customize the inventory**

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

### Part 2: Understanding the Generated Playbooks

After Bob generates the files, review the key task patterns before running them. This section explains what each module does and common mistakes Bob may need to correct.

#### System Value Auditing (`ibmi_sysval`)

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

#### User Profile Compliance (`ibmi_user_compliance_check`)

> **Important:** Parameters are `users` (list of names) and `fields` (list of dicts with `name`/`expect`). There is **no** `check_type` parameter.

```yaml
- name: Check for profiles with default/blank passwords
  ibm.power_ibmi.ibmi_user_compliance_check:
    users:
      - '*ALL'
    fields:
      - {name: 'NO_PASSWORD_INDICATOR', expect: ['NO']}
      - {name: 'STATUS',                expect: ['*ENABLED']}
  register: user_compliance
  failed_when: false
```

Non-compliant users are returned in `user_compliance.result_set`. Bob will loop over this list in the compliance report template.

#### Library Permissions (`ibmi_object_authority`)

> **Important:** The read operation is `display`, **not** `query`. Valid operations: `grant`, `revoke`, `display`, `grant_autl`, `revoke_autl`, `grant_ref`.

```yaml
- name: Audit public authority on MYAPP_DB
  ibm.power_ibmi.ibmi_object_authority:
    object_name: 'MYAPP_DB'
    object_type: '*LIB'
    user: '*PUBLIC'
    operation: display
  register: myapp_public_auth
  failed_when: false
```

#### Setting System Values (Important: `ibmi_sysval` is read/check only)

> **Important:** `ibmi_sysval` only **reads and checks** system values — it cannot change them. To actually set a system value, Bob will use `ibmi_cl_command` with `CHGSYSVAL` in the remediation playbook:

```yaml
- name: Set QINACTMSGQ to disconnect inactive sessions
  ibm.power_ibmi.ibmi_cl_command:
    cmd: "CHGSYSVAL SYSVAL(QINACTMSGQ) VALUE(*DSCJOB)"
```

> **Note:** On this system `QPWDRULES` is active with `*MINLEN15`, which blocks any direct `CHGSYSVAL` on `QPWDMINLEN` with CPF1058. `QINACTMSGQ` is audited and remediated instead as it represents the same CIS benchmark category (session policy controls).

#### Privilege Elevation on IBM i (`become_user`)

On IBM i, standard Ansible `become:` does not work. The `ibm.power_ibmi` collection uses **module-level** `become_user` and `become_user_password` arguments instead. Bob will generate the remediation tasks like this:

```yaml
- name: Remediate QINACTMSGQ (requires *SECADM)
  ibm.power_ibmi.ibmi_cl_command:
    cmd: "CHGSYSVAL SYSVAL(QINACTMSGQ) VALUE(*DSCJOB)"
    become_user: 'QSECOFR'
    become_user_password: '{{ qsecofr_password }}'
```

Pass the password at runtime to avoid storing it in plain text:
```bash
ansible-playbook ... -e "qsecofr_password=<password>"
```

Or use Ansible Vault for production environments:
```bash
ansible-vault encrypt_string '<password>' --name 'qsecofr_password'
```

> **Note for this lab:** `ITZUSER` already has `*ALLOBJ` and `*SECADM` — you can omit `become_user`/`become_user_password` entirely and the tasks will run under `ITZUSER` directly.

---

## Playbook Execution & Self-Healing

### Step 1: Run the Audit Playbook

Ask Bob to run the audit playbook for you:

```
Run the security audit playbook
```

Or run it directly from the terminal:

```bash
ansible-playbook -i ansible/inventories/development/hosts.yml \
  ansible/playbooks/audit_security.yml
```

> Bob may iterate on the playbook a few times to adapt to your system. Let it self-correct — review its explanations for each change.

**What to look for in the output:**

Review the `PLAY RECAP` at the end. With the non-compliant baseline in place, you should see `failed=0` (tasks use `failed_when: false`) but the generated compliance report will surface the findings.

Open the generated JSON scorecard at `./ansible/reports/security_compliance_report.json`. It should show three failing items:

| System Value / Object | Current Value | Target Value | Status |
|---|---|---|---|
| `QSECURITY` | `50` | `>= 50` | PASS |
| `QINACTMSGQ` | `*ENDJOB` | `*DSCJOB` | **FAIL** |
| `QMAXSIGN` | `000003` | `000003` | PASS |
| `QALWOBJRST` | `*ALL` | `*NONE` | **FAIL** |
| `MYAPP_DB *PUBLIC` | `*CHANGE` | `*EXCLUDE` | **FAIL** |

---

### Step 2: Run the Remediation Playbook

Ask Bob to apply the fixes:

```
Run the remediation playbook to fix the non-compliant findings
```

Or run directly:

```bash
ansible-playbook -i ansible/inventories/development/hosts.yml \
  ansible/playbooks/remediate_security.yml
```

**What this changes on the system:**

| Setting | Before | After |
|---|---|---|
| `QINACTMSGQ` | `*ENDJOB` | `*DSCJOB` |
| `QALWOBJRST` | `*ALL` | `*NONE` |
| `MYAPP_DB *PUBLIC` | `*CHANGE` | `*EXCLUDE` |

Review the `PLAY RECAP`. All tasks should complete with `changed=3` and `failed=0`.

> **Caution:** `QALWOBJRST=*NONE` means no objects can be restored from save files without explicit authority. On a shared ITZ system this is safe for the lab; reverse it with `*ALL` afterwards if needed.

---

### Step 3: Re-Audit and Verify Compliance

Run the audit playbook a second time to confirm the remediation worked:

```bash
ansible-playbook -i ansible/inventories/development/hosts.yml \
  ansible/playbooks/audit_security.yml
```

Open the updated `./ansible/reports/security_compliance_report.json`. All three previously failing items should now show **PASS** and the overall compliance score should read **100%** for the audited controls.

Ask Bob:

```
Compare the two compliance report files and summarize what changed
```

Bob will diff the before and after JSON reports and produce a human-readable summary of the remediation.

---

### Step 4: Reset the Environment (Optional)

To restore the system to its pre-lab non-compliant state for the next student session:

```bash
# Restore QINACTMSGQ to default
ansible ibmi_systems -i ansible/inventories/development/hosts.yml \
  -m ibm.power_ibmi.ibmi_cl_command \
  -a "cmd='CHGSYSVAL SYSVAL(QINACTMSGQ) VALUE(*ENDJOB)'"

# Restore QALWOBJRST to *ALL
ansible ibmi_systems -i ansible/inventories/development/hosts.yml \
  -m ibm.power_ibmi.ibmi_cl_command \
  -a "cmd='CHGSYSVAL SYSVAL(QALWOBJRST) VALUE(*ALL)'"

# Restore MYAPP_DB to *PUBLIC *CHANGE
ansible ibmi_systems -i ansible/inventories/development/hosts.yml \
  -m ibm.power_ibmi.ibmi_object_authority \
  -a "object_name=MYAPP_DB object_type=*LIB user=*PUBLIC operation=grant authority=*CHANGE"

# Optionally delete the test library
ansible ibmi_systems -i ansible/inventories/development/hosts.yml \
  -m ibm.power_ibmi.ibmi_cl_command \
  -a "cmd='DLTLIB LIB(MYAPP_DB)'"
```

---

## Additional Security Use Cases

The following use cases show how to extend the playbooks you created in this lab. For each one, ask Bob to add the task to your existing `audit_security.yml` or `remediate_security.yml`.

### 1. Inactive Profile Disabling

Ask Bob:

```
Add a task to audit_security.yml that finds all enabled user profiles that have not
signed on in more than 90 days, then add a second task to remediate_security.yml
that disables those profiles using ibmi_cl_command.
```

Bob will add:

```yaml
- name: Find profiles inactive for more than 90 days
  ibm.power_ibmi.ibmi_sql_query:
    sql: >
      SELECT AUTHORIZATION_NAME FROM QSYS2.USER_INFO
      WHERE STATUS = '*ENABLED'
        AND PREVIOUS_SIGNON < CURRENT DATE - 90 DAYS
        AND AUTHORIZATION_NAME != 'QSECOFR'
  register: inactive_users
  failed_when: false

- name: Disable inactive profiles
  ibm.power_ibmi.ibmi_cl_command:
    cmd: "CHGUSRPRF USRPRF({{ item.AUTHORIZATION_NAME }}) STATUS(*DISABLED)"
  loop: "{{ inactive_users.row | default([]) }}"
```

### 2. Auditing SSH Configuration

Ask Bob:

```
Add a task to audit_security.yml that checks whether PermitRootLogin is disabled
in the IBM i sshd_config file. Add a corresponding remediation task.
```

> **IBM i path note:** The yum-installed OpenSSH config lives at `/QOpenSys/QIBM/UserData/SC1/OpenSSH/etc/sshd_config`, not the Linux default `/etc/ssh/sshd_config`.

Bob will add:

```yaml
- name: Ensure PermitRootLogin is disabled
  ansible.builtin.lineinfile:
    path: "/QOpenSys/QIBM/UserData/SC1/OpenSSH/etc/sshd_config"
    regexp: "^#?PermitRootLogin"
    line: "PermitRootLogin no"
  notify: Restart SSH Daemon
```

### 3. Monitoring System Auditing Values

Ask Bob:

```
Add a task that verifies QAUDCTL is set to *AUDLVL to confirm security auditing is active.
```

```yaml
- name: Ensure security auditing is active
  ibm.power_ibmi.ibmi_sysval:
    sysvalue:
      - {name: 'QAUDCTL', expect: '*AUDLVL', check: 'equal_as_list'}
  register: audit_ctl
  failed_when: false
```

### 4. Integrity Violation Scans

Ask Bob:

```
Add a task that runs CHKOBJITG and writes violations to an output file in QGPL.
```

```yaml
- name: Check system object integrity
  ibm.power_ibmi.ibmi_cl_command:
    cmd: "CHKOBJITG OUTFILE(QGPL/ITGVIOLATE)"
  register: integrity_scan
```

### 5. Checking Object Authority Across a Library

Ask Bob:

```
Add a task that reports all objects in MYAPP_DB where *PUBLIC has *ALL authority,
using QSYS2.OBJECT_PRIVILEGES.
```

```yaml
- name: Report all objects with *PUBLIC *ALL authority in MYAPP_DB
  ibm.power_ibmi.ibmi_sql_query:
    sql: >
      SELECT OBJECT_NAME, OBJECT_TYPE, OBJECT_AUTHORITY
      FROM QSYS2.OBJECT_PRIVILEGES
      WHERE OBJECT_SCHEMA = 'MYAPP_DB'
        AND GRANTEE = '*PUBLIC'
        AND OBJECT_AUTHORITY = '*ALL'
  register: overly_permissive_objects
  failed_when: false
```

### 6. Network Attribute Audit (RTVNETA)

The CIS IBM i Benchmark recommends that the `JOBACN` network attribute be set to `*REJECT` to block job streams received from the SNA network.

Ask Bob:

```
Add a task to audit_security.yml that retrieves the JOBACN network attribute using
ibmi_rtv_command and asserts it is set to *REJECT. Add a JOBACN field to the
compliance scorecard template.
```

Bob will add:

```yaml
- name: Check JOBACN network attribute (CIS 4.2.1)
  ibm.power_ibmi.ibmi_rtv_command:
    cmd: 'RTVNETA'
    char_vars:
      - 'JOBACN'
  register: jobacn_attr
  failed_when: false

- name: Assert JOBACN is *REJECT
  ansible.builtin.assert:
    that:
      - jobacn_attr.rc == 0
      - jobacn_attr.output['JOBACN'] == '*REJECT'
    fail_msg: "JOBACN is {{ jobacn_attr.output['JOBACN'] }} -- should be *REJECT (CIS 4.2.1)"
    success_msg: "JOBACN is correctly set to *REJECT"
  failed_when: false
```

### 7. SSH Configuration Hardening (sshd_config)

Ask Bob:

```
Add tasks to remediate_security.yml that enforce six CIS-recommended sshd_config
settings using ansible.builtin.lineinfile: PermitRootLogin no, HostbasedAuthentication no,
MaxAuthTries 4, ClientAliveCountMax 0, ClientAliveInterval 300, and strong Ciphers only.
```

Bob will generate:

```yaml
- name: Enforce SSH hardening settings (CIS 4.4.x)
  ansible.builtin.lineinfile:
    path: "/QOpenSys/QIBM/UserData/SC1/OpenSSH/etc/sshd_config"
    regexp: "{{ item.regexp }}"
    line: "{{ item.line }}"
  loop:
    - {regexp: '^#?PermitRootLogin',        line: 'PermitRootLogin no'}
    - {regexp: '^#?HostbasedAuthentication', line: 'HostbasedAuthentication no'}
    - {regexp: '^#?MaxAuthTries',            line: 'MaxAuthTries 4'}
    - {regexp: '^#?ClientAliveCountMax',     line: 'ClientAliveCountMax 0'}
    - {regexp: '^#?ClientAliveInterval',     line: 'ClientAliveInterval 300'}
    - {regexp: '^#?Ciphers',                 line: 'Ciphers aes256-ctr,aes192-ctr,aes128-ctr'}
  notify: Restart SSH Daemon
```

### 8. Broad Object Authority Audit (QGPL Baseline)

Before locking down application libraries, it is useful to understand what a "normal" IBM i system library looks like.

Ask Bob:

```
Add a task that displays the public authority on QGPL using ibmi_object_authority
with operation: display. Use this as a baseline to compare against MYAPP_DB.
```

Bob will add:

```yaml
- name: Display public authority on QGPL (baseline reference)
  ibm.power_ibmi.ibmi_object_authority:
    operation: display
    object_name: QGPL
    object_library: QSYS
    object_type: '*LIB'
  register: qgpl_auth
  failed_when: false

- name: Show QGPL authority list
  ansible.builtin.debug:
    msg: "QGPL authority list: {{ qgpl_auth.object_authority_list }}"
  when: qgpl_auth.rc == 0
```

Then ask Bob:

```
Compare the QGPL authority list returned here against the MYAPP_DB authority we set
in the main lab. What differences do you see and why does MYAPP_DB need stricter controls?
```

---

## Common Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `CWBNL0203` / `cwbodmsg.dll` error | `ibm.power_ibmi` 3.5.x uses pyodbc which fails in PASE SSH sessions | Pin to `ibm.power_ibmi:3.3.0` |
| `parameter 'sysval' is not supported` | Wrong parameter name in playbook | Use `sysvalue` (list of dicts) |
| `invalid operation: query` | Wrong operation on `ibmi_object_authority` | Use `operation: display` to read authority |
| `check_type is not a valid parameter` | Wrong parameter on `ibmi_user_compliance_check` | Use `users` + `fields` parameters |
| `MYAPP_DB not found` / `CPF9801` | Library not created before audit runs | Run the instructor setup block first |
| `become_user` has no effect | Standard Ansible `become:` not supported on IBM i | Use `become_user`/`become_user_password` as module arguments |

---

## Conclusion

You have successfully built and run an automated security compliance and self-healing remediation assistant on IBM i using Bob and Ansible.

**What you achieved:**
- Used Bob's `ℹ️ Ansible for i` mode to generate audit and remediation playbooks from a single prompt
- Audited core system values using `ibmi_sysval` with the correct `sysvalue` parameter
- Checked user profiles for weak password configurations using `ibmi_user_compliance_check`
- Enforced zero-trust access permissions on a database library using `ibmi_object_authority`
- Applied self-healing remediation and verified 100% compliance on a re-audit
- Used IBM i-specific privilege elevation with `become_user`/`become_user_password` module arguments

**Next Steps:**
- Integrate the compliance audit playbook into a weekly CI/CD cron job or scheduled pipeline
- Expand checking rules to match full regulatory standards like PCI-DSS or HIPAA
- Combine PTF management (Lab 5), security compliance (Lab 6), and the observability dashboard (Lab 7) into a consolidated "System Integrity Portal"
- Add the network attribute and SSH hardening checks (use cases 6 and 7 above) to your `audit_security.yml` and `remediate_security.yml` playbooks

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

```bash
ansible ibmi_systems -i ansible/inventories/development/hosts.yml \
  -m ibm.power_ibmi.ibmi_cl_command \
  -a "cmd='CRTLIB LIB(MYAPP_DB) TEXT(''Lab 6 Test Library'')'" \
  --ignore-errors

ansible ibmi_systems -i ansible/inventories/development/hosts.yml \
  -m ibm.power_ibmi.ibmi_object_authority \
  -a "object_name=MYAPP_DB object_type=*LIB user=*PUBLIC operation=grant authority=*CHANGE"

# Set QINACTMSGQ non-compliant (QPWDMINLEN blocked by QPWDRULES on this system)
ansible ibmi_systems -i ansible/inventories/development/hosts.yml \
  -m ibm.power_ibmi.ibmi_cl_command \
  -a "cmd='CHGSYSVAL SYSVAL(QINACTMSGQ) VALUE(*ENDJOB)'"

# Set QALWOBJRST non-compliant
ansible ibmi_systems -i ansible/inventories/development/hosts.yml \
  -m ibm.power_ibmi.ibmi_cl_command \
  -a "cmd='CHGSYSVAL SYSVAL(QALWOBJRST) VALUE(*ALL)'"
```
