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
readonly PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::"
readonly CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a"

# LPAR Configuration
readonly PRIMARY_LPAR="get-snapshot"              # Source LPAR for cloning
readonly PRIMARY_INSTANCE_ID="113196d1-1ee2-4815-8cfe-14df1ddedb59"
readonly SECONDARY_LPAR="empty-ibmi-lpar"               # Target LPAR for restore
readonly STORAGE_TIER="tier3"                     # Must match source tier

# Naming Convention - Clone YYYY-MM-DD-HH-MM
readonly CLONE_PREFIX="get-snapshot-$(date +"%Y%m%d%H%M")"

# Polling Configuration
readonly POLL_INTERVAL=30
readonly INITIAL_WAIT=30
readonly MAX_ATTACH_WAIT=420
readonly MAX_BOOT_WAIT=1200

# Runtime State Variables (Tracked for Cleanup)
PRIMARY_BOOT_ID=""
PRIMARY_DATA_IDS=""
SECONDARY_INSTANCE_ID=""
CLONE_BOOT_ID=""
CLONE_DATA_IDS=""
CLONE_TASK_ID=""
JOB_SUCCESS=0

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
        ATTACH_VOLUME|BOOT_CONFIG|STARTUP)
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

###############################################################################
# RESUME / GUARDRAIL CHECK
###############################################################################

echo "========================================================================"
echo " Checking LPAR for existing attached Boot volume"
echo "========================================================================"
echo ""

###############################################################################
# ENSURE SECONDARY_INSTANCE_ID IS KNOWN (FOR RESUME CHECK)
###############################################################################

echo "→ Resolving secondary LPAR instance ID..."

SECONDARY_INSTANCE_ID=$(ibmcloud pi instance list --json 2>/dev/null \
    | jq -r --arg N "$SECONDARY_LPAR" \
      '.pvmInstances[] | select(.name==$N) | .id' \
    | head -n 1)

if [[ -z "$SECONDARY_INSTANCE_ID" || "$SECONDARY_INSTANCE_ID" == "null" ]]; then
    echo "✗ ERROR: Secondary LPAR '${SECONDARY_LPAR}' not found"
    exit 1
fi

echo "✓ Secondary LPAR ID: ${SECONDARY_INSTANCE_ID}"

echo "→ Checking attached volumes on secondary LPAR..."

VOLUME_JSON=$(ibmcloud pi instance volume list "$SECONDARY_INSTANCE_ID" --json 2>/dev/null)

BOOT_VOLUMES=$(echo "$VOLUME_JSON" | jq '[.volumes[] | select(.bootable == true)] | length')
TOTAL_VOLUMES=$(echo "$VOLUME_JSON" | jq '.volumes | length')

echo "  Total attached volumes: ${TOTAL_VOLUMES}"
echo "  Bootable volumes       : ${BOOT_VOLUMES}"
echo ""

if [[ "$BOOT_VOLUMES" -ge 1 ]]; then
    echo "✓ Boot volume detected"
    echo "✓ Skipping directly to Stage 5 (boot/start only)"
    RESUME_AT_STAGE_5=1



################################################################################
# STAGE 2: IDENTIFY VOLUMES ON PRIMARY LPAR
# Logic:
#   1. Resolve secondary LPAR instance ID (needed for later stages)
#   2. Query volumes attached to primary LPAR
#   3. Parse JSON to identify boot vs data volumes
#   4. Extract volume IDs for cloning
################################################################################


echo "========================================================================"
echo " STAGE 2/5: IDENTIFY VOLUMES ON PRIMARY LPAR"
echo "========================================================================"
echo ""

# -------------------------------------------------------------------------
# STEP 1: Resolve secondary LPAR instance ID
# -------------------------------------------------------------------------
echo "→ Secondary LPAR resolved in previous step..."

#SECONDARY_INSTANCE_ID=$(ibmcloud pi instance list --json \
#    | jq -r ".pvmInstances[] | select(.name == \"$SECONDARY_LPAR\") | .id")

#if [[ -z "$SECONDARY_INSTANCE_ID" ]]; then
#    echo "✗ ERROR: Secondary LPAR not found: ${SECONDARY_LPAR}"
#    exit 1
#fi

#echo "✓ Secondary LPAR found"
echo "  Name: ${SECONDARY_LPAR}"
echo "  Instance ID: ${SECONDARY_INSTANCE_ID}"
echo ""

