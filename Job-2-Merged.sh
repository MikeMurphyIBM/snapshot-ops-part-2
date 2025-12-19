#!/usr/bin/env bash

################################################################################
# JOB 2: CLONE & RESTORE (NO SNAPSHOTS)
# Purpose: Clone volumes from primary LPAR and attach to secondary LPAR
# Dependencies: IBM Cloud CLI, PowerVS plugin, jq
################################################################################

# ------------------------------------------------------------------------------
# TIMESTAMP LOGGING SETUP
# Prepends timestamp to all output for audit trail
# ------------------------------------------------------------------------------
timestamp() {
    while IFS= read -r line; do
        printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
    done
}
exec > >(timestamp) 2>&1

# ------------------------------------------------------------------------------
# STRICT ERROR HANDLING
# Exit on undefined variables and command failures
# ------------------------------------------------------------------------------
set -eu

################################################################################
# BANNER
################################################################################
echo ""
echo "========================================================================"
echo " JOB 2: CLONE & RESTORE OPERATIONS"
echo " Purpose: Clone primary LPAR volumes and restore to secondary LPAR"
echo "========================================================================"
echo ""

################################################################################
# CONFIGURATION VARIABLES
# Centralized configuration for easy maintenance
################################################################################

# IBM Cloud Authentication
readonly API_KEY="${IBMCLOUD_API_KEY}"
readonly REGION="us-south"
readonly RESOURCE_GROUP="Default"

# PowerVS Workspace Configuration
readonly PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/db1a8b544a184fd7ac339c243684a9b7:973f4d55-9056-4848-8ed0-4592093161d2::" #workspace crn
readonly CLOUD_INSTANCE_ID="973f4d55-9056-4848-8ed0-4592093161d2" #workspace ID

# LPAR Configuration
readonly PRIMARY_LPAR="murphy-prod"              # Source LPAR for cloning
readonly PRIMARY_INSTANCE_ID="fea64706-1929-41c9-a761-68c43a8f29cc"
readonly SECONDARY_LPAR="murphy-prod-clone"               # Target LPAR for restore
#readonly STORAGE_TIER="tier3"                     # Must match source tier

# Naming Convention - Clone YYYY-MM-DD-HH-MM
readonly CLONE_PREFIX="murphy-prod-$(date +"%Y%m%d%H%M")"

# Polling Configuration
readonly POLL_INTERVAL=30
readonly INITIAL_WAIT=60
readonly MAX_ATTACH_WAIT=1800
readonly MAX_BOOT_WAIT=1200

# Runtime State Variables (Tracked for Cleanup)
PRIMARY_BOOT_ID=""
PRIMARY_DATA_IDS=""
SECONDARY_INSTANCE_ID=""
CLONE_BOOT_ID=""
CLONE_DATA_IDS=""
CLONE_TASK_ID=""
JOB_SUCCESS=0
RESUME_AT_STAGE_5=0   

echo "Configuration loaded successfully."
echo ""

################################################################################
# CLEANUP FUNCTION
# Triggered on failure to rollback partially completed operations
# Logic:
#   1. Resolve secondary LPAR instance ID (if not already resolved)
#   2. Bulk detach all volumes from secondary LPAR
#   3. Wait for detachment to complete
#   4. Bulk delete cloned volumes
#   5. Verify deletion completed
################################################################################


