#!/usr/bin/env bash

################################################################################
# JOB 2: CLONE & RESTORE (NO SNAPSHOTS) - WITH IBMi SSH PREP
echo " Version: v7"
# suspending ASP for 15 seconds
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
echo " JOB 2: CLONE & RESTORE OPERATIONS (v7)"
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
readonly SECONDARY_LPAR="murphy-prod-clone4"               # Target LPAR for restore
#readonly STORAGE_TIER="tier3"                     # Must match source tier

# Naming Convention - Clone YYYY-MM-DD-HH-MM
readonly CLONE_PREFIX="murphy-prod-$(date +"%Y%m%d%H%M")"

# Polling Configuration
readonly POLL_INTERVAL=60
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
            echo "  Clone task status: ${STATUS} - waiting ${POLL_INTERVAL}s..."
            sleep "$POLL_INTERVAL"   # ← Use the variable!
        fi
    done
}

#wait_for_clone_job() {
#    local task_id=$1
 #   echo "→ Waiting for asynchronous clone task: ${task_id}..."
  
#    while true; do
#        STATUS=$(ibmcloud pi volume clone-async get "$task_id" --json \
#            | jq -r '.status')
        
#        if [[ "$STATUS" == "completed" ]]; then
#            echo "✓ Clone task completed successfully"
#            break
#        elif [[ "$STATUS" == "failed" ]]; then
#            echo "✗ ERROR: Clone task failed"
#            exit 1
#        else
#            echo "  Clone task status: ${STATUS} - waiting 30s..."
#            sleep 30
#        fi
#    done
#}

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

set +e
INSTANCE_LIST_OUTPUT=$(ibmcloud pi instance list --json 2>&1)
INSTANCE_LIST_RC=$?
set -e

if [[ $INSTANCE_LIST_RC -ne 0 ]]; then
    echo "✗ ERROR: Failed to list PowerVS instances (exit code: ${INSTANCE_LIST_RC})"
    echo "Output: ${INSTANCE_LIST_OUTPUT}"
    exit 1
fi

SECONDARY_INSTANCE_ID=$(echo "$INSTANCE_LIST_OUTPUT" | jq -r --arg N "$SECONDARY_LPAR" \
      '.pvmInstances[]? | select(.name==$N) | .id' 2>/dev/null | head -n 1)

if [[ -z "$SECONDARY_INSTANCE_ID" || "$SECONDARY_INSTANCE_ID" == "null" ]]; then
    echo "✗ ERROR: Secondary LPAR '${SECONDARY_LPAR}' not found in workspace"
    echo "Searching for: ${SECONDARY_LPAR}"
    echo ""
    echo "Available instances in workspace:"
    echo "$INSTANCE_LIST_OUTPUT" | jq -r '.pvmInstances[]? | "  - \(.name) (ID: \(.id))"' 2>/dev/null || echo "  (Unable to parse instance list)"
    exit 1
fi

echo "✓ Secondary LPAR ID: ${SECONDARY_INSTANCE_ID}"

echo "→ Checking attached volumes on secondary LPAR..."

VOLUME_JSON=$(ibmcloud pi instance volume list "$SECONDARY_INSTANCE_ID" --json 2>/dev/null)

set +e
BOOT_VOLUMES=$(echo "$VOLUME_JSON" | jq '[.volumes[]? | select(.bootable == true)] | length' 2>/dev/null)
TOTAL_VOLUMES=$(echo "$VOLUME_JSON" | jq '.volumes? | length' 2>/dev/null)
set -e

# Default to 0 if jq failed
BOOT_VOLUMES=${BOOT_VOLUMES:-0}
TOTAL_VOLUMES=${TOTAL_VOLUMES:-0}

echo "  Total attached volumes: ${TOTAL_VOLUMES}"
echo "  Bootable volumes       : ${BOOT_VOLUMES}"
echo ""

###############################################################################
# DECISION: SKIP TO STAGE 5 IF BOOT VOLUME ALREADY ATTACHED
###############################################################################
if [[ "$BOOT_VOLUMES" -gt 0 ]]; then
    echo "⚠ Boot volume already attached - skipping clone/attach stages"
    echo "  Resuming at Stage 5 (Boot LPAR)"
    echo ""
    RESUME_AT_STAGE_5=1
fi

