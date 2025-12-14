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
readonly PRIMARY_INSTANCE_ID="c92f6904-8bd2-4093-acec-f641899cd658"
readonly SECONDARY_LPAR="empty-ibmi-lpar"               # Target LPAR for restore
readonly STORAGE_TIER="tier3"                     # Must match source tier

# Naming Convention - Capture timestamp at script start
readonly TIMESTAMP="$(date +"%Y%m%d%H%M")"
readonly CLONE_PREFIX="empty-IBMi-lpar-${TIMESTAMP}"

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
echo "  Clone prefix: ${CLONE_PREFIX}"
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
    # STEP 1: Resolve secondary LPAR instance ID (if not already resolved)
    # -------------------------------------------------------------------------
    if [[ -z "$SECONDARY_INSTANCE_ID" ]]; then
        echo "→ Resolving secondary LPAR instance ID..."
        
        SECONDARY_INSTANCE_ID=$(ibmcloud pi instance list --json 2>/dev/null \
            | jq -r --arg N "$SECONDARY_LPAR" '.pvmInstances[]? | select(.name==$N) | .id' \
            | head -n 1)
    fi
    
    if [[ -z "$SECONDARY_INSTANCE_ID" || "$SECONDARY_INSTANCE_ID" == "null" ]]; then
        echo "  ⚠ No LPAR found named '${SECONDARY_LPAR}'"
        echo "  Skipping volume cleanup - proceeding to cloned volume deletion"
    else
        echo "✓ Found LPAR '${SECONDARY_LPAR}'"
        echo "  Instance ID: ${SECONDARY_INSTANCE_ID}"
        
        # ---------------------------------------------------------------------
        # STEP 2: Bulk detach all volumes (if any are attached)
        # ---------------------------------------------------------------------
        echo "→ Checking for attached volumes..."
        
        ATTACHED=$(ibmcloud pi instance volume list "$SECONDARY_INSTANCE_ID" --json 2>/dev/null \
            | jq -r '(.volumes // [])[] | .volumeID' || true)
        
        if [[ -n "$ATTACHED" ]]; then
            echo "  Volumes detected - requesting bulk detach..."
            
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
        else
            echo "  No volumes attached - skipping detach"
        fi
    fi
    
    # -------------------------------------------------------------------------
    # STEP 3: Bulk delete cloned volumes
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
    # STEP 4: Verify deletion
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

# -------------------------------------------------------------------------
# STEP 2: Query primary LPAR volumes
# -------------------------------------------------------------------------
echo "→ Querying volumes on primary LPAR: ${PRIMARY_LPAR}..."

PRIMARY_VOLUME_DATA=$(ibmcloud pi ins vol ls "$PRIMARY_INSTANCE_ID" --json 2>/dev/null)

# Debug: Show structure
echo "  Debug: Volume data structure..."
echo "$PRIMARY_VOLUME_DATA" | jq '.' || echo "  Could not parse JSON"
echo ""

# -------------------------------------------------------------------------
# STEP 3: Extract boot and data volume IDs
# -------------------------------------------------------------------------
echo "→ Identifying boot and data volumes..."

# Extract boot volume ID
PRIMARY_BOOT_ID=$(echo "$PRIMARY_VOLUME_DATA" | jq -r '
    if .volumes then
        if (.volumes | type) == "array" then
            .volumes[] | select(.bootVolume==true or .bootVolume=="true") | .volumeID? // empty
        else
            .volumes | to_entries[] | .value | select(.bootVolume==true or .bootVolume=="true") | .volumeID? // empty
        fi
    else
        empty
    end
' | head -n 1)

# Extract data volume IDs
PRIMARY_DATA_IDS=$(echo "$PRIMARY_VOLUME_DATA" | jq -r '
    if .volumes then
        if (.volumes | type) == "array" then
            .volumes[] | select(.bootVolume==false or .bootVolume=="false" or .bootVolume==null) | .volumeID? // empty
        else
            .volumes | to_entries[] | .value | select(.bootVolume==false or .bootVolume=="false" or .bootVolume==null) | .volumeID? // empty
        fi
    else
        empty
    end
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

################################################################################
# STAGE 3: CLONE VOLUMES & VERIFY AVAILABILITY
# Logic:
#   1. Submit asynchronous clone request with new volume names
#   2. Extract clone task ID
#   3. Wait for clone job to complete
#   4. Extract cloned volume IDs from completed job
#   5. Separate boot and data volumes
#   6. Verify all cloned volumes are available before proceeding
################################################################################
echo "========================================================================"
echo " STAGE 3/5: CLONE VOLUMES & VERIFY AVAILABILITY"
echo "========================================================================"
echo ""

echo "→ Submitting clone request..."
echo "  Clone prefix: ${CLONE_PREFIX}"
echo "  Storage tier: ${STORAGE_TIER}"
echo "  Source volumes: ${PRIMARY_VOLUME_IDS}"

CLONE_JSON=$(ibmcloud pi volume clone-async \
    --target-tier "$STORAGE_TIER" \
    --volumes "$PRIMARY_VOLUME_IDS" \
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
    | jq -r '.clonedVolumes[] | select(.sourceVolume=="'"$PRIMARY_BOOT_ID"'") | .clonedVolume')

if [[ -n "$PRIMARY_DATA_IDS" ]]; then
    CLONE_DATA_IDS=$(echo "$CLONE_RESULT" \
        | jq -r '.clonedVolumes[] | select(.sourceVolume!="'"$PRIMARY_BOOT_ID"'") | .clonedVolume' \
        | paste -sd "," -)
fi

echo "✓ Cloned volume IDs extracted"
echo "  Boot volume: ${CLONE_BOOT_ID}"
echo "  Data volumes: ${CLONE_DATA_IDS:-None}"
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

echo "→ Waiting ${INITIAL_WAIT}s for backend stabilization..."
sleep $INITIAL_WAIT
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
echo " Stage 4 Complete: Volumes attached and verified"
echo "------------------------------------------------------------------------"
echo ""

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
    
    echo "✓ Job 3 (cleanup) triggered successfully"
    echo "  Jobrun instance: ${NEXT_RUN}"
else
    echo "→ RUN_CLEANUP_JOB not set - skipping Job 3"
    echo "  Volumes will remain until manual cleanup"
fi

echo ""
echo "========================================================================"
echo ""

JOB_SUCCESS=1
sleep 1
exit 0