cleanup_on_failure() {
    trap - ERR EXIT

    echo "→ cleanup_on_failure triggered (FAILED_STAGE=${FAILED_STAGE:-UNKNOWN})"


    # If job succeeded, do nothing
    if [[ ${JOB_SUCCESS:-0} -eq 1 ]]; then
        return 0
    fi

    FAILED_AT="${FAILED_STAGE:-UNKNOWN_STAGE}"

    echo ""
    echo "========================================================================"
    echo " JOB FAILED — PRESERVING RECOVERY ARTIFACTS"
    echo "========================================================================"
    echo ""
    echo "Failure detected at stage: ${FAILED_AT}"
    echo ""

    #
    # Only mark volumes for relevant failures
    #
    case "$FAILED_AT" in
        ATTACH_VOLUME|BOOT_CONFIG|STARTUP|FINAL_STATUS_CHECK)
            MARK_VOLUMES=1
            ;;
        *)
            MARK_VOLUMES=0
            ;;
    esac



    if [[ "$MARK_VOLUMES" -ne 1 ]]; then
        echo "Failure stage does not require volume marking — skipping"
        return 0
    fi

    #
    # Mark boot volume
    #
    if [[ -n "$CLONE_BOOT_ID" ]]; then
        echo "→ Marking boot volume as FAILED..."

        CURRENT_NAME=$(ibmcloud pi volume get "$CLONE_BOOT_ID" --json \
            | jq -r '.name')

        if [[ "$CURRENT_NAME" != *"__FAILED" ]]; then
            ibmcloud pi volume update "$CLONE_BOOT_ID" \
                --name "${CURRENT_NAME}__FAILED" \
                >/dev/null 2>&1 || true
        fi

        echo "  Boot volume preserved: ${CURRENT_NAME}__FAILED"
    fi

    #
    # Mark data volumes (if any)
    #
    if [[ -n "$CLONE_DATA_IDS" ]]; then
        for VOL in ${CLONE_DATA_IDS//,/ }; do
            echo "→ Marking data volume ${VOL} as FAILED..."

            CURRENT_NAME=$(ibmcloud pi volume get "$VOL" --json \
                | jq -r '.name')

            if [[ "$CURRENT_NAME" != *"__FAILED" ]]; then
                ibmcloud pi volume update "$VOL" \
                    --name "${CURRENT_NAME}__FAILED" \
                    >/dev/null 2>&1 || true
            fi

            echo "  Data volume preserved: ${CURRENT_NAME}__FAILED"
        done
    fi

    echo ""
    echo "========================================================================"
    echo " FAILURE SUMMARY"
    echo "========================================================================"
    echo " Secondary LPAR : ${SECONDARY_LPAR}"
    echo " Failure stage  : ${FAILED_AT}"
    echo " Volumes marked : __FAILED"
    echo " Cleanup job    : separate job required"
    echo "========================================================================"
    echo ""
}


################################################################################
# HELPER FUNCTION: WAIT FOR ASYNC CLONE JOB
# Logic:
#   1. Poll clone task status every 30 seconds
#   2. Complete when status is "completed"
#   3. Fail if status is "failed"
################################################################################
wait_for_clone_job() {
    local task_id=$1
    echo "→ Waiting for asynchronous clone task: ${task_id}..."
    
    while true; do
        STATUS=$(ibmcloud pi volume clone-async get "$task_id" --json \
            | jq -r '.status')
        
        if [[ "$STATUS" == "completed" ]]; then
            echo "✓ Clone task completed successfully"
            break
        elif [[ "$STATUS" == "failed" ]]; then
            echo "✗ ERROR: Clone task failed"
            exit 1
        else
            echo "  Clone task status: ${STATUS} - waiting 30s..."
            sleep 30
        fi
    done
}

################################################################################
# ACTIVATE CLEANUP TRAP
# Ensures cleanup runs on both ERR and EXIT
################################################################################
trap 'cleanup_on_failure' ERR EXIT

################################################################################
# STAGE 1: IBM CLOUD AUTHENTICATION
################################################################################
echo "========================================================================"
echo " STAGE 1/5: IBM CLOUD AUTHENTICATION & WORKSPACE TARGETING"
echo "========================================================================"
echo ""

echo "→ Authenticating to IBM Cloud (Region: ${REGION})..."
ibmcloud login --apikey "$API_KEY" -r "$REGION" > /dev/null 2>&1 || {
    echo "✗ ERROR: IBM Cloud login failed"
    exit 1
}
echo "✓ Authentication successful"

