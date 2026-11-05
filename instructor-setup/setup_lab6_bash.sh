#!/QOpenSys/pkgs/bin/bash
# =============================================================================
# setup_lab6_bash.sh
# =============================================================================
# PURPOSE
#   One-shot environment setup for Lab 6 (Automated Security Auditing).
#   Replaces the Ansible-based setup commands by running them natively on IBM i.
#
#   Provisions a separate non-compliant security baseline for each of up to N
#   students. Each student gets their own library MYAPP_DB<NN> and user profile
#   LAB6USR<NN>, allowing simultaneous auditing and remediation on the shared system.
#
#   Each student library is set with *PUBLIC having *CHANGE authority (non-compliant).
#   Each student profile is created with PASSWORD(*NONE) and is left *ENABLED.
#
#   Run this ON the IBM i (PASE bash), e.g. from an SSH/QSH session, once,
#   before the workshop.
#
# USAGE
#   bash setup_lab6_bash.sh --participants <N> [OPTIONS]
#
# COUNT (choose one)
#   -n, --participants N   Create baselines for 1 .. <N> (e.g., 20 -> 1..20)
#   -r, --range M N        Explicit inclusive suffix range (e.g. 1 20)
#
# OPTIONS
#       --lib-base BASE    Base name for student database libraries (default: MYAPP_DB)
#       --usr-base BASE    Base name for student user profiles     (default: LAB6USR)
#       --force            Delete and recreate existing libraries and profiles
#   -d, --dry-run          Print the CL commands without running them
#   -v, --verbose          Show full CL command output
#   -h, --help             Show this help
#
# EXAMPLES
#   # Full setup for 20 students (creates MYAPP_DB01..20 and LAB6USR01..20)
#   bash setup_lab6_bash.sh -n 20
#
#   # Full setup for students 1 to 5, overwriting existing resources
#   bash setup_lab6_bash.sh -r 1 5 --force
#
#   # Preview commands without executing
#   bash setup_lab6_bash.sh -n 10 --dry-run
#
# NOTES
#   - Idempotent: library and user creation are skipped if they already exist,
#     unless --force is supplied.
#   - Regardless of existence, the non-compliant permissions and statuses are re-applied.
#   - Requires authority to CRTLIB, CRTUSRPRF, GRTOBJAUT, and CHGUSRPRF
#     (typically *ALLOBJ and *SECADM, i.e., the instructor/administrator profile).
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
LIB_BASE="MYAPP_DB"
USR_BASE="LAB6USR"
PAD=2                  # Suffix zero-pad width

PARTICIPANTS=""
RANGE_M=""
RANGE_N=""

FORCE=false
DRY_RUN=false
VERBOSE=false

SETUP_OK=0
SETUP_ERR=0

# ---------------------------------------------------------------------------
# Colours (disabled when not a terminal)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
usage() {
    sed -n '/^# USAGE/,/^# NOTES/p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
    exit 0
}

is_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }

# run_cl <description> <CL command>
#   Runs a CL command via the PASE `system` utility.
#   Returns 0 on success, 1 on failure. Never aborts the script.
run_cl() {
    local desc="$1" cmd="$2" out rc=0
    printf "    %-55s" "$desc"
    $VERBOSE && { echo; echo -e "      ${CYAN}${cmd}${RESET}"; printf "    %-55s" ""; }
    if $DRY_RUN; then
        echo -e "${YELLOW}[dry-run]${RESET}"
        return 0
    fi
    out=$(system "$cmd" 2>&1) || rc=$?
    if [ $rc -ne 0 ]; then
        echo -e "${RED}FAILED${RESET}"
        echo -e "      ${RED}${out}${RESET}" >&2
        return 1
    fi
    echo -e "${GREEN}OK${RESET}"
    $VERBOSE && [ -n "$out" ] && echo -e "      ${out}"
    return 0
}

# lib_exists <lib>  -> 0 if the *LIB exists
lib_exists() {
    system "QSYS/CHKOBJ OBJ(QSYS/${1}) OBJTYPE(*LIB)" >/dev/null 2>&1
}