# -------------------------------------------------------------------------
# STEP 2: Query primary LPAR volumes
# -------------------------------------------------------------------------
echo "→ Querying volumes on primary LPAR: ${PRIMARY_LPAR}..."

PRIMARY_VOLUME_DATA=$(ibmcloud pi ins vol ls "$PRIMARY_INSTANCE_ID" --json 2>/dev/null)


# -------------------------------------------------------------------------
# STEP 3: Extract boot and data volume IDs
# -------------------------------------------------------------------------


echo "→ Identifying boot and data volumes..."

# Extract boot volume ID (where bootVolume is true)
PRIMARY_BOOT_ID=$(echo "$PRIMARY_VOLUME_DATA" | jq -r '
    .volumes[]? | select(.bootVolume == true) | .volumeID
' | head -n 1)

# Extract data volume IDs (where bootVolume is false or null)
PRIMARY_DATA_IDS=$(echo "$PRIMARY_VOLUME_DATA" | jq -r '
    .volumes[]? | select(.bootVolume != true) | .volumeID
' | paste -sd "," -)

if [[ -z "$PRIMARY_BOOT_ID" ]]; then
    echo "✗ ERROR: No boot volume found on primary LPAR"
    exit 1
fi

# Build complete volume ID list for cloning
if [[ -n "$PRIMARY_DATA_IDS" ]]; then
    PRIMARY_VOLUME_IDS="${PRIMARY_BOOT_ID},${PRIMARY_DATA_IDS}"
else
    PRIMARY_VOLUME_IDS="${PRIMARY_BOOT_ID}"
fi

echo "✓ Volumes identified on primary LPAR"
echo "  Boot volume:  ${PRIMARY_BOOT_ID}"
echo "  Data volumes: ${PRIMARY_DATA_IDS:-None}"
echo "  Total volumes to clone: ${PRIMARY_VOLUME_IDS}"



echo ""
echo "------------------------------------------------------------------------"
echo " Stage 2 Complete: Volume identification complete"
echo "------------------------------------------------------------------------"
echo ""


echo "========================================================================"
echo " STAGE 3/5: CLONE VOLUMES & VERIFY AVAILABILITY"
echo "========================================================================"
echo ""

echo "→ Submitting clone request..."
echo "  Clone prefix: ${CLONE_PREFIX}"
echo "  Storage tier: ${STORAGE_TIER}"
echo "  Source volumes: ${PRIMARY_VOLUME_IDS}"

CLONE_JSON=$(ibmcloud pi volume clone-async create "$CLONE_PREFIX" \
    --target-tier "$STORAGE_TIER" \
    --volumes "$PRIMARY_VOLUME_IDS" \
    --json) || {
        echo "✗ ERROR: Clone request failed"
        exit 1
}

CLONE_TASK_ID=$(echo "$CLONE_JSON" | jq -r '.cloneTaskID')

if [[ -z "$CLONE_TASK_ID" || "$CLONE_TASK_ID" == "null" ]]; then
    echo "✗ ERROR: cloneTaskID not returned"
    echo "$CLONE_JSON"
    exit 1
fi

echo "✓ Clone request submitted"
echo "  Clone task ID: ${CLONE_TASK_ID}"


# Wait for clone job to complete
wait_for_clone_job "$CLONE_TASK_ID"

echo ""
echo "→ Extracting cloned volume IDs..."

CLONE_RESULT=$(ibmcloud pi volume clone-async get "$CLONE_TASK_ID" --json)

# Extract boot volume clone
CLONE_BOOT_ID=$(echo "$CLONE_RESULT" \
  | jq -r --arg boot "$PRIMARY_BOOT_ID" '
      .clonedVolumes[]
      | select(.sourceVolumeID == $boot)
      | .clonedVolumeID
  ')

# Extract data volume clones (if any)
if [[ -n "$PRIMARY_DATA_IDS" ]]; then
  CLONE_DATA_IDS=$(echo "$CLONE_RESULT" \
    | jq -r --arg boot "$PRIMARY_BOOT_ID" '
        .clonedVolumes[]
        | select(.sourceVolumeID != $boot)
        | .clonedVolumeID
    ' | paste -sd "," -)
fi

# Validation
if [[ -z "$CLONE_BOOT_ID" ]]; then
  echo "✗ ERROR: Failed to identify cloned boot volume"
  echo "$CLONE_RESULT"
  exit 1
fi

echo "✓ Cloned volume IDs extracted"
echo "  Boot volume: ${CLONE_BOOT_ID}"
echo "  Data volumes: ${CLONE_DATA_IDS:-None}"
echo ""


echo "→ Verifying cloned volumes are available..."

# Verify boot volume
while true; do
    BOOT_STATUS=$(ibmcloud pi volume get "$CLONE_BOOT_ID" --json \
        | jq -r '.state | ascii_downcase')
    
    if [[ "$BOOT_STATUS" == "available" ]]; then
        echo "✓ Boot volume available: ${CLONE_BOOT_ID}"
        break
    fi
    
    echo "  Boot volume status: ${BOOT_STATUS} - waiting..."
    sleep "$POLL_INTERVAL"
done

# Verify data volumes (if any)
if [[ -n "$CLONE_DATA_IDS" ]]; then
    for VOL in ${CLONE_DATA_IDS//,/ }; do
        while true; do
            DATA_STATUS=$(ibmcloud pi volume get "$VOL" --json \
                | jq -r '.state | ascii_downcase')
            
            if [[ "$DATA_STATUS" == "available" ]]; then
                echo "✓ Data volume available: ${VOL}"
                break
            fi
            
            echo "  Data volume status: ${DATA_STATUS} - waiting..."
            sleep "$POLL_INTERVAL"
        done
    done
fi

echo ""
echo "------------------------------------------------------------------------"
echo " Stage 3 Complete: All volumes cloned and verified available"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# STAGE 4: ATTACH VOLUMES TO SECONDARY LPAR
# Logic:
#   1. Attach boot volume and data volumes (if any)
#   2. Wait for initial stabilization
#   3. Poll until all volumes appear in instance volume list
################################################################################
echo "========================================================================"
echo " STAGE 4/5: ATTACH VOLUMES TO SECONDARY LPAR"
echo "========================================================================"
echo ""

echo "→ Attaching volumes to secondary LPAR..."
echo "  LPAR: ${SECONDARY_LPAR}"
echo "  Instance ID: ${SECONDARY_INSTANCE_ID}"
echo ""

# --- Submit attachment request ---
if [[ -n "$CLONE_DATA_IDS" ]]; then
    echo "  Attaching boot + data volumes..."
    ibmcloud pi instance volume attach "$SECONDARY_INSTANCE_ID" \
        --volumes "$CLONE_DATA_IDS" \
        --boot-volume "$CLONE_BOOT_ID" \
        >/dev/null 2>&1 || {
            echo "✗ ERROR: Volume attachment failed"
            exit 1
        }
else
    echo "  Attaching boot volume only..."
    ibmcloud pi instance volume attach "$SECONDARY_INSTANCE_ID" \
        --boot-volume "$CLONE_BOOT_ID" \
        >/dev/null 2>&1 || {
            echo "✗ ERROR: Boot volume attachment failed"
            exit 1
        }
fi

echo "✓ Attachment request accepted"
echo ""

# --- Initial backend settle delay ---
echo "→ Waiting ${INITIAL_WAIT}s for backend stabilization..."
sleep "$INITIAL_WAIT"
echo ""

# --- Poll for attachment confirmation ---
echo "→ Polling for volume attachment confirmation..."

ELAPSED=0

while true; do
    VOL_LIST=$(ibmcloud pi instance volume list "$SECONDARY_INSTANCE_ID" --json 2>/dev/null \
        | jq -r '(.volumes // [])[]?.volumeID')

    # Assume success until proven otherwise
    BOOT_ATTACHED=false
    DATA_ATTACHED=true

    # Check boot volume
    if grep -qx "$CLONE_BOOT_ID" <<<"$VOL_LIST"; then
        BOOT_ATTACHED=true
    fi

    # Check data volumes (if any)
    if [[ -n "$CLONE_DATA_IDS" ]]; then
        for VOL in ${CLONE_DATA_IDS//,/ }; do
            if ! grep -qx "$VOL" <<<"$VOL_LIST"; then
                DATA_ATTACHED=false
                break
            fi
        done
    fi

    if [[ "$BOOT_ATTACHED" == "true" && "$DATA_ATTACHED" == "true" ]]; then
        echo "✓ All volumes confirmed attached"
        break
    fi

    if (( ELAPSED >= MAX_ATTACH_WAIT )); then
        echo "✗ ERROR: Volumes not attached after ${MAX_ATTACH_WAIT}s"
        exit 1
    fi

    echo "  Volumes not fully visible yet - checking again in ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

echo ""
echo "------------------------------------------------------------------------"
echo " Stage 4 Complete: Volumes attached and verified"
echo "------------------------------------------------------------------------"
echo ""

else
    echo "✓ No boot volume attached"
    echo "✓ Running full workflow from the beginning"
    RESUME_AT_STAGE_5=0
fi


################################################################################
# STAGE 5: BOOT SECONDARY LPAR
# Logic:
#   1. Check current LPAR status
#   2. If not ACTIVE, configure boot mode and start LPAR
#   3. Poll status until ACTIVE or timeout
#   4. Handle ERROR state as failure
################################################################################
echo "========================================================================"
echo " STAGE 5/5: BOOT SECONDARY LPAR"
echo "========================================================================"
echo ""

echo "→ Checking current LPAR status..."

CURRENT_STATUS=$(ibmcloud pi instance get "$SECONDARY_INSTANCE_ID" --json 2>/dev/null \
    | jq -r '.status')

echo "  Current status: ${CURRENT_STATUS}"
echo ""

if [[ "$CURRENT_STATUS" != "ACTIVE" ]]; then

    #
    # ─────────────────────────────────────────────────────────────
    # Step 1: Configure boot mode (retry once on failure)
    # ─────────────────────────────────────────────────────────────
    #
    echo "→ Configuring boot mode (NORMAL)..."

    BOOTCFG_ATTEMPT=1
    MAX_BOOTCFG_ATTEMPTS=2
    BOOTCFG_SUCCESS=0

    while [[ $BOOTCFG_ATTEMPT -le $MAX_BOOTCFG_ATTEMPTS ]]; do
        echo "  Boot config attempt ${BOOTCFG_ATTEMPT}/${MAX_BOOTCFG_ATTEMPTS}"

        BOOTCFG_OUTPUT=$(ibmcloud pi instance operation "$SECONDARY_INSTANCE_ID" \
            --operation-type boot \
            --boot-mode a \
            --boot-operating-mode normal 2>&1)

        echo "$BOOTCFG_OUTPUT"

        if echo "$BOOTCFG_OUTPUT" | grep -q "Operation boot complete for instance"; then
            echo "✓ Boot mode configured"
            BOOTCFG_SUCCESS=1
            break
        fi

        echo "⚠ Boot configuration did not complete successfully"

        if [[ $BOOTCFG_ATTEMPT -lt $MAX_BOOTCFG_ATTEMPTS ]]; then
            echo "→ Retrying boot configuration in 60 seconds..."
            sleep 60
        fi

        BOOTCFG_ATTEMPT=$((BOOTCFG_ATTEMPT + 1))
    done

    if [[ $BOOTCFG_SUCCESS -ne 1 ]]; then
        echo ""
        echo "✗ ERROR: Boot configuration failed after ${MAX_BOOTCFG_ATTEMPTS} attempts"
        echo "✗ Critical failure — volumes will NOT be detached or deleted"
        exit 1
    fi

    echo ""

    #
    # ─────────────────────────────────────────────────────────────
    # Step 2: Start LPAR (retry up to 3 attempts)
    # ─────────────────────────────────────────────────────────────
    #
    echo "→ Starting LPAR..."

    START_ATTEMPT=1
    MAX_START_ATTEMPTS=3
    START_SUCCESS=0

    while [[ $START_ATTEMPT -le $MAX_START_ATTEMPTS ]]; do
        echo "  Start attempt ${START_ATTEMPT}/${MAX_START_ATTEMPTS}"

        START_OUTPUT=$(ibmcloud pi instance action "$SECONDARY_INSTANCE_ID" \
            --operation start 2>&1)

        if [[ $? -eq 0 ]]; then
            echo "$START_OUTPUT"
            echo "✓ Start command accepted"
            START_SUCCESS=1
            break
        fi

        STATUS=$(ibmcloud pi instance get "$SECONDARY_INSTANCE_ID" --json 2>/dev/null \
            | jq -r '.status')

        if [[ "$STATUS" == "STARTING" ]]; then
            echo "✓ LPAR is already STARTING"
            START_SUCCESS=1
            break
        fi

        echo "⚠ Start failed:"
        echo "$START_OUTPUT"

        if [[ $START_ATTEMPT -lt $MAX_START_ATTEMPTS ]]; then
            echo "→ Retrying start in 60 seconds..."
            sleep 60
        fi

        START_ATTEMPT=$((START_ATTEMPT + 1))
    done

    if [[ $START_SUCCESS -ne 1 ]]; then
        echo ""
        echo "✗ ERROR: LPAR start failed after ${MAX_START_ATTEMPTS} attempts"
        echo "✗ Critical failure — volumes will NOT be detached or deleted"
        exit 1
    fi

else
    echo "  LPAR already ACTIVE - skipping boot sequence"
fi

echo ""
echo "→ Waiting for LPAR to reach ACTIVE state..."
echo "  (Max wait: $(($MAX_BOOT_WAIT/60)) minutes)"
echo ""

BOOT_ELAPSED=0

while true; do
    STATUS=$(ibmcloud pi instance get "$SECONDARY_INSTANCE_ID" --json 2>/dev/null \
        | jq -r '.status')

    echo "  LPAR status: ${STATUS} (elapsed: ${BOOT_ELAPSED}s)"

    if [[ "$STATUS" == "ACTIVE" ]]; then
        echo ""
        echo "✓ LPAR is ACTIVE"
        JOB_SUCCESS=1
        break
    fi

    if [[ "$STATUS" == "ERROR" ]]; then
        echo ""
        echo "✗ ERROR: LPAR entered ERROR state during boot"
        echo "✗ Critical failure — volumes will NOT be detached or deleted"
        exit 1
    fi

    if [[ $BOOT_ELAPSED -ge $MAX_BOOT_WAIT ]]; then
        echo ""
        echo "✗ ERROR: LPAR failed to reach ACTIVE state within $(($MAX_BOOT_WAIT/60)) minutes"
        echo "✗ Critical failure — volumes will NOT be detached or deleted"
        exit 1
    fi

    sleep "$POLL_INTERVAL"
    BOOT_ELAPSED=$((BOOT_ELAPSED + POLL_INTERVAL))
done


echo ""
echo "------------------------------------------------------------------------"
echo " Stage 5 Complete: LPAR booted successfully"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# FINAL VALIDATION & SUMMARY
################################################################################
echo ""
echo "========================================================================"
echo " JOB 2: COMPLETION SUMMARY"
echo "========================================================================"
echo ""

# Final status readback (with error handling)
set +e
FINAL_CHECK=$(ibmcloud pi instance get "$SECONDARY_INSTANCE_ID" --json 2>/dev/null)
FINAL_STATUS=$(echo "$FINAL_CHECK" | jq -r '.status // "ACTIVE"' 2>/dev/null)
set -e

echo "  Status:                  ✓ SUCCESS"
echo "  ────────────────────────────────────────────────────────────────"
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

# Disable cleanup trap - job completed successfully
trap - ERR EXIT

################################################################################
# OPTIONAL STAGE: TRIGGER CLEANUP JOB (Job 3)
################################################################################
echo "========================================================================"
echo " OPTIONAL STAGE: CHAIN TO CLEANUP PROCESS"
echo "========================================================================"
echo ""

if [[ "${RUN_CLEANUP_JOB:-No}" == "Yes" ]]; then
    echo "→ Environment cleanup requested - triggering Job 3..."
    
    echo "  Switching to Code Engine project: IBMi..."
    ibmcloud ce project target --name IBMi > /dev/null 2>&1 || {
        echo "✗ ERROR: Unable to target Code Engine project 'IBMi'"
        exit 1
    }
    
    echo "  Submitting Code Engine job: snap-ops-3..."
    
    RAW_SUBMISSION=$(ibmcloud ce jobrun submit \
        --job snap-ops-3 \
        --output json 2>&1)
    
    NEXT_RUN=$(echo "$RAW_SUBMISSION" | jq -r '.metadata.name // .name // empty' 2>/dev/null || true)
    
    if [[ -z "$NEXT_RUN" ]]; then
        echo "✗ ERROR: Job submission failed - no jobrun name returned"
        echo ""
        echo "Raw output:"
        echo "$RAW_SUBMISSION"
        exit 1
    fi
    
    echo "✓ Environment Cleanup triggered successfully"
    echo "  Jobrun instance: ${NEXT_RUN}"
else
    echo "→ Proceed to Environment Cleanup not requested"
    echo "  ${SECONDARY_LPAR} is ${FINAL_STATUS} and ready for BRMS Backup Operations "
fi

echo ""
echo "========================================================================"
echo ""

JOB_SUCCESS=1
sleep 1
exit 0