echo "→ Targeting resource group: ${RESOURCE_GROUP}..."
ibmcloud target -g "$RESOURCE_GROUP" > /dev/null 2>&1 || {
    echo "✗ ERROR: Failed to target resource group"
    exit 1
}
echo "✓ Resource group targeted"

echo "→ Targeting PowerVS workspace..."
ibmcloud pi ws target "$PVS_CRN" > /dev/null 2>&1 || {
    echo "✗ ERROR: Failed to target PowerVS workspace"
    exit 1
}
echo "✓ PowerVS workspace targeted"

echo ""
echo "------------------------------------------------------------------------"
echo " Stage 1 Complete: Authentication successful"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# STAGE 2: IDENTIFY PRIMARY VOLUMES
################################################################################
FAILED_STAGE="IDENTIFY_PRIMARY_VOLUMES"

echo "========================================================================"
echo " STAGE 2/5: IDENTIFY PRIMARY LPAR VOLUMES"
echo "========================================================================"
echo ""

echo "→ Retrieving volumes attached to primary LPAR: ${PRIMARY_LPAR}..."

PRIMARY_JSON=$(ibmcloud pi instance get "$PRIMARY_INSTANCE_ID" --json 2>/dev/null)
if [[ -z "$PRIMARY_JSON" ]]; then
    echo "✗ ERROR: Could not retrieve primary LPAR details"
    exit 1
fi

# Extract boot volume ID
PRIMARY_BOOT_ID=$(echo "$PRIMARY_JSON" | jq -r '.volumeIDs[0]')
if [[ -z "$PRIMARY_BOOT_ID" || "$PRIMARY_BOOT_ID" == "null" ]]; then
    echo "✗ ERROR: Could not identify boot volume"
    exit 1
fi
echo "✓ Boot volume identified: ${PRIMARY_BOOT_ID}"

# Extract data volumes (all volumes except boot)
PRIMARY_DATA_IDS=$(echo "$PRIMARY_JSON" | jq -r '.volumeIDs[1:]? | join(",")')
if [[ -n "$PRIMARY_DATA_IDS" && "$PRIMARY_DATA_IDS" != "null" ]]; then
    DATA_COUNT=$(echo "$PRIMARY_DATA_IDS" | tr ',' '\n' | wc -l | tr -d ' ')
    echo "✓ Data volumes identified: ${DATA_COUNT} volumes"
else
    PRIMARY_DATA_IDS=""
    echo "  No additional data volumes found"
fi

echo ""
echo "  Primary LPAR Volume Summary:"
echo "  ┌────────────────────────────────────────────────────────────"
echo "  │ Boot Volume: ${PRIMARY_BOOT_ID}"
if [[ -n "$PRIMARY_DATA_IDS" ]]; then
    echo "  │ Data Volumes:"
    IFS=',' read -ra DATA_ARRAY <<<"$PRIMARY_DATA_IDS"
    for vol in "${DATA_ARRAY[@]}"; do
        echo "  │   - ${vol}"
    done
else
    echo "  │ Data Volumes: None"
fi
echo "  └────────────────────────────────────────────────────────────"
echo ""

echo "------------------------------------------------------------------------"
echo " Stage 2 Complete: Primary volumes identified"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# STAGE 3: SSH PREPARATION & VOLUME CLONING
################################################################################
FAILED_STAGE="IBMI_PREPARATION"

echo "========================================================================"
echo " STAGE 3/5: IBMi PREPARATION & VOLUME CLONING"
echo "========================================================================"
echo ""

# ------------------------------------------------------------------------------
# STAGE 3a: Install SSH Keys from Code Engine Secrets
# ------------------------------------------------------------------------------
echo "→ Stage 3a: Installing SSH keys from Code Engine secrets..."
echo ""

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# VSI SSH Key (RSA)
VSI_KEY_FILE="$HOME/.ssh/id_rsa"
if [ -z "${id_rsa:-}" ]; then
  echo "✗ ERROR: id_rsa environment variable is not set"
  exit 1