# usr_exists <usr>  -> 0 if the *USRPRF exists
usr_exists() {
    system "QSYS/CHKOBJ OBJ(QSYS/${1}) OBJTYPE(*USRPRF)" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--participants) PARTICIPANTS="$2"; shift 2 ;;
        -r|--range)       RANGE_M="$2"; RANGE_N="$3"; shift 3 ;;
        --lib-base)       LIB_BASE=$(echo "$2" | tr '[:lower:]' '[:upper:]'); shift 2 ;;
        --usr-base)       USR_BASE=$(echo "$2" | tr '[:lower:]' '[:upper:]'); shift 2 ;;
        --force)          FORCE=true; shift ;;
        -d|--dry-run)     DRY_RUN=true; shift ;;
        -v|--verbose)     VERBOSE=true; shift ;;
        -h|--help)        usage ;;
        *) echo -e "${RED}Unknown option: $1${RESET}"; echo; usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
errs=0

# Build the student range
TARGET_SUFFIXES=()
if [[ -n "$PARTICIPANTS" ]]; then
    if ! is_integer "$PARTICIPANTS" || [[ "$PARTICIPANTS" -lt 1 ]]; then
        echo -e "${RED}ERROR: --participants must be a positive integer.${RESET}" >&2
        errs=$((errs+1))
    else
        RANGE_M=1; RANGE_N="$PARTICIPANTS"
    fi
fi

if [[ -z "$RANGE_M" || -z "$RANGE_N" ]]; then
    echo -e "${RED}ERROR: Provide --participants N or --range M N.${RESET}" >&2
    errs=$((errs+1))
elif ! is_integer "$RANGE_M" || ! is_integer "$RANGE_N"; then
    echo -e "${RED}ERROR: range values must be integers.${RESET}" >&2
    errs=$((errs+1))
elif [[ "$RANGE_M" -gt "$RANGE_N" ]]; then
    echo -e "${RED}ERROR: range M must be <= N (got $RANGE_M..$RANGE_N).${RESET}" >&2
    errs=$((errs+1))
fi

[ $errs -gt 0 ] && exit 1

