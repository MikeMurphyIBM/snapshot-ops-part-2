#!/usr/bin/env bash

################################################################################
# JOB 2: SNAPSHOT/CLONE/RESTORE OPERATIONS
# Purpose: Snapshot primary LPAR, clone volumes, attach to secondary LPAR, boot
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

################################################################################
# BANNER
################################################################################
echo ""
echo "========================================================================"
echo " JOB 2: SNAPSHOT/CLONE/RESTORE OPERATIONS"
echo " Purpose: Backup primary LPAR and restore to secondary LPAR"
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
readonly PRIMARY_LPAR="get-snapshot"              # Source LPAR for snapshot
readonly PRIMARY_INSTANCE_ID="c92f6904-8bd2-4093-acec-f641899cd658"
readonly SECONDARY_LPAR="manhattan"         # Target LPAR for restore
readonly STORAGE_TIER="tier3"                     # Must match snapshot tier

# Naming Convention
readonly CLONE_PREFIX="manhattan-$(date +"%Y%m%d%H%M")"
readonly SNAPSHOT_NAME="${CLONE_PREFIX}"

# Polling Configuration
readonly POLL_INTERVAL=30
readonly SNAPSHOT_POLL_INTERVAL=45
readonly INITIAL_WAIT=30
readonly MAX_ATTACH_WAIT=420
readonly MAX_BOOT_WAIT=1200

# Runtime State Variables (Tracked for Cleanup)
SNAPSHOT_ID=""                  # ID of created snapshot
SOURCE_VOLUME_IDS=""            # Volume IDs within snapshot
CLONE_BOOT_ID=""                # ID of cloned boot volume
CLONE_DATA_IDS=""               # Comma-separated data volume IDs
CLONE_TASK_ID=""                # Async clone job ID
SECONDARY_INSTANCE_ID=""        # Resolved secondary LPAR instance ID
JOB_SUCCESS=0                   # 0=Failure, 1=Success

echo "Configuration loaded successfully."
echo ""