fi
echo "$id_rsa" > "$VSI_KEY_FILE"
chmod 600 "$VSI_KEY_FILE"
echo "  ✓ VSI SSH key installed"

# IBMi SSH Key (ED25519)
IBMI_KEY_FILE="$HOME/.ssh/id_ed25519_vsi"
if [ -z "${id_ed25519_vsi:-}" ]; then
  echo "✗ ERROR: id_ed25519_vsi environment variable is not set"
  exit 1
fi
echo "$id_ed25519_vsi" > "$IBMI_KEY_FILE"
chmod 600 "$IBMI_KEY_FILE"
echo "  ✓ IBMi SSH key installed"

echo ""

# ------------------------------------------------------------------------------
# STAGE 3b: SSH to IBMi and Run Preparation Commands
# ------------------------------------------------------------------------------
echo "→ Stage 3b: Connecting to IBMi via VSI for disk preparation..."
echo ""

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  murphy@52.118.255.179 \
  "ssh -i /home/murphy/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       murphy@192.168.0.109 \
       'system \"CALL PGM(QSYS/QAENGCHG) PARM(*ENABLECI)\"; \
        system \"CHGASPACT ASPDEV(*SYSBAS) OPTION(*FRCWRT)\"'" || true

echo "  ✓ IBMi preparation commands completed"
echo ""

echo "→ Waiting 3 seconds before initiating volume clone..."
sleep 3
echo ""

# ------------------------------------------------------------------------------
# STAGE 3c: Clone Boot Volume
# ------------------------------------------------------------------------------
FAILED_STAGE="CLONE_BOOT_VOLUME"

echo "→ Stage 3c: Cloning boot volume..."
echo ""

BOOT_NAME="${CLONE_PREFIX}-boot"
echo "  Clone name: ${BOOT_NAME}"

CLONE_RESPONSE=$(ibmcloud pi volume clone-async create "$BOOT_NAME" \
    --volumes "$PRIMARY_BOOT_ID" \
    --json 2>/dev/null)

CLONE_TASK_ID=$(echo "$CLONE_RESPONSE" | jq -r '.id')
if [[ -z "$CLONE_TASK_ID" || "$CLONE_TASK_ID" == "null" ]]; then
    echo "✗ ERROR: Could not initiate boot volume clone"
    exit 1
fi
echo "  ✓ Clone task initiated: ${CLONE_TASK_ID}"
echo ""

wait_for_clone_job "$CLONE_TASK_ID"

# Extract cloned boot volume ID
CLONE_BOOT_ID=$(ibmcloud pi volume clone-async get "$CLONE_TASK_ID" --json \
    | jq -r '.clonedVolumes[0].volumeID')

if [[ -z "$CLONE_BOOT_ID" || "$CLONE_BOOT_ID" == "null" ]]; then
    echo "✗ ERROR: Could not retrieve cloned boot volume ID"
    exit 1
fi
echo "  ✓ Boot volume cloned successfully: ${CLONE_BOOT_ID}"
echo ""

# ------------------------------------------------------------------------------
# STAGE 3d: Clone Data Volumes (if any)
# ------------------------------------------------------------------------------
if [[ -n "$PRIMARY_DATA_IDS" ]]; then
    FAILED_STAGE="CLONE_DATA_VOLUMES"
    
    echo "→ Stage 3d: Cloning data volumes..."
    echo ""
    
    DATA_NAME="${CLONE_PREFIX}-data"
    echo "  Clone name: ${DATA_NAME}"
    
    DATA_CLONE_RESPONSE=$(ibmcloud pi volume clone-async create "$DATA_NAME" \
        --volumes "$PRIMARY_DATA_IDS" \
        --json 2>/dev/null)
    
    DATA_TASK_ID=$(echo "$DATA_CLONE_RESPONSE" | jq -r '.id')
    if [[ -z "$DATA_TASK_ID" || "$DATA_TASK_ID" == "null" ]]; then
        echo "✗ ERROR: Could not initiate data volume clone"
        exit 1
    fi
    echo "  ✓ Clone task initiated: ${DATA_TASK_ID}"
    echo ""
    
    wait_for_clone_job "$DATA_TASK_ID"
    
    # Extract cloned data volume IDs
    CLONE_DATA_IDS=$(ibmcloud pi volume clone-async get "$DATA_TASK_ID" --json \
        | jq -r '[.clonedVolumes[].volumeID] | join(",")')
    
    if [[ -z "$CLONE_DATA_IDS" || "$CLONE_DATA_IDS" == "null" ]]; then
        echo "✗ ERROR: Could not retrieve cloned data volume IDs"
        exit 1
    fi
    echo "  ✓ Data volumes cloned successfully"
    echo ""