# Validate 10-char library and user profile limit
top_len=${#RANGE_N}
[ "$top_len" -gt "$PAD" ] && PAD=$top_len

if [ $((${#LIB_BASE} + PAD)) -gt 10 ]; then
    echo -e "${RED}ERROR: Library base '$LIB_BASE' + ${PAD}-digit suffix exceeds the 10-char limit.${RESET}" >&2
    exit 1
fi

if [ $((${#USR_BASE} + PAD)) -gt 10 ]; then
    echo -e "${RED}ERROR: User profile base '$USR_BASE' + ${PAD}-digit suffix exceeds the 10-char limit.${RESET}" >&2
    exit 1
fi

for (( i=RANGE_M; i<=RANGE_N; i++ )); do
    TARGET_SUFFIXES+=( "$(printf "%0${PAD}d" "$i")" )
done

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo
echo -e "${BOLD}============================================================${RESET}"
echo -e "${BOLD}  Lab 6 Security Environment Setup (Native PASE Bash)${RESET}"
echo -e "${BOLD}============================================================${RESET}"
echo -e "  Library prefix : ${CYAN}${LIB_BASE}${RESET}"
echo -e "  Profile prefix : ${CYAN}${USR_BASE}${RESET}"
echo -e "  Students       : ${CYAN}${TARGET_SUFFIXES[0]} .. ${TARGET_SUFFIXES[-1]}${RESET}  (${#TARGET_SUFFIXES[@]} total)"
$FORCE         && echo -e "  Overwrite      : ${YELLOW}FORCE (Recreate existing libraries and profiles)${RESET}"
$DRY_RUN       && echo -e "  Mode           : ${YELLOW}DRY-RUN (No changes made)${RESET}"
echo

# ---------------------------------------------------------------------------
# Provision Baselines
# ---------------------------------------------------------------------------
idx=0
total=${#TARGET_SUFFIXES[@]}

for suffix in "${TARGET_SUFFIXES[@]}"; do
    idx=$((idx+1))
    LIBLE="${LIB_BASE}${suffix}"
    USRPRF="${USR_BASE}${suffix}"

    echo -e "  ${BOLD}[$idx/$total] Provisioning Student $suffix:${RESET}"

    # --- 1. Manage Library ---
    if ! $DRY_RUN && lib_exists "$LIBLE"; then
        if $FORCE; then
            run_cl "  Delete existing library ${LIBLE} (force)" "QSYS/DLTLIB LIB(${LIBLE})" || {
                SETUP_ERR=$((SETUP_ERR+1)); echo; continue; }
            run_cl "  Create library ${LIBLE}" "QSYS/CRTLIB LIB(${LIBLE}) TEXT('Lab 6 Student ${suffix}')" || {
                SETUP_ERR=$((SETUP_ERR+1)); echo; continue; }
        else
            printf "    %-55s%s\n" "  Create library ${LIBLE}" "${YELLOW}skipped (exists; use --force)${RESET}"
        fi
    else
        run_cl "  Create library ${LIBLE}" "QSYS/CRTLIB LIB(${LIBLE}) TEXT('Lab 6 Student ${suffix}')" || {
            SETUP_ERR=$((SETUP_ERR+1)); echo; continue; }
    fi

    # --- 2. Inject Library Authority Vulnerability (*PUBLIC has *CHANGE) ---
    run_cl "  Set *PUBLIC authority on ${LIBLE} to *CHANGE" \
           "QSYS/GRTOBJAUT OBJ(${LIBLE}) OBJTYPE(*LIB) USER(*PUBLIC) AUT(*CHANGE)" || {
        SETUP_ERR=$((SETUP_ERR+1)); echo; continue; }

    # --- 3. Manage User Profile ---
    if ! $DRY_RUN && usr_exists "$USRPRF"; then
        if $FORCE; then
            run_cl "  Delete existing user profile ${USRPRF} (force)" "QSYS/DLTUSRPRF USRPRF(${USRPRF})" || {
                SETUP_ERR=$((SETUP_ERR+1)); echo; continue; }
            run_cl "  Create user profile ${USRPRF}" \
                   "QSYS/CRTUSRPRF USRPRF(${USRPRF}) PASSWORD(*NONE) STATUS(*ENABLED) TEXT('Lab 6 Student ${suffix}')" || {
                SETUP_ERR=$((SETUP_ERR+1)); echo; continue; }
        else
            printf "    %-55s%s\n" "  Create user profile ${USRPRF}" "${YELLOW}skipped (exists; use --force)${RESET}"
        fi
    else
        run_cl "  Create user profile ${USRPRF}" \
               "QSYS/CRTUSRPRF USRPRF(${USRPRF}) PASSWORD(*NONE) STATUS(*ENABLED) TEXT('Lab 6 Student ${suffix}')" || {
            SETUP_ERR=$((SETUP_ERR+1)); echo; continue; }
    fi

    # --- 4. Inject Profile Status Vulnerability (*ENABLED) ---
    run_cl "  Set status of user profile ${USRPRF} to *ENABLED" \
           "QSYS/CHGUSRPRF USRPRF(${USRPRF}) STATUS(*ENABLED)" || {
        SETUP_ERR=$((SETUP_ERR+1)); echo; continue; }

    SETUP_OK=$((SETUP_OK+1))
    echo
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo -e "${BOLD}============================================================${RESET}"
if $DRY_RUN; then
    echo -e "  ${YELLOW}DRY-RUN complete - no changes were made.${RESET}"
elif [ $SETUP_ERR -eq 0 ]; then
    echo -e "  ${GREEN}ALL DONE - ${SETUP_OK} student environments provisioned successfully.${RESET}"
else
    echo -e "  ${YELLOW}DONE with errors - ${SETUP_OK} ok, ${RED}${SETUP_ERR} failed${YELLOW}.${RESET}"
fi
echo -e "${BOLD}============================================================${RESET}"
echo
echo -e "  ${BOLD}Student assignments for Lab 6:${RESET}"
printf "    %-10s %-12s %-12s\n" "Student" "Library" "User Profile"
printf "    %s\n" "----------------------------------------"
for suffix in "${TARGET_SUFFIXES[@]}"; do
    printf "    %-10s %-12s %-12s\n" "$((10#$suffix))" "${LIB_BASE}${suffix}" "${USR_BASE}${suffix}"
done
echo
echo -e "  Instruct students to run audits with: -e student=${CYAN}<NN>${RESET} (e.g. 07)"
echo

exit $SETUP_ERR