################################################################################
# CLEANUP FUNCTION
# Triggered on failure to rollback partially completed operations
# Logic:
#   1. Preserve snapshot (intentional - snapshots are kept for recovery)
#   2. Resolve secondary LPAR instance ID by name
#   3. Bulk detach all volumes from secondary LPAR
#   4. Wait for detachment to complete
#   5. Bulk delete cloned volumes
#   6. Verify deletion completed
# Note: Does NOT delete the LPAR itself - only volumes
################################################################################
cleanup_on_failure() {
    trap - ERR EXIT
    
    # Skip cleanup if job completed successfully
    if [[ ${JOB_SUCCESS:-0} -eq 1 ]]; then
        echo "Job completed successfully - no cleanup needed"
        return 0
    fi
    
    echo ""
    echo "========================================================================"
    echo " FAILURE DETECTED - INITIATING CLEANUP"
    echo "========================================================================"
    echo ""
    
    # -------------------------------------------------------------------------
    # STEP 1: Resolve LPAR instance ID
    # -------------------------------------------------------------------------
    echo "→ Resolving secondary LPAR instance ID..."
    
    SECONDARY_INSTANCE_ID=$(ibmcloud pi instance list --json 2>/dev/null \
        | jq -r --arg N "$SECONDARY_LPAR" '.pvmInstances[]? | select(.name==$N) | .id' \
        | head -n 1)
    
    if [[ -z "$SECONDARY_INSTANCE_ID" || "$SECONDARY_INSTANCE_ID" == "null" ]]; then
        echo "  ⚠ No LPAR found named '${SECONDARY_LPAR}' - skipping cleanup"
        return 0
    fi
    
    echo "✓ Found LPAR '${SECONDARY_LPAR}'"
    echo "  Instance ID: ${SECONDARY_INSTANCE_ID}"
    
    # -------------------------------------------------------------------------
    # STEP 2: Preserve snapshot (by design)
    # -------------------------------------------------------------------------
    if [[ -n "${SNAPSHOT_ID}" ]]; then
        echo "→ Snapshot preserved: ${SNAPSHOT_ID}"
        echo "  (Snapshots are retained for recovery purposes)"
    fi
    
    # -------------------------------------------------------------------------
    # STEP 3: Bulk detach all volumes
    # -------------------------------------------------------------------------
    echo "→ Requesting bulk detach of all volumes..."
    
    ibmcloud pi instance volume bulk-detach "$SECONDARY_INSTANCE_ID" \
        --detach-all \
        --detach-primary > /dev/null 2>&1 || true
    
    echo "  Waiting for detachment to complete..."
    
    WAIT_TIME=30
    MAX_DETACH_WAIT=240
    ELAPSED=30
    
    sleep $WAIT_TIME
    
    while true; do
        ATTACHED=$(ibmcloud pi instance volume list "$SECONDARY_INSTANCE_ID" --json 2>/dev/null \
            | jq -r '(.volumes // [])[] | .volumeID')
        
        if [[ -z "$ATTACHED" ]]; then
            echo "✓ All volumes detached"
            break
        fi
        
        if [[ $ELAPSED -ge $MAX_DETACH_WAIT ]]; then
            echo "  ⚠ WARNING: Volumes still attached after ${MAX_DETACH_WAIT}s"
            echo "  ⚠ Proceeding with deletion anyway"
            break
        fi
        
        echo "  Volumes still attached - retrying in ${POLL_INTERVAL}s"
        sleep "$POLL_INTERVAL"
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
    done
    
    # -------------------------------------------------------------------------
    # STEP 4: Bulk delete cloned volumes
    # -------------------------------------------------------------------------
    echo "→ Deleting cloned volumes..."
    
    if [[ -n "$CLONE_BOOT_ID" ]]; then
        if [[ -n "$CLONE_DATA_IDS" ]]; then
            # Delete boot + data volumes
            ibmcloud pi volume bulk-delete \
                --volumes "${CLONE_BOOT_ID},${CLONE_DATA_IDS}" > /dev/null 2>&1 || true
        else
            # Delete boot volume only
            ibmcloud pi volume bulk-delete \
                --volumes "${CLONE_BOOT_ID}" > /dev/null 2>&1 || true
        fi
    fi
    
    # -------------------------------------------------------------------------
    # STEP 5: Verify deletion
    # -------------------------------------------------------------------------
    echo "→ Verifying volume deletion..."
    
    sleep 5
    
    if [[ -n "$CLONE_BOOT_ID" ]]; then
        if ibmcloud pi volume get "$CLONE_BOOT_ID" --json > /dev/null 2>&1; then
            echo "  ⚠ WARNING: Boot volume still exists - manual review required"
        else
            echo "✓ Boot volume deleted: ${CLONE_BOOT_ID}"
        fi
    fi
    
    if [[ -n "$CLONE_DATA_IDS" ]]; then
        for VOL in ${CLONE_DATA_IDS//,/ }; do
            if ibmcloud pi volume get "$VOL" --json > /dev/null 2>&1; then
                echo "  ⚠ WARNING: Data volume still exists - manual review required: ${VOL}"
            else
                echo "✓ Data volume deleted: ${VOL}"
            fi
        done
    fi
    
    echo ""
    echo "========================================================================"
    echo " CLEANUP COMPLETE"
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
echo " STAGE 1/7: IBM CLOUD AUTHENTICATION & WORKSPACE TARGETING"
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
# STAGE 2: SNAPSHOT PRIMARY LPAR
# Logic:
#   1. Create snapshot of primary LPAR with timestamped name
#   2. Poll snapshot status until AVAILABLE
#   3. Handle ERROR state as failure
################################################################################
echo "========================================================================"
echo " STAGE 2/7: SNAPSHOT PRIMARY LPAR"
echo "========================================================================"
echo ""

echo "→ Creating snapshot of primary LPAR: ${PRIMARY_LPAR}"
echo "  Snapshot name: ${SNAPSHOT_NAME}"

SNAPSHOT_JSON=$(ibmcloud pi instance snapshot create "$PRIMARY_LPAR" \
    --name "$SNAPSHOT_NAME" \
    --json 2>/dev/null) || {
    echo "✗ ERROR: Snapshot creation failed"
    exit 1
}

SNAPSHOT_ID=$(echo "$SNAPSHOT_JSON" | jq -r '.snapshotID')
echo "✓ Snapshot created"
echo "  Snapshot ID: ${SNAPSHOT_ID}"
echo ""

echo "→ Polling snapshot status (interval: ${SNAPSHOT_POLL_INTERVAL}s)..."

while true; do
    STATUS_JSON=$(ibmcloud pi instance snapshot get "$SNAPSHOT_ID" --json 2>/dev/null)
    STATUS=$(echo "$STATUS_JSON" | jq -r '.status')
    
    echo "  Snapshot status: ${STATUS}"
    
    if [[ "$STATUS" == "available" ]]; then
        echo "✓ Snapshot is AVAILABLE"
        break
    elif [[ "$STATUS" == "error" ]]; then
        echo "✗ ERROR: Snapshot entered ERROR state"
        exit 1
    fi
    
    sleep "$SNAPSHOT_POLL_INTERVAL"
done

echo ""
echo "------------------------------------------------------------------------"
echo " Stage 2 Complete: Snapshot ready for cloning"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# STAGE 3: EXTRACT SNAPSHOT VOLUMES
# Logic:
#   1. Parse snapshot JSON to extract volume IDs
#   2. Separate boot volume from data volumes
#   3. Validate at least one boot volume exists
################################################################################
echo "========================================================================"
echo " STAGE 3/7: EXTRACT SNAPSHOT VOLUME INFORMATION"
echo "========================================================================"
echo ""

echo "→ Extracting volume information from snapshot..."

SNAPSHOT_DETAIL=$(ibmcloud pi instance snapshot get "$SNAPSHOT_ID" --json)

# Parse volume IDs from snapshot
SOURCE_VOLUME_IDS=$(echo "$SNAPSHOT_DETAIL" \
    | jq -r '.volumeSnapshots[]?.volumeID // empty' \
    | paste -sd "," -)

if [[ -z "$SOURCE_VOLUME_IDS" ]]; then
    echo "✗ ERROR: No volumes found in snapshot"
    exit 1
fi

echo "✓ Found volumes in snapshot: ${SOURCE_VOLUME_IDS}"

# Identify boot vs data volumes
SOURCE_BOOT_ID=$(echo "$SNAPSHOT_DETAIL" \
    | jq -r '.volumeSnapshots[] | select(.bootable==true) | .volumeID' \
    | head -n 1)

SOURCE_DATA_IDS=$(echo "$SNAPSHOT_DETAIL" \
    | jq -r '.volumeSnapshots[] | select(.bootable==false) | .volumeID' \
    | paste -sd "," -)

echo ""
echo "  Volume Classification:"
echo "  ├─ Boot Volume:  ${SOURCE_BOOT_ID}"
echo "  └─ Data Volumes: ${SOURCE_DATA_IDS:-None}"

echo ""
echo "------------------------------------------------------------------------"
echo " Stage 3 Complete: Volume information extracted"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# STAGE 4: CLONE SNAPSHOT VOLUMES
# Logic:
#   1. Submit asynchronous clone request with new volume names
#   2. Extract clone task ID
#   3. Wait for clone job to complete
#   4. Extract cloned volume IDs from completed job
#   5. Separate boot and data volumes
################################################################################
echo "========================================================================"
echo " STAGE 4/7: CLONE SNAPSHOT VOLUMES"
echo "========================================================================"
echo ""

echo "→ Submitting clone request..."
echo "  Clone prefix: ${CLONE_PREFIX}"
echo "  Storage tier: ${STORAGE_TIER}"

CLONE_JSON=$(ibmcloud pi volume clone-async \
    --target-tier "$STORAGE_TIER" \
    --volumes "$SOURCE_VOLUME_IDS" \
    --name "$CLONE_PREFIX" \
    --json 2>/dev/null) || {
    echo "✗ ERROR: Clone request failed"
    exit 1
}

CLONE_TASK_ID=$(echo "$CLONE_JSON" | jq -r '.clonedVolumes[0].cloneTaskID')
echo "✓ Clone request submitted"
echo "  Clone task ID: ${CLONE_TASK_ID}"
echo ""

# Wait for clone job to complete
wait_for_clone_job "$CLONE_TASK_ID"

echo ""
echo "→ Extracting cloned volume IDs..."

CLONE_RESULT=$(ibmcloud pi volume clone-async get "$CLONE_TASK_ID" --json)

CLONE_BOOT_ID=$(echo "$CLONE_RESULT" \
    | jq -r '.clonedVolumes[] | select(.sourceVolume=="'"$SOURCE_BOOT_ID"'") | .clonedVolume')

if [[ -n "$SOURCE_DATA_IDS" ]]; then
    CLONE_DATA_IDS=$(echo "$CLONE_RESULT" \
        | jq -r '.clonedVolumes[] | select(.sourceVolume!="'"$SOURCE_BOOT_ID"'") | .clonedVolume' \
        | paste -sd "," -)
fi

echo "✓ Cloned volume IDs extracted"
echo "  Boot volume: ${CLONE_BOOT_ID}"
echo "  Data volumes: ${CLONE_DATA_IDS:-None}"

echo ""
echo "------------------------------------------------------------------------"
echo " Stage 4 Complete: Volumes cloned successfully"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# STAGE 5: VERIFY CLONED VOLUMES
# Logic:
#   1. Poll each cloned volume until status is "available"
#   2. Ensures volumes are ready for attachment
################################################################################
echo "========================================================================"
echo " STAGE 5/7: VERIFY CLONED VOLUMES"
echo "========================================================================"
echo ""

echo "→ Verifying cloned volumes are available..."

# Verify boot volume
while true; do
    BOOT_STATUS=$(ibmcloud pi volume get "$CLONE_BOOT_ID" --json \
        | jq -r '.state')
    
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
                | jq -r '.state')
            
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
echo " Stage 5 Complete: All volumes verified available"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# STAGE 6: ATTACH VOLUMES TO SECONDARY LPAR
# Logic:
#   1. Resolve secondary LPAR instance ID by name
#   2. Attach boot volume and data volumes (if any)
#   3. Wait for initial stabilization
#   4. Poll until all volumes appear in instance volume list
################################################################################
echo "========================================================================"
echo " STAGE 6/7: ATTACH VOLUMES TO SECONDARY LPAR"
echo "========================================================================"
echo ""

echo "→ Resolving secondary LPAR instance ID..."

SECONDARY_INSTANCE_ID=$(ibmcloud pi instance list --json \
    | jq -r ".pvmInstances[] | select(.name == \"$SECONDARY_LPAR\") | .id")

if [[ -z "$SECONDARY_INSTANCE_ID" ]]; then
    echo "✗ ERROR: Secondary LPAR not found: ${SECONDARY_LPAR}"
    exit 1
fi

echo "✓ Secondary LPAR found"
echo "  Name: ${SECONDARY_LPAR}"
echo "  Instance ID: ${SECONDARY_INSTANCE_ID}"
echo ""

echo "→ Attaching volumes to LPAR..."

if [[ -n "$CLONE_DATA_IDS" ]]; then
    echo "  Attaching boot + data volumes..."
    ibmcloud pi instance volume attach "$SECONDARY_INSTANCE_ID" \
        --volumes "$CLONE_DATA_IDS" \
        --boot-volume "$CLONE_BOOT_ID" || {
        echo "✗ ERROR: Volume attachment failed"
        exit 1
    }
else
    echo "  Attaching boot volume only..."
    ibmcloud pi instance volume attach "$SECONDARY_INSTANCE_ID" \
        --boot-volume "$CLONE_BOOT_ID" || {
        echo "✗ ERROR: Boot volume attachment failed"
        exit 1
    }
fi

echo "✓ Attachment request accepted"
echo ""

echo "→ Waiting ${SNAPSHOT_POLL_INTERVAL}s for backend stabilization..."
sleep $SNAPSHOT_POLL_INTERVAL
echo ""

echo "→ Polling for volume attachment confirmation..."

ELAPSED=0

while true; do
    VOL_LIST=$(ibmcloud pi instance volume list "$SECONDARY_INSTANCE_ID" --json 2>/dev/null \
        | jq -r '(.volumes // []) | .[]? | .volumeID')
    
    # Check boot volume is attached
    BOOT_ATTACHED=$(echo "$VOL_LIST" | grep -q "$CLONE_BOOT_ID" && echo yes || echo no)
    
    # Check all data volumes are attached
    DATA_ATTACHED=true
    if [[ -n "$CLONE_DATA_IDS" ]]; then
        for VOL in ${CLONE_DATA_IDS//,/ }; do
            if ! echo "$VOL_LIST" | grep -q "$VOL"; then
                DATA_ATTACHED=false
                break
            fi
        done
    fi
    
    if [[ "$BOOT_ATTACHED" == "yes" && "$DATA_ATTACHED" == "true" ]]; then
        echo "✓ All volumes confirmed attached"
        break
    fi
    
    if [[ $ELAPSED -ge $MAX_ATTACH_WAIT ]]; then
        echo "✗ ERROR: Volumes not attached after ${MAX_ATTACH_WAIT}s"
        exit 1
    fi
    
    echo "  Volumes not fully visible yet - checking again in ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

echo ""
echo "------------------------------------------------------------------------"
echo " Stage 6 Complete: Volumes attached and verified"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# STAGE 7: BOOT SECONDARY LPAR
# Logic:
#   1. Check current LPAR status
#   2. If not ACTIVE, configure boot mode and start LPAR
#   3. Poll status until ACTIVE or timeout
#   4. Handle ERROR state as failure
################################################################################
echo "========================================================================"
echo " STAGE 7/7: BOOT SECONDARY LPAR"
echo "========================================================================"
echo ""

echo "→ Checking current LPAR status..."

CURRENT_STATUS=$(ibmcloud pi instance get "$SECONDARY_INSTANCE_ID" --json \
    | jq -r '.status')

echo "  Current status: ${CURRENT_STATUS}"
echo ""

if [[ "$CURRENT_STATUS" != "ACTIVE" ]]; then
    echo "→ Configuring boot mode (NORMAL)..."
    
    ibmcloud pi instance operation "$SECONDARY_INSTANCE_ID" \
        --operation-type boot \
        --boot-mode a \
        --boot-operating-mode normal || {
        echo "✗ ERROR: Boot configuration failed"
        exit 1
    }
    
    echo "✓ Boot mode configured"
    echo ""
    
    echo "→ Starting LPAR..."
    
    ibmcloud pi instance action "$SECONDARY_INSTANCE_ID" --operation start || {
        echo "✗ ERROR: LPAR start command failed"
        exit 1
    }
    
    echo "✓ Start command accepted"
else
    echo "  LPAR already ACTIVE - skipping boot sequence"
fi

echo ""
echo "→ Waiting for LPAR to reach ACTIVE state..."
echo "  (Max wait: $(($MAX_BOOT_WAIT/60)) minutes)"
echo ""

BOOT_ELAPSED=0

while true; do
    STATUS=$(ibmcloud pi instance get "$SECONDARY_INSTANCE_ID" --json \
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
        exit 1
    fi
    
    if [[ $BOOT_ELAPSED -ge $MAX_BOOT_WAIT ]]; then
        echo ""
        echo "✗ ERROR: LPAR failed to reach ACTIVE state within $(($MAX_BOOT_WAIT/60)) minutes"
        exit 1
    fi
    
    sleep "$POLL_INTERVAL"
    BOOT_ELAPSED=$((BOOT_ELAPSED + POLL_INTERVAL))
done

echo ""
echo "------------------------------------------------------------------------"
echo " Stage 7 Complete: LPAR booted successfully"
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
echo "  Snapshot Created:        ✓ Yes (${SNAPSHOT_ID})"
echo "  Volumes Cloned:          ✓ Yes"
echo "  Volumes Attached:        ✓ Yes"
echo "  Boot Mode:               ✓ NORMAL (Mode A)"
echo "  ────────────────────────────────────────────────────────────────"
echo "  Boot Volume:             ${CLONE_BOOT_ID}"
echo "  Data Volumes:            ${CLONE_DATA_IDS:-None}"
echo ""
echo "========================================================================"
echo ""

################################################################################
# OPTIONAL STAGE: TRIGGER CLEANUP JOB (Job 3)
################################################################################
echo "========================================================================"
echo " OPTIONAL STAGE: CHAIN TO CLEANUP PROCESS"
echo "========================================================================"
echo ""

if [[ "${RUN_CLEANUP_JOB:-No}" == "Yes" ]]; then
    echo "→ RUN_CLEANUP_JOB=Yes detected - triggering Job 3..."
    
    echo "  Switching to Code Engine project: IBMi..."
    ibmcloud ce project target --name IBMi > /dev/null 2>&1 || {
        echo "✗ ERROR: Unable to target Code Engine project 'IBMi'"
        exit 1
    }
    
    echo "  Submitting Code Engine job: prod-cleanup..."
    
    RAW_SUBMISSION=$(ibmcloud ce jobrun submit \
        --job prod-cleanup \
        --output json 2>&1)
    
    NEXT_RUN=$(echo "$RAW_SUBMISSION" | jq -r '.metadata.name // .name // empty' 2>/dev/null || true)
    
    if [[ -z "$NEXT_RUN" ]]; then
        echo "✗ ERROR: Job submission failed - no jobrun name returned"
        echo ""
        echo "Raw output:"
        echo "$RAW_SUBMISSION"
        exit 1
    fi
    
    echo "✓ Job 3 triggered successfully"
    echo "  Jobrun instance: ${NEXT_RUN}"
else
    echo "→ RUN_CLEANUP_JOB not set - skipping Job 3"
    echo "  Snapshot and volumes will remain until manual cleanup"
fi

echo ""
echo "========================================================================"
echo ""

JOB_SUCCESS=1
sleep 1
exit 0