else
    echo "→ No data volumes to clone - skipping"
    echo ""
fi

echo "------------------------------------------------------------------------"
echo " Stage 3 Complete: IBMi prepared and volumes cloned"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# STAGE 4: RESOLVE SECONDARY LPAR & ATTACH VOLUMES
################################################################################
FAILED_STAGE="RESOLVE_SECONDARY_LPAR"

echo "========================================================================"
echo " STAGE 4/5: RESOLVE SECONDARY LPAR & ATTACH VOLUMES"
echo "========================================================================"
echo ""

echo "→ Resolving secondary LPAR instance ID: ${SECONDARY_LPAR}..."

SECONDARY_INSTANCE_ID=$(ibmcloud pi instances --json 2>/dev/null \
    | jq -r --arg name "$SECONDARY_LPAR" \
    '.pvmInstances[]? | select(.name == $name) | .id' \
    | head -n 1)

if [[ -z "$SECONDARY_INSTANCE_ID" || "$SECONDARY_INSTANCE_ID" == "null" ]]; then
    echo "✗ ERROR: Could not find secondary LPAR: ${SECONDARY_LPAR}"
    exit 1
fi
echo "✓ Secondary LPAR resolved: ${SECONDARY_INSTANCE_ID}"
echo ""

# ------------------------------------------------------------------------------
# Attach Boot Volume
# ------------------------------------------------------------------------------
FAILED_STAGE="ATTACH_BOOT_VOLUME"

echo "→ Attaching boot volume to secondary LPAR..."

ibmcloud pi instance attach "$SECONDARY_INSTANCE_ID" \
    --volume "$CLONE_BOOT_ID" > /dev/null 2>&1 || {
    echo "✗ ERROR: Failed to attach boot volume"
    exit 1
}
echo "  ✓ Boot volume attached: ${CLONE_BOOT_ID}"
echo ""

# ------------------------------------------------------------------------------
# Attach Data Volumes
# ------------------------------------------------------------------------------
if [[ -n "$CLONE_DATA_IDS" ]]; then
    FAILED_STAGE="ATTACH_DATA_VOLUMES"
    
    echo "→ Attaching data volumes to secondary LPAR..."
    
    IFS=',' read -ra DATA_VOLS <<<"$CLONE_DATA_IDS"
    for vol in "${DATA_VOLS[@]}"; do
        echo "  Attaching: ${vol}..."
        ibmcloud pi instance attach "$SECONDARY_INSTANCE_ID" \
            --volume "$vol" > /dev/null 2>&1 || {
            echo "✗ ERROR: Failed to attach volume ${vol}"
            exit 1
        }
    done
    echo "  ✓ All data volumes attached"
    echo ""
fi

# ------------------------------------------------------------------------------
# Wait for Attachments to Complete
# ------------------------------------------------------------------------------
echo "→ Waiting ${INITIAL_WAIT} seconds for volume attachments to stabilize..."
sleep "$INITIAL_WAIT"
echo ""