###############################################################################
# RESUME MODE: CAPTURE EXISTING ATTACHED VOLUMES FOR FAILURE MARKING
###############################################################################
if [[ "$RESUME_AT_STAGE_5" -eq 1 ]]; then
    echo "→ Resume mode: capturing existing attached volumes..."

    ATTACHED_VOLUMES_JSON=$(ibmcloud pi instance volume list "$SECONDARY_INSTANCE_ID" --json)

    CLONE_BOOT_ID=$(echo "$ATTACHED_VOLUMES_JSON" \
        | jq -r '.volumes[] | select(.bootable == true) | .volumeID' \
        | head -n 1)

    CLONE_DATA_IDS=$(echo "$ATTACHED_VOLUMES_JSON" \
        | jq -r '.volumes[] | select(.bootable != true) | .volumeID' \
        | paste -sd "," -)

    echo "  Boot volume ID : ${CLONE_BOOT_ID}"
    echo "  Data volume IDs: ${CLONE_DATA_IDS:-None}"
    echo ""
fi


if [[ "$RESUME_AT_STAGE_5" -ne 1 ]]; then



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
set +e
PRIMARY_DATA_IDS=$(echo "$PRIMARY_VOLUME_DATA" | jq -r '
    .volumes[]? | select(.bootVolume != true) | .volumeID
' 2>/dev/null | paste -sd "," - 2>/dev/null)
set -e

# Clean up empty result
if [[ -z "$PRIMARY_DATA_IDS" || "$PRIMARY_DATA_IDS" == "" ]]; then
    PRIMARY_DATA_IDS=""
fi

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

# Count total volumes
IFS=',' read -ra _VOLS <<<"$PRIMARY_VOLUME_IDS"
TOTAL_VOLUME_COUNT=${#_VOLS[@]}


echo "✓ Volumes identified on primary LPAR"
echo "  Boot volume:  ${PRIMARY_BOOT_ID}"
echo "  Data volumes: ${PRIMARY_DATA_IDS:-None}"
echo "  Total volumes to clone: ${TOTAL_VOLUME_COUNT}"



echo ""
echo "------------------------------------------------------------------------"
echo " Stage 2 Complete: Volume identification complete"
echo "------------------------------------------------------------------------"
echo ""


echo "========================================================================"
echo " STAGE 3/5: IBMi PREPARATION & VOLUME CLONING"
echo "========================================================================"
echo ""

# ------------------------------------------------------------------------------
# STAGE 3a: Install SSH Client and SSH Keys
# ------------------------------------------------------------------------------
#echo "→ Installing SSH client..."

#set +e
#apt-get update -qq > /dev/null 2>&1
#apt-get install -y openssh-client -qq > /dev/null 2>&1
#set -e

#echo "  ✓ SSH client installed"
echo ""

echo "→ Installing SSH keys from Code Engine secrets..."

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
# ------------------------------------------------------------------------------
# STAGE 3b: SSH to IBMi and Run Preparation Commands
# ------------------------------------------------------------------------------
echo "→ Connecting to IBMi via VSI for disk preparation..."

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  murphy@52.118.255.179 \
  "ssh -i /home/murphy/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       murphy@192.168.0.109 \
       'system \"CHGTCPSVR SVRSPCVAL(*TELNET) AUTOSTART(*YES)\"; \
        system \"CHGTCPSVR SVRSPCVAL(*SSHD) AUTOSTART(*YES)\"; \
        system \"CHGTCPIFC INTNETADR('\''192.168.0.109'\'') AUTOSTART(*NO)\"; \
        system \"CALL PGM(QSYS/QAENGCHG) PARM(*ENABLECI)\"; \
        sleep 30; \
        system \"CHGASPACT ASPDEV(*SYSBAS) OPTION(*FRCWRT)\"; \
        system \"CHGASPACT ASPDEV(*SYSBAS) OPTION(*SUSPEND) SSPTIMO(120)\"'" || true

echo "  ✓ IBMi preparation commands completed - ASP suspended for 120 seconds"
echo ""

echo "→ Waiting 5 seconds before initiating volume clone..."
sleep 5
echo ""

# ------------------------------------------------------------------------------
# STAGE 3c: Clone Volumes
# ------------------------------------------------------------------------------
echo "→ Submitting clone request..."
echo "  Clone prefix: ${CLONE_PREFIX}"
#echo "  Storage tier: ${STORAGE_TIER}"
echo "  Source volumes: ${PRIMARY_VOLUME_IDS}"

CLONE_JSON=$(ibmcloud pi volume clone-async create "$CLONE_PREFIX" \
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
echo ""

echo "→ Waiting 90 seconds before resuming ASP operations..."
sleep 90
echo ""

# Resume ASP immediately after clone initiation
echo "→ Resuming ASP on IBMi..."

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  murphy@52.118.255.179 \
  "ssh -i /home/murphy/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       murphy@192.168.0.109 \
       'system \"CHGASPACT ASPDEV(*SYSBAS) OPTION(*RESUME)\"; \
        system \"CHGTCPIFC INTNETADR('\''192.168.0.109'\'') AUTOSTART(*YES)\"'" || true

echo "  ✓ ASP resumed"
echo ""


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
            FAILED_STAGE="ATTACH_VOLUME"
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

    ############ Check boot volume
    if grep -qx "$CLONE_BOOT_ID" <<<"$VOL_LIST"; then
        BOOT_ATTACHED=true
    fi

    # Check data volumes (if any)
    if [[ -n "$CLONE_DATA_IDS" ]]; then
        for VOL in ${CLONE_DATA_IDS//,/ }; do
            if ! grep -qx "$VOL" <<<"$VOL_LIST"; then    #########took out qx
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
        FAILED_STAGE="ATTACH_VOLUME"
        echo "✗ ERROR: Volumes not attached after ${MAX_ATTACH_WAIT}s"
        exit 1
    fi


    echo "  Volumes not fully visible yet - checking again in ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

echo ""
echo "Pausing 180 seconds to allow logs to sync.."
echo ""
sleep 180s

echo ""
echo "------------------------------------------------------------------------"
echo " Stage 4 Complete: Volumes attached and verified"
echo "------------------------------------------------------------------------"
echo ""


fi  # ← closes "if [[ $RESUME_AT_STAGE_5 -ne 1 ]]"



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

set +e
INSTANCE_JSON=$(ibmcloud pi instance get "$SECONDARY_INSTANCE_ID" --json 2>/dev/null)
RC=$?
set -e

if [[ $RC -ne 0 || -z "$INSTANCE_JSON" ]]; then
    echo "✗ Unable to retrieve LPAR status"
    FAILED_STAGE="STARTUP"
    exit 1
fi

CURRENT_STATUS=$(echo "$INSTANCE_JSON" | jq -r '.status // "UNKNOWN"')
echo "  Current status: ${CURRENT_STATUS}"
echo ""

###############################################################################
# BOOT CONFIGURATION (ONLY IF NOT ACTIVE)
###############################################################################

if [[ "$CURRENT_STATUS" != "ACTIVE" ]]; then
    echo "→ Configuring boot mode (NORMAL)..."

    BOOTCFG_SUCCESS=0

    for BOOTCFG_ATTEMPT in 1 2; do
        echo "  Boot config attempt ${BOOTCFG_ATTEMPT}/2"

        set +e
        BOOTCFG_OUTPUT=$(ibmcloud pi instance operation "$SECONDARY_INSTANCE_ID" \
            --operation-type boot \
            --boot-mode b \
            --boot-operating-mode normal 2>&1)
        RC=$?
        set -e

        echo "$BOOTCFG_OUTPUT"

        if [[ $RC -eq 0 ]]; then
            echo "✓ Boot mode configured"
            BOOTCFG_SUCCESS=1
            break
        fi

        sleep 60
    done

    if [[ $BOOTCFG_SUCCESS -ne 1 ]]; then
        FAILED_STAGE="BOOT_CONFIG"
        exit 1
    fi

    ############################################################################
    # START LPAR (RETRYABLE, NO TRAPS)
    ############################################################################
    sleep 60
    echo "→ Starting LPAR..."

    START_SUCCESS=0
    IN_START_RETRY=1   # <<< CRITICAL FLAG

    for START_ATTEMPT in 1 2 3; do
        echo "  Start attempt ${START_ATTEMPT}/3"

        set +e
        START_OUTPUT=$(ibmcloud pi instance action "$SECONDARY_INSTANCE_ID" \
            --operation start 2>&1)
        RC=$?
        set -e

        echo "$START_OUTPUT"

        if [[ $RC -eq 0 ]]; then
            echo "✓ Start command accepted"
            START_SUCCESS=1
            break
        fi

        # Retryable failure handling
        if echo "$START_OUTPUT" | grep -q "attaching_volume"; then
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
echo "  Boot Mode:               ✓ NORMAL (Mode B)"
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

