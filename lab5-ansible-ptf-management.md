# Lab 5: Building a PTF Management Assistant on IBM i with IBM Bob & Ansible

**Duration:** 20 minutes  
**Difficulty:** Intermediate   
**Version:** 2 - April 1 , 2026


## Introduction

This lab guides you through creating an automated assistant to manage Program Temporary Fixes (PTFs) on IBM i systems using Ansible with Bob AI assistant integration. You'll learn to leverage Bob's AI capabilities to streamline PTF currency checks, automate compliance reporting, and manage system updates efficiently.

**Objectives:**
- Configure Bob with specialized Ansible for IBM i knowledge
- Create playbooks to query and report PTF status
- Automate PTF currency compliance checking
- Generate formatted reports for system administrators
- Explore advanced automation scenarios for IBM i environments

## Prerequisites

### IBM i System Requirements
- IBM i 7.3 or higher
- SSH'd into IBM i (PASE/5250)
- User profile with *ALLOBJ or appropriate PTF management authorities
- Python 3.6+ installed via yum (`yum install python3`)
- IBM i Open Source Package Management configured
Please check on the [Lab Instructor Guide](./lab5-ansible-ptf-management.md#lab-instructor-guide) section for more details.


### Bob Workstation Requirements
**You can create a virtual environment to install all the packages required.
```bash
  python -m venv
  source .venv/bin/activate
  ```
- Ansible 2.9+ installed (`pip install ansible`)
- Python 3.8+ with pip
- IBM i Ansible collections:
  ```bash
  ansible-galaxy collection install ibm.power_ibmi:3.3.0 --force
  ansible-galaxy collection install ibm.power_hmc
  ```
  > **⚠️ Version note:** Install `ibm.power_ibmi` at **v3.3.0** specifically. v3.5.0 (the current default) switched from `ibm_db` to `pyodbc` as its SQL transport, and the IBM i Access ODBC driver fails with `CWBNL0203` inside a PASE SSH session. v3.3.0 uses `ibm_db_dbi` (IBM's native Db2 driver), which works correctly.
- SSH key-based authentication configured to IBM i system (see [Lab Instructor Guide](./lab5-ansible-ptf-management.md#lab-instructor-guide) instructions included in lab guide)
- Bob AI assistant installed and configured
- Network connectivity to IBM i system (port 22) (see lab 4)

### Verify Setup
```bash
# Verify Ansible installation
ansible --version

# Check IBM i collection
ansible-galaxy collection list | grep ibm.power_ibmi
```

## Custom Mode Configuration

For this we'll use the `ansible-for-i` custom mode defined in `./.bob/custom_modes.yaml`:

```yaml
customModes:
  - slug: ansible-for-i
    name: "Ansible for i"
    whenToUse: >-
      Use this mode for IBM i automation with Ansible -- playbook development,
      ibm.power_ibmi collection modules, PTF management, object authorities,
      PowerHA automation, and Power HMC integration.
    roleDefinition: |
      You are an expert in IBM i system administration and Ansible automation.

      Focus areas:
      - IBM i-specific Ansible modules (ibm.power_ibmi collection)
      - PTF management and system currency
      - YAML playbook best practices
      - IBM i object authorities and security
      - Power Systems hardware management
      - High availability configurations

      Key commands you work with:
        ansible-playbook, ansible-inventory, ansible-doc

      Core knowledge areas:
        - IBM i operating system concepts
        - PTF lifecycle and management
        - Ansible playbook development
        - Jinja2 templating
        - IBM i Ansible modules: ibmi_fix, ibmi_sql_query, ibmi_object_authority
        - Power HMC integration
        - PowerHA SystemMirror automation
    groups:
      - read
      - edit
      - execute
```

## First Playbook Creation

### Part 1: Using Bob to Generate the Playbook

Let's use Bob to generate the complete playbook structure and automation code.

**Step 1: Activate the mode:**
- Expand the modes dropdown beneath the chat input
- Select `ℹ️ Ansible for i`

**Step 1b: Verify column names before generating (IBM i Database mode)**

Before asking Bob to write any playbook SQL, confirm the actual column names available on your system. IBM i versions vary — columns that exist on 7.5 may not exist on 7.3, and a wrong column name will cause `SQL0206` errors at runtime.

- Switch to **IBM i Database mode** (mode dropdown → IBM i Database)
- Run this prompt:

```
Run a query to check whether these columns exist in their respective views:
  QSYS2.SYSTEM_STATUS_INFO — HOST_NAME, ELAPSED_CPU_USED, SYSTEM_ASP_USED, ACTIVE_JOBS_IN_SYSTEM, TOTAL_JOBS_IN_SYSTEM
  QSYS2.PTF_INFO — PTF_IDENTIFIER, PTF_LOADED_STATUS, PTF_IPL_REQUIRED, PTF_PRODUCT_ID, PTF_STATUS_TIMESTAMP
```

Bob will query the system catalog live and return the real column list for your IBM i version. **Note down the columns you want to use** — particularly:
- From `SYSTEM_STATUS_INFO`: the hostname/system name column, CPU utilisation, ASP usage
- From `PTF_INFO`: PTF identifier, status, IPL required flag, product ID, and load date

- Switch back to **Ansible for i mode** before continuing

**Step 2: Ask Bob to create the PTF currency check automation**

In your Bob IDE or terminal, provide this prompt — substituting the confirmed column names from Step 1b where indicated:

```
Create an Ansible automation project for IBM i PTF management with the following:

1. Directory structure: ./ansible with subdirectories for inventories/development, playbooks, and templates
2. A playbook called check_ptf_currency.yml that:
   - Queries IBM i system information using ibmi_sql_query against QSYS2.SYSTEM_STATUS_INFO
     (available columns: HOST_NAME, PARTITION_ID, ELAPSED_CPU_USED, SYSTEM_ASP_USED, ACTIVE_JOBS_IN_SYSTEM, TOTAL_JOBS_IN_SYSTEM)
   - Checks PTF group levels (SF99740, SF99738) using ibmi_fix_group_check
   - Lists installed PTFs from QSYS2.PTF_INFO
     (available columns: PTF_IDENTIFIER, PTF_LOADED_STATUS, PTF_IPL_REQUIRED, PTF_PRODUCT_ID, PTF_STATUS_TIMESTAMP)
   - Compares against missing critical PTFs
   - Calculates compliance statistics
   - Generates an HTML report using a Jinja2 template, save to ./ansible/reports
3. An inventory file for development environment with ibmi_systems group
4. A Jinja2 template for the PTF currency report with system info, PTF group status, missing PTFs, and compliance metrics

Use IBM i Ansible collection modules (ibm.power_ibmi) and follow best practices.
```

**Step 3: Review Bob's generated files**

Bob will create:
- `./ansible/inventories/development/hosts.yml` - Inventory configuration
- `./ansible/playbooks/check_ptf_currency.yml` - Main playbook
- `./ansible/templates/ptf_currency_report.j2` - Report template

**Step 4: Customize the generated inventory**

Update the inventory (hosts.yml) file with your actual IBM i system details:
```yaml
all:
  children:
    ibmi_systems:
      hosts:
        ibmi_dev01:
          ansible_host: <YOUR_IBM_I_IP>
          ansible_user: ITZUSER
          ansible_ssh_private_key_file: ./ssh_private_key.pem
          ansible_python_interpreter: /QOpenSys/pkgs/bin/python3.9
          ansible_connection: ssh
          ansible_env:
            LANG: EN_US
            PASE_LANG: EN_US
            QIBM_MULTI_THREADED: "Y"
```

> **⚠️ Python interpreter:** Set `ansible_python_interpreter` to `/QOpenSys/pkgs/bin/python3.9` explicitly. The default `python3` symlink may point to a Python version that does not have `ibm_db` installed.

### Part 2: Understanding the Generated Playbook

After Bob generates the automation, review the PTF currency check playbook structure at `./ansible/playbooks/check_ptf_currency.yml`. It should look something like:

```yaml
---
- name: Check PTF Currency on IBM i Systems
  hosts: ibmi_systems
  gather_facts: no

  vars:
    report_path: "./ansible/reports/ptf_currency_report_{{ ansible_date_time.date }}.html"

  tasks:
    - name: Gather system information
      ibm.power_ibmi.ibmi_sql_query:
        sql: >-
          SELECT HOST_NAME, ELAPSED_CPU_USED, SYSTEM_ASP_USED,
                 ACTIVE_JOBS_IN_SYSTEM, TOTAL_JOBS_IN_SYSTEM
          FROM QSYS2.SYSTEM_STATUS_INFO
      register: system_info

    - name: Get current PTF group level
      ibm.power_ibmi.ibmi_fix_group_check:
        groups:
          - "SF99740"  # Technology Refresh group
          - "SF99738"  # Cumulative PTF package
      register: ptf_groups

    - name: List installed PTFs
      ibm.power_ibmi.ibmi_sql_query:
        sql: >-
          SELECT PTF_IDENTIFIER, PTF_LOADED_STATUS, PTF_IPL_REQUIRED,
                 PTF_PRODUCT_ID, PTF_STATUS_TIMESTAMP
          FROM QSYS2.PTF_INFO
          WHERE PTF_LOADED_STATUS NOT IN ('NOT LOADED', 'DAMAGED')
      register: ptf_list

    ...
```

## Template Development

Duplicate Jinja2 template at `./ansible/templates/ptf_currency_report.html.j2`, convert it to html: `ptf_currency_report.html`, and open it in the integrated browser (right click on the file):

![](./pics/PTF_report_unfilled.png)

## Playbook Execution - Ansible for i mode

**Run the playbook through Bob:**
```bash
Run the PTF currency check playbook
```
- Bob may need to iterate on the Playbook a few times to adapt to your current system.


**Review output:**
- Check PLAY RECAP for success/failure status
- Examine task output for PTF details
- Open generated HTML report in browser
- Review missing PTFs and compliance percentage

**Common troubleshooting:**
- SSH authentication failures: Verify key-based auth setup
- Module not found: Reinstall `ibm.power_ibmi` collection at v3.3.0 (`ansible-galaxy collection install ibm.power_ibmi:3.3.0 --force`)
- Permission denied: Check user authorities on IBM i
- Connection timeout: Verify firewall rules and network connectivity
- `CWBNL0203` / ODBC errors: You have v3.5.0 of `ibm.power_ibmi` — downgrade to v3.3.0 (see Prerequisites)
- `SQL0206 - Column not found` on `SERIAL_NUMBER` or `PARTITION_NAME`: Remove those columns from the `ENV_SYS_INFO` query; they don't exist on IBM i 7.6 VMs

**Pre-flight verification checklist** — run these before executing the playbook:

On your IBM i:
```bash
# All three must succeed
/QOpenSys/pkgs/bin/python3.9 -c "import ibm_db_dbi; conn = ibm_db_dbi.connect(); print('OK')"
/QOpenSys/pkgs/bin/python3.9 -c "import itoolkit; print(itoolkit.__version__)"
/QOpenSys/pkgs/cwbping localhost   # Should show all host servers connected
```

On your Mac (Ansible controller):
```bash
ansible-galaxy collection list | grep ibm.power_ibmi   # Must show 3.3.0
ansible --version                                       # Must show 2.9+
```

### When the playbook finishes, check the output by opening the html file in browser

`open ./ansible/reports/<REPORT_NAME>`

![](./pics/PTF_report_filled.png)


## Some Additional Use Cases

### 1. Automated PTF Application
```yaml
- name: Apply PTF package
  ibm.power_ibmi.ibmi_fix:
    product_id: "5770SS1"
    fix_list: ["SI12345", "SI67890"]
    operation: "apply"
```

### 2. System Health Monitoring
```yaml
- name: Monitor system resources
  ibm.power_ibmi.ibmi_sql_query:
    sql: "SELECT * FROM QSYS2.SYSTEM_STATUS_INFO"
  register: health_metrics
```

### 3. Backup Automation
```yaml
- name: Save system configuration
  ibm.power_ibmi.ibmi_save:
    objects: ["*ALL"]
    savefile: "QGPL/SYSBACKUP"
    parameters: "UPDHST(*YES)"
```

### 4. User Authority Management
```yaml
- name: Grant object authority
  ibm.power_ibmi.ibmi_object_authority:
    object_name: "MYLIB/MYFILE"
    user: "APPUSER"
    authority: "*CHANGE"
```

### 5. Performance Monitoring
```yaml
- name: Collect performance data
  ibm.power_ibmi.ibmi_sql_query:
    sql: "SELECT * FROM QSYS2.SYSTEM_ACTIVITY_INFO"
```

### 6. PowerHA Orchestration
```yaml
- name: Check cluster status
  ibm.power_ibmi.ibmi_cl_command:
    cmd: "DSPCLU CLUSTER(MYCLUSTER)"
  register: cluster_status
```

### 7. Power HMC Integration
```yaml
- name: Provision LPAR
  ibm.power_hmc.lpar:
    hmc_host: "hmc.example.com"
    system_name: "POWER9-SYS"
    name: "NEW_LPAR"
    state: "present"
```

### 8. Software Installation
```yaml
- name: Install licensed program
  ibm.power_ibmi.ibmi_install_product:
    product: "5770DG1"
    option: "*BASE"
```

### 9. Security Audit
```yaml
- name: Audit user profiles
  ibm.power_ibmi.ibmi_sql_query:
    sql: "SELECT * FROM QSYS2.USER_INFO WHERE STATUS = '*ENABLED'"
```

### 10. ServiceNow Integration
```yaml
- name: Create change request
  servicenow.itsm.change_request:
    instance: "{{ snow_instance }}"
    short_description: "PTF Application - {{ ansible_date_time.date }}"
    description: "Applying PTFs: {{ missing_ptfs.missing_fixes | join(', ') }}"
    state: "new"
```

## Conclusion

You've successfully created an Ansible-based PTF management assistant with Bob AI integration. This automation framework provides:
- Automated PTF currency checking and compliance reporting
- Streamlined system administration workflows
- Integration capabilities with enterprise ITSM tools
- Foundation for comprehensive IBM i automation

**Next Steps:**
- Expand playbooks for automated PTF application
- Integrate with CI/CD pipelines
- Create scheduled jobs for regular compliance checks
- Explore PowerHA and HMC automation scenarios

**Resources:**
- IBM i Ansible Collection: https://galaxy.ansible.com/ibm/power_ibmi
- Power HMC Collection: https://galaxy.ansible.com/ibm/power_hmc
- IBM i PTF Management: https://www.ibm.com/support/pages/best-practices-ptf-or-fixes-installation


## Lab Instructor Guide

On your IBM i, please ensure that public ssh key authentication is set up for the user and that the prerequisites are installed on the IBM i system (https://github.com/IBM/ansible-for-i: 5733SC1 Base and Option 1, 5770DG1, python3, python3-itoolkit, python3-ibm_db)

0. SSH into the IBM i server
`ssh -i path/to/pem_user_privatekey_download.pem <OS_USER_NAME>@<IBMi_IP_ADDRESS>`

1. Generate an ssh key on your local
`ssh-keygen -t rsa -b 4096 -C "identifier e.g. ibmi-liam"`

2. Copy the key to your IBM i machine
```
ssh -i path/to/pem_user_privatekey_download.pem \
  -L 8076:localhost:8076 \
  cecuser@<IBMi_IP>
```

3. Test the connection, you shouldn't be prompted for a password this time
`ssh <USERNAME>@<IBMi_IP>`

If you need to set one up...

2. Verify installations
```bash
/QOpenSys/pkgs/bin/python3.9 --version
/QOpenSys/pkgs/bin/yum search python39-itoolkit
/QOpenSys/pkgs/bin/yum search python39-ibm_db
```

If not installed, install the missing package/s:
```bash
/QOpenSys/pkgs/bin/yum install python3.9
/QOpenSys/pkgs/bin/yum install python39-itoolkit
/QOpenSys/pkgs/bin/yum install python39-ibm_db
```

> **⚠️ Important:** `python39-ibm_db` must be installed for the **Python 3.9** interpreter specifically — not just Python 3.6. Run this via SSH to confirm and install on the target system:
> ```bash
> ssh ITZUSER@<IP> "/QOpenSys/pkgs/bin/yum install -y python39-ibm_db"
> ```