# Verify all volumes are attached
TOTAL_VOLUME_COUNT=1  # Boot volume
if [[ -n "$CLONE_DATA_IDS" ]]; then
    DATA_VOL_COUNT=$(echo "$CLONE_DATA_IDS" | tr ',' '\n' | wc -l | tr -d ' ')
    TOTAL_VOLUME_COUNT=$((TOTAL_VOLUME_COUNT + DATA_VOL_COUNT))
fi

echo "→ Verifying volume attachment status..."
ATTACHED_COUNT=$(ibmcloud pi instance get "$SECONDARY_INSTANCE_ID" --json 2>/dev/null \
    | jq '.volumeIDs | length')

if [[ "$ATTACHED_COUNT" -ne "$TOTAL_VOLUME_COUNT" ]]; then
    echo "✗ ERROR: Volume count mismatch (Expected: ${TOTAL_VOLUME_COUNT}, Found: ${ATTACHED_COUNT})"
    exit 1
fi
echo "  ✓ All ${TOTAL_VOLUME_COUNT} volumes verified as attached"
echo ""

echo "------------------------------------------------------------------------"
echo " Stage 4 Complete: All volumes attached to secondary LPAR"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# STAGE 5: BOOT CONFIGURATION & STARTUP
################################################################################
FAILED_STAGE="BOOT_CONFIG"

# --- Check if we need to run STAGE 5 ---
if [[ ${RESUME_AT_STAGE_5} -eq 1 ]]; then
    echo "→ RESUME_AT_STAGE_5 flag is set — skipping to LPAR startup"
    echo ""
fi

echo "========================================================================"
echo " STAGE 5/5: BOOT CONFIGURATION & LPAR STARTUP"
echo "========================================================================"
echo ""

if [[ ${RESUME_AT_STAGE_5} -ne 1 ]]; then
    echo "→ Configuring boot volume as primary bootable device..."

    ibmcloud pi instance update "$SECONDARY_INSTANCE_ID" \
        --boot-volume "$CLONE_BOOT_ID" > /dev/null 2>&1 || {
        echo "✗ ERROR: Failed to configure boot volume"
        exit 1
    }
    echo "  ✓ Boot volume configured: ${CLONE_BOOT_ID}"
    echo ""
fi

###############################################################################
# START LPAR (WITH RETRY LOGIC)
###############################################################################

FAILED_STAGE="STARTUP"

if [[ ${RESUME_AT_STAGE_5} -ne 1 ]]; then
    echo "→ Starting secondary LPAR in NORMAL boot mode..."
    echo ""

    IN_START_RETRY=1   # <<< ENTER RETRY MODE
    START_SUCCESS=0
    START_ATTEMPTS=0
    MAX_START_ATTEMPTS=3

    while [[ $START_ATTEMPTS -lt $MAX_START_ATTEMPTS && $START_SUCCESS -ne 1 ]]; do
        START_ATTEMPTS=$((START_ATTEMPTS + 1))
        echo "  Start attempt ${START_ATTEMPTS}/${MAX_START_ATTEMPTS}..."

        set +e
        ibmcloud pi instance start "$SECONDARY_INSTANCE_ID" > /dev/null 2>&1
        START_RC=$?
        set -e

        if [[ $START_RC -eq 0 ]]; then
            echo "  ✓ Start command accepted"
            START_SUCCESS=1
            break
        fi

        # Capture error message
        START_ERROR=$(ibmcloud pi instance start "$SECONDARY_INSTANCE_ID" 2>&1 || true)

        # Check if error is retryable
        if echo "$START_ERROR" | grep -qi "attaching"; then
            echo "⚠ Instance still attaching volumes — retrying"
        else
            echo "✗ Non-retryable start failure"
            FAILED_STAGE="STARTUP"
            unset IN_START_RETRY
            exit 1
        fi

        sleep 60
    done

    unset IN_START_RETRY   # <<< EXIT RETRY MODE

    if [[ $START_SUCCESS -ne 1 ]]; then
        FAILED_STAGE="STARTUP"
        exit 1
    fi
fi

###############################################################################
# WAIT FOR ACTIVE
###############################################################################

echo ""
echo "→ Waiting for LPAR to reach ACTIVE state..."
echo ""

BOOT_ELAPSED=0

while [[ $BOOT_ELAPSED -lt $MAX_BOOT_WAIT ]]; do
    set +e
    STATUS=$(ibmcloud pi instance get "$SECONDARY_INSTANCE_ID" --json 2>/dev/null \
        | jq -r '.status // "UNKNOWN"')
    set -e

    echo "  LPAR status: ${STATUS} (elapsed ${BOOT_ELAPSED}s)"

    if [[ "$STATUS" == "ACTIVE" ]]; then
        echo "✓ LPAR is ACTIVE"
        break
    fi

    if [[ "$STATUS" == "ERROR" ]]; then
        FAILED_STAGE="STARTUP"
        exit 1
    fi

    sleep "$POLL_INTERVAL"
    BOOT_ELAPSED=$((BOOT_ELAPSED + POLL_INTERVAL))
done

if [[ "$STATUS" != "ACTIVE" ]]; then
    FAILED_STAGE="STARTUP"
    exit 1
fi


echo ""
echo "------------------------------------------------------------------------"
echo " Stage 5 Complete: LPAR booted successfully"
echo "------------------------------------------------------------------------"
echo ""


#echo ""
#echo "------------------------------------------------------------------------"
#echo " Waiting 3 minutes for LPAR stabilization..."
#echo "------------------------------------------------------------------------"
#echo ""
#sleep 180

###############################################################################
# FINAL VALIDATION & SUMMARY
###############################################################################

echo ""
echo "========================================================================"
echo " JOB 2: COMPLETION SUMMARY"
echo "========================================================================"
echo ""

# --- Safely retrieve final status ---
set +e
INSTANCE_JSON=$(ibmcloud pi instance get "$SECONDARY_INSTANCE_ID" --json 2>/dev/null)
RC=$?
set -e

if [[ $RC -ne 0 || -z "$INSTANCE_JSON" ]]; then
    echo "✗ ERROR: Unable to retrieve final LPAR status"
    FAILED_STAGE="FINAL_STATUS_CHECK"
    exit 1   # EXIT trap WILL run
fi

FINAL_STATUS=$(echo "$INSTANCE_JSON" | jq -r '.status // "UNKNOWN"')

echo "→ Final LPAR status check: ${FINAL_STATUS}"
echo ""

# --- FAILURE PATH ---
if [[ "$FINAL_STATUS" != "ACTIVE" ]]; then
    echo ""
    echo "========================================================================"
    echo " FINAL STATE CHECK FAILED"
    echo "========================================================================"
    echo ""
    echo "✗ Secondary LPAR did not remain ACTIVE"
    echo "  Final status: ${FINAL_STATUS}"
    echo ""

    FAILED_STAGE="FINAL_STATUS_CHECK"
    exit 1   # EXIT trap WILL run
fi

# ===========================
# SUCCESS PATH (NO EXITS ABOVE THIS)
# ===========================

echo "========================================================================"
echo " JOB COMPLETED SUCCESSFULLY"
echo "========================================================================"
echo ""
echo "  Status:                  ✓ SUCCESS"
echo "  Primary LPAR:            ${PRIMARY_LPAR}"
echo "  Secondary LPAR:          ${SECONDARY_LPAR}"
echo "  Secondary Instance ID:   ${SECONDARY_INSTANCE_ID}"
echo "  Final Status:            ${FINAL_STATUS}"
echo "  ────────────────────────────────────────────────────────────────"
echo "  Volumes Cloned:          ✓ Yes"
echo ""
echo "  Boot Volume:"
echo "    - ${CLONE_BOOT_ID}"
echo ""

echo "  Data Volumes:"
if [[ -n "$CLONE_DATA_IDS" ]]; then
    IFS=',' read -ra _DATA_VOLS <<<"$CLONE_DATA_IDS"
    for VOL in "${_DATA_VOLS[@]}"; do
        echo "    - ${VOL}"
    done
else
    echo "    - None"
fi
unset _DATA_VOLS

echo ""
echo "  Volumes Attached:        ✓ Yes (${TOTAL_VOLUME_COUNT} total)"
echo "  Boot Mode:               ✓ NORMAL (Mode A)"
echo "  ────────────────────────────────────────────────────────────────"
echo "  Clone Prefix:            ${CLONE_PREFIX}"
echo ""
echo "========================================================================"
echo ""


: <<'COMMENT'
echo "========================================================================"
echo " JOB COMPLETED SUCCESSFULLY"
echo "========================================================================"
echo ""
echo "  Status:                  ✓ SUCCESS"
echo "  Primary LPAR:            ${PRIMARY_LPAR}"
echo "  Secondary LPAR:          ${SECONDARY_LPAR}"
echo "  Secondary Instance ID:   ${SECONDARY_INSTANCE_ID}"
echo "  Final Status:            ${FINAL_STATUS}"
echo "  ────────────────────────────────────────────────────────────────"
echo "  Volumes Cloned:          ✓ Yes"
echo "  Boot Volume:             ${CLONE_BOOT_ID}"
echo "  Data Volumes:            ${CLONE_DATA_IDS:-None}"
echo "  Volumes Attached:        ✓ Yes"
echo "  Boot Mode:               ✓ NORMAL (Mode A)"
echo "  ────────────────────────────────────────────────────────────────"
echo "  Clone Prefix:            ${CLONE_PREFIX}"
echo ""
echo "========================================================================"
echo ""
COMMENT



################################################################################
# OPTIONAL STAGE: TRIGGER CLEANUP JOB (Job 3)
################################################################################
echo "========================================================================"
echo " OPTIONAL STAGE: CHAIN TO CLEANUP PROCESS"
echo "========================================================================"
echo ""

if [[ "${RUN_CLEANUP_JOB:-No}" == "Yes" ]]; then
    echo "→ Proceed to Environment Cleanup has been requested - triggering Job 3..."

    echo " targeting new resource group.."
    ibmcloud target -g cloud-techsales || {
        echo "⚠ WARNING: Unable to target resource group"
    }

    echo "  Switching to Code Engine project: usnm-project..."
    ibmcloud ce project target --name usnm-project > /dev/null 2>&1 || {
        echo "⚠ WARNING: Unable to target Code Engine project 'usnm-project'"
    }

    echo "  Submitting Code Engine job: snap-ops-3..."

    # Capture output but do not fail job
    RAW_SUBMISSION=$(ibmcloud ce jobrun submit \
        --job snap-ops-3 \
        --output json 2>&1 || true)

    NEXT_RUN=$(echo "$RAW_SUBMISSION" | jq -r '.metadata.name // .name // empty' 2>/dev/null || true)

    if [[ -z "$NEXT_RUN" ]]; then
        echo "⚠ WARNING: Cleanup job submission did not return a jobrun name"
        echo ""
        echo "Raw output:"
        echo "$RAW_SUBMISSION"
    else
        echo "✓ Environment Cleanup triggered successfully"
        echo "  Jobrun instance: ${NEXT_RUN}"
    fi
else
    echo "→ Proceed to Environment Cleanup not set - skipping Job 3"
    echo "  ${SECONDARY_LPAR} is ${FINAL_STATUS} and the IPL is underway.."
    echo "  ....will be ready for BRMS Backup Operations momentarily"
fi

echo ""
echo ""

# --- Mark success FIRST ---
JOB_SUCCESS=1

# --- Disable cleanup trap ONLY AFTER success ---
trap - ERR EXIT


# --- Allow logger to flush ---
sleep 60     #dont use 1m
echo "Closing down Job 2, this will take approximately 60 seconds"
echo ""


echo ""
echo "========================================================================"
echo ""

exit 0
