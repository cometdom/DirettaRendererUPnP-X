#!/bin/bash
#
# diretta-renderer-tuner-5900x.sh
# CPU isolation and real-time tuning for diretta-renderer.service
# VERSION: Ryzen 9 5900X (12 cores, SMT disabled)
#
# Adapted from leeeanh/SwissMountainsBear script
# Optimized for AMD Ryzen 9 5900X with SMT disabled
#
# Configuration:
#   - 12 physical cores (0-11) with SMT off
#   - Housekeeping: cores 0-1 (system, IRQs)
#   - Audio isolated: cores 2-11 (DirettaRenderer only)
#
# Benefits:
#   - Ultra-low latency (~10-20 µs)
#   - No IRQ interruptions on audio cores
#   - No kernel threads on audio cores
#   - Deterministic performance
#
# Usage: sudo ./diretta-renderer-tuner-5900x.sh [apply|revert|status|redistribute]

# --- Bash Best Practices ---
set -euo pipefail

# =============================================================================
# CONFIGURATION - RYZEN 9 5900X (12 CORES)
# =============================================================================

# Housekeeping cores: System tasks, IRQs, kernel work
# Use 2 physical cores (cores 0-1)
HOUSEKEEPING_CPUS="0-1"

# Diretta Renderer cores: Isolated for audio processing
# Use remaining 10 physical cores (cores 2-11)
RENDERER_CPUS="2-11"

# =============================================================================
# DERIVED VARIABLES (DO NOT EDIT)
# =============================================================================

# System paths
GRUB_FILE="/etc/default/grub"
SYSTEMD_DIR="/etc/systemd/system"
LOCAL_BIN_DIR="/usr/local/bin"

# Service configuration
SERVICE_NAME="diretta-renderer.service"
SLICE_NAME="diretta-renderer.slice"

# Helper scripts/services
GOVERNOR_SERVICE="cpu-performance-diretta-5900x.service"
IRQ_SCRIPT_NAME="set-irq-affinity-diretta-5900x.sh"
IRQ_SCRIPT_PATH="${LOCAL_BIN_DIR}/${IRQ_SCRIPT_NAME}"
THREAD_DIST_SCRIPT_NAME="distribute-diretta-threads-5900x.sh"
THREAD_DIST_SCRIPT_PATH="${LOCAL_BIN_DIR}/${THREAD_DIST_SCRIPT_NAME}"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: This script must be run as root. Please use 'sudo'." >&2
        exit 1
    fi
}

check_cpu() {
    # Verify we're on a Ryzen 9 5900X (or compatible 12-core CPU)
    local cores
    cores=$(lscpu | grep "^Core(s) per socket:" | awk '{print $4}')
    
    if [[ "$cores" != "12" ]]; then
        echo "WARNING: This script is optimized for 12-core CPUs (Ryzen 9 5900X)"
        echo "         Detected: $cores cores"
        echo ""
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Check if SMT is already disabled
    local threads_per_core
    threads_per_core=$(lscpu | grep "Thread(s) per core:" | awk '{print $4}')
    
    if [[ "$threads_per_core" != "1" ]]; then
        echo "WARNING: SMT is still enabled (threads per core: $threads_per_core)"
        echo "         This script requires SMT to be disabled first"
        echo ""
        echo "Run: sudo smt-toggle.sh disable-permanent"
        echo "Then reboot and run this script again"
        exit 1
    fi
}

usage() {
    cat <<EOF
Diretta Renderer CPU Tuner - Ryzen 9 5900X
===========================================

Optimized for AMD Ryzen 9 5900X (12 cores, SMT disabled)

Usage: sudo $0 [apply|revert|status|redistribute]

Commands:
  apply        - Apply CPU isolation and real-time tuning
  revert       - Remove all tuning configurations
  status       - Check current tuning status
  redistribute - Manually redistribute threads now (for testing)

Configuration (Ryzen 9 5900X):
  HOUSEKEEPING_CPUS = ${HOUSEKEEPING_CPUS} (2 cores for system)
  RENDERER_CPUS     = ${RENDERER_CPUS} (10 cores isolated for audio)

Prerequisites:
  - SMT must be disabled (use smt-toggle.sh)
  - diretta-renderer.service must be installed

This configuration isolates 10 cores exclusively for audio processing,
leaving 2 cores for all system tasks, IRQs, and kernel threads.
EOF
}

# Expand CPU range notation (e.g., "1-3,8" -> "1 2 3 8")
expand_cpu_list() {
    local input="$1"
    local result=""

    # Replace commas with spaces, then process ranges
    for part in ${input//,/ }; do
        if [[ "$part" == *-* ]]; then
            local start="${part%-*}"
            local end="${part#*-}"
            for ((i=start; i<=end; i++)); do
                result+="$i "
            done
        else
            result+="$part "
        fi
    done

    echo "$result"
}

# =============================================================================
# APPLY FUNCTIONS
# =============================================================================

apply_grub_config() {
    echo "INFO: Applying GRUB kernel parameters (CPU isolation)..."

    # Remove any previous instances of these parameters
    sed -i -E 's/ (isolcpus|nohz|nohz_full|rcu_nocbs|irqaffinity)=[^"]*//g' "${GRUB_FILE}"

    # Build new kernel parameters
    # nosmt should already be present (required prerequisite)
    local grub_cmdline="isolcpus=${RENDERER_CPUS} nohz=on nohz_full=${RENDERER_CPUS} rcu_nocbs=${RENDERER_CPUS} irqaffinity=${HOUSEKEEPING_CPUS}"

    # Append to GRUB_CMDLINE_LINUX
    sed -i "s|^\(GRUB_CMDLINE_LINUX=\"[^\"]*\)\"|\1 ${grub_cmdline}\"|" "${GRUB_FILE}"

    # Update GRUB
    if command -v update-grub &> /dev/null; then
        update-grub
    elif command -v grub2-mkconfig &> /dev/null; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
    else
        echo "WARNING: Could not find update-grub or grub2-mkconfig."
        echo "         Please update GRUB manually."
    fi

    echo "SUCCESS: GRUB configuration updated."
    echo "         After reboot:"
    echo "         - Cores ${RENDERER_CPUS} will be isolated (audio only)"
    echo "         - Cores ${HOUSEKEEPING_CPUS} will handle system tasks"
}

apply_systemd_slice() {
    echo "INFO: Creating systemd slice for CPU pinning..."

    cat << EOF > "${SYSTEMD_DIR}/${SLICE_NAME}"
[Unit]
Description=Slice for Diretta Renderer audio service (Ryzen 9 5900X isolated)
Before=slices.target

[Slice]
# Pin to isolated audio cores (10 cores: 2-11)
AllowedCPUs=${RENDERER_CPUS}
# Allow full CPU usage
CPUQuota=100%
EOF

    echo "SUCCESS: Systemd slice created: ${SLICE_NAME}"
}

apply_service_override() {
    echo "INFO: Creating systemd service override..."

    local override_dir="${SYSTEMD_DIR}/${SERVICE_NAME}.d"
    mkdir -p "${override_dir}"

    cat << EOF > "${override_dir}/10-isolation.conf"
[Unit]
Description=Diretta UPnP Renderer (CPU isolated - Ryzen 9 5900X)
After=network.target set-irq-affinity-diretta-5900x.service ${GOVERNOR_SERVICE}
Wants=set-irq-affinity-diretta-5900x.service ${GOVERNOR_SERVICE}

[Service]
# Run in the CPU-pinned slice
Slice=${SLICE_NAME}

# Real-time scheduling
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=80

# Nice level
Nice=-19

# Thread distribution hook
ExecStartPost=/bin/bash -c 'sleep 2 && ${THREAD_DIST_SCRIPT_PATH} \$MAINPID || true'
EOF

    echo "SUCCESS: Service override created."
}

apply_irq_config() {
    echo "INFO: Creating IRQ affinity configuration..."

    # Get the list of housekeeping CPUs as a hex mask
    local expanded_cpus
    expanded_cpus=$(expand_cpu_list "${HOUSEKEEPING_CPUS}")
    
    # Convert to hex mask (for 12 cores: 0-1 = 0x0003)
    local mask=0
    for cpu in $expanded_cpus; do
        mask=$((mask | (1 << cpu)))
    done
    local hex_mask=$(printf "0x%x" $mask)

    cat << SCRIPT_EOF > "${IRQ_SCRIPT_PATH}"
#!/bin/bash
#
# set-irq-affinity-diretta-5900x.sh
# Set IRQ affinity to housekeeping cores only (cores ${HOUSEKEEPING_CPUS})
#

set -euo pipefail

LOG_FILE="/var/log/irq-affinity-5900x.log"

log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S'): \$*" | tee -a "\$LOG_FILE"
}

log "Setting IRQ affinity to cores ${HOUSEKEEPING_CPUS} (mask: ${hex_mask})"

# Set default IRQ affinity
echo "${hex_mask}" > /proc/irq/default_smp_affinity 2>/dev/null || true

# Set affinity for all existing IRQs
for irq in /proc/irq/*/smp_affinity; do
    if [[ -w "\$irq" ]]; then
        echo "${hex_mask}" > "\$irq" 2>/dev/null || true
    fi
done

log "IRQ affinity configured for Ryzen 9 5900X"
log "Housekeeping cores: ${HOUSEKEEPING_CPUS}"
log "Isolated cores: ${RENDERER_CPUS}"

# Log current IRQ distribution
log "Current IRQ counts per CPU:"
grep -E "^ *[0-9]+" /proc/interrupts | head -1 | tee -a "\$LOG_FILE"
grep -E "^ *[0-9]+:" /proc/interrupts | awk '{print \$1, \$2, \$3, \$NF}' | tail -5 | tee -a "\$LOG_FILE"
SCRIPT_EOF

    chmod +x "${IRQ_SCRIPT_PATH}"

    # Create systemd service for IRQ affinity
    cat << EOF > "${SYSTEMD_DIR}/set-irq-affinity-diretta-5900x.service"
[Unit]
Description=Set IRQ affinity for Diretta Renderer (Ryzen 9 5900X)
DefaultDependencies=no
After=sysinit.target
Before=network.target

[Service]
Type=oneshot
ExecStart=${IRQ_SCRIPT_PATH}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    echo "SUCCESS: IRQ affinity configuration created."
}

apply_governor_config() {
    echo "INFO: Creating CPU governor configuration..."

    cat << EOF > "${SYSTEMD_DIR}/${GOVERNOR_SERVICE}"
[Unit]
Description=Set CPU governor to performance for Diretta (Ryzen 9 5900X)
DefaultDependencies=no
After=sysinit.target
Before=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/cpupower frequency-set -g performance
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    echo "SUCCESS: CPU governor service created."
}

apply_thread_distribution() {
    echo "INFO: Creating thread distribution script (Ryzen 9 5900X)..."

    # Get the list of renderer CPUs as an array for round-robin
    local expanded_cpus
    expanded_cpus=$(expand_cpu_list "${RENDERER_CPUS}")

    cat << 'SCRIPT_HEADER' > "${THREAD_DIST_SCRIPT_PATH}"
#!/bin/bash
#
# distribute-diretta-threads-5900x.sh
# Distributes DirettaRenderer threads across isolated cores (Ryzen 9 5900X)
#

set -euo pipefail

MAIN_PID="${1:-}"
LOG_FILE="/var/log/diretta-thread-distribution-5900x.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" | tee -a "$LOG_FILE"
}

if [[ -z "$MAIN_PID" ]]; then
    log "ERROR: No PID provided"
    exit 1
fi

# Wait for threads to spawn
sleep 1.0

# Check if process still exists
if ! ps -p "$MAIN_PID" > /dev/null 2>&1; then
    log "WARNING: Process $MAIN_PID no longer exists, skipping"
    exit 0
fi

SCRIPT_HEADER

    # Now add the CPU array
    cat << SCRIPT_CPUS >> "${THREAD_DIST_SCRIPT_PATH}"
# Available renderer CPUs - isolated cores on Ryzen 9 5900X
RENDERER_CPUS_ARRAY=(${expanded_cpus})
NUM_CPUS=\${#RENDERER_CPUS_ARRAY[@]}

SCRIPT_CPUS

    cat << 'SCRIPT_BODY' >> "${THREAD_DIST_SCRIPT_PATH}"
log "Starting thread distribution for PID $MAIN_PID (Ryzen 9 5900X)"
log "Isolated cores: ${RENDERER_CPUS_ARRAY[*]} ($NUM_CPUS cores)"

# Get all thread IDs for this process
TIDS=$(ps -T -o tid= -p "$MAIN_PID" 2>/dev/null | tr -d ' ')

if [[ -z "$TIDS" ]]; then
    log "WARNING: No threads found for PID $MAIN_PID"
    exit 0
fi

# Count threads
THREAD_COUNT=$(echo "$TIDS" | wc -l)
log "Found $THREAD_COUNT threads to distribute across $NUM_CPUS isolated cores"

# Distribute threads round-robin across available CPUs
i=0
while read -r tid; do
    if [[ -n "$tid" ]]; then
        cpu_index=$(( i % NUM_CPUS ))
        target_cpu=${RENDERER_CPUS_ARRAY[$cpu_index]}

        if taskset -pc "$target_cpu" "$tid" > /dev/null 2>&1; then
            log "  Thread $tid -> Core $target_cpu (isolated)"
        else
            log "  Thread $tid -> Core $target_cpu (FAILED)"
        fi

        i=$(( i + 1 ))
    fi
done <<< "$TIDS"

log "Thread distribution complete - $THREAD_COUNT threads on $NUM_CPUS isolated cores"
SCRIPT_BODY

    chmod +x "${THREAD_DIST_SCRIPT_PATH}"

    echo "SUCCESS: Thread distribution script created."
}

# =============================================================================
# REVERT FUNCTIONS
# =============================================================================

revert_grub_config() {
    echo "INFO: Removing CPU isolation from GRUB..."

    # Backup
    cp "${GRUB_FILE}" "${GRUB_FILE}.backup-revert-$(date +%Y%m%d-%H%M%S)"

    # Remove isolation parameters (keep nosmt if present)
    sed -i -E 's/ (isolcpus|nohz_full|rcu_nocbs|irqaffinity)=[^"]*//g' "${GRUB_FILE}"

    # Update GRUB
    if command -v update-grub &> /dev/null; then
        update-grub
    elif command -v grub2-mkconfig &> /dev/null; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
    else
        echo "WARNING: Could not update GRUB. Please do it manually."
    fi

    echo "SUCCESS: GRUB configuration cleaned."
}

revert_systemd_config() {
    echo "INFO: Removing systemd configurations..."

    # Remove files
    rm -f "${SYSTEMD_DIR}/${SLICE_NAME}"
    rm -f "${SYSTEMD_DIR}/${SERVICE_NAME}.d/10-isolation.conf"
    rm -f "${SYSTEMD_DIR}/set-irq-affinity-diretta-5900x.service"
    rm -f "${SYSTEMD_DIR}/${GOVERNOR_SERVICE}"
    rm -f "${IRQ_SCRIPT_PATH}"
    rm -f "${THREAD_DIST_SCRIPT_PATH}"

    # Try to remove override directory if empty
    rmdir "${SYSTEMD_DIR}/${SERVICE_NAME}.d" 2>/dev/null || true

    echo "SUCCESS: Systemd configurations removed."
}

# =============================================================================
# STATUS
# =============================================================================

check_status() {
    echo "=== Diretta Renderer CPU Tuning Status (Ryzen 9 5900X) ==="
    echo ""

    # CPU Info
    echo "=== CPU Configuration ==="
    echo ""
    lscpu | grep -E "Model name|CPU\(s\)|On-line|Off-line|Thread\(s\) per core|Core\(s\) per socket"
    echo ""

    # Kernel parameters
    echo "=== Kernel Parameters ==="
    echo ""
    echo -n "1. nosmt: "
    if grep -q "nosmt" /proc/cmdline; then
        echo "ACTIVE ✓"
    else
        echo "MISSING ✗"
    fi

    echo -n "2. isolcpus: "
    if grep -q "isolcpus=" /proc/cmdline; then
        grep -o "isolcpus=[^ ]*" /proc/cmdline
    else
        echo "MISSING ✗"
    fi

    echo -n "3. nohz_full: "
    if grep -q "nohz_full=" /proc/cmdline; then
        grep -o "nohz_full=[^ ]*" /proc/cmdline
    else
        echo "MISSING ✗"
    fi

    echo -n "4. rcu_nocbs: "
    if grep -q "rcu_nocbs=" /proc/cmdline; then
        grep -o "rcu_nocbs=[^ ]*" /proc/cmdline
    else
        echo "MISSING ✗"
    fi

    echo -n "5. irqaffinity: "
    if grep -q "irqaffinity=" /proc/cmdline; then
        grep -o "irqaffinity=[^ ]*" /proc/cmdline
    else
        echo "MISSING ✗"
    fi
    echo ""

    # Configuration files
    echo "=== Configuration Files ==="
    echo ""

    local has_error=0

    echo -n "1. Systemd slice: "
    if [[ -f "${SYSTEMD_DIR}/${SLICE_NAME}" ]]; then
        echo "EXISTS ✓"
    else
        echo "MISSING ✗"
        has_error=1
    fi

    echo -n "2. Service override: "
    if [[ -f "${SYSTEMD_DIR}/${SERVICE_NAME}.d/10-isolation.conf" ]]; then
        echo "EXISTS ✓"
    else
        echo "MISSING ✗"
        has_error=1
    fi

    echo -n "3. IRQ affinity service: "
    if [[ -f "${SYSTEMD_DIR}/set-irq-affinity-diretta-5900x.service" ]]; then
        local irq_status
        irq_status=$(systemctl is-active set-irq-affinity-diretta-5900x.service 2>/dev/null || echo "inactive")
        echo "EXISTS ($irq_status)"
    else
        echo "MISSING ✗"
        has_error=1
    fi

    echo -n "4. Governor service: "
    if [[ -f "${SYSTEMD_DIR}/${GOVERNOR_SERVICE}" ]]; then
        local gov_status
        gov_status=$(systemctl is-active "${GOVERNOR_SERVICE}" 2>/dev/null || echo "inactive")
        echo "EXISTS ($gov_status)"
    else
        echo "MISSING ✗"
        has_error=1
    fi

    echo -n "5. Thread distribution script: "
    if [[ -f "${THREAD_DIST_SCRIPT_PATH}" ]]; then
        echo "EXISTS ✓"
    else
        echo "MISSING ✗"
        has_error=1
    fi

    echo ""

    # Service status
    echo "=== Service Status ==="
    echo ""
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        echo "Service: RUNNING ✓"
        systemctl show "${SERVICE_NAME}" -p Slice,CPUSchedulingPolicy,Nice 2>/dev/null | sed 's/^/  /'

        # Show actual CPU affinity
        local main_pid
        main_pid=$(systemctl show "${SERVICE_NAME}" -p MainPID --value 2>/dev/null)
        if [[ -n "$main_pid" && "$main_pid" != "0" ]]; then
            echo ""
            echo "  Process affinity (allowed CPUs):"
            taskset -pc "$main_pid" 2>/dev/null | sed 's/^/    /' || echo "    (unable to read)"

            echo ""
            echo "  Thread distribution:"
            echo "    TID      CPU  COMMAND"
            ps -T -o tid=,psr=,comm= -p "$main_pid" 2>/dev/null | while read -r tid psr comm; do
                printf "    %-8s %-4s %s\n" "$tid" "$psr" "$comm"
            done

            # Count threads per CPU
            echo ""
            echo "  Threads per core:"
            ps -T -o psr= -p "$main_pid" 2>/dev/null | sort | uniq -c | while read -r count cpu; do
                if [[ $cpu -ge 2 && $cpu -le 11 ]]; then
                    printf "    Core %2s: %s threads (isolated ✓)\n" "$cpu" "$count"
                else
                    printf "    Core %2s: %s threads (housekeeping)\n" "$cpu" "$count"
                fi
            done
        fi
    else
        echo "Service: NOT RUNNING ✗"
    fi

    echo ""

    # Summary
    if [[ $has_error -eq 0 ]]; then
        if grep -q "isolcpus=" /proc/cmdline; then
            echo "=== All configurations active (Ryzen 9 5900X isolated) ✓ ==="
        else
            echo "=== Configurations in place - REBOOT REQUIRED ==="
        fi
    else
        echo "=== Some configurations missing - run 'apply' ==="
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    check_root

    case "${1:-}" in
        apply)
            echo "=== Applying CPU Isolation (Ryzen 9 5900X) ==="
            echo ""
            
            # Pre-flight checks
            check_cpu
            
            echo "Configuration:"
            echo "  CPU:              AMD Ryzen 9 5900X (12 cores)"
            echo "  SMT:              Disabled (required)"
            echo "  Housekeeping:     Cores ${HOUSEKEEPING_CPUS} (2 cores)"
            echo "  Audio isolated:   Cores ${RENDERER_CPUS} (10 cores)"
            echo ""
            echo "This will configure CPU isolation for ultra-low latency audio."
            echo ""
            read -p "Continue? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 0
            fi
            echo ""

            apply_grub_config
            apply_systemd_slice
            apply_service_override
            apply_irq_config
            apply_governor_config
            apply_thread_distribution

            echo ""
            echo "INFO: Reloading systemd daemon..."
            systemctl daemon-reload

            echo "INFO: Enabling helper services..."
            systemctl enable set-irq-affinity-diretta-5900x.service "${GOVERNOR_SERVICE}" 2>/dev/null || true

            echo ""
            echo "=== Configuration Applied ✓ ==="
            echo ""
            echo "IMPORTANT: A REBOOT is required for CPU isolation to take effect."
            echo ""
            echo "After reboot:"
            echo "  - Cores 2-11 will be isolated (audio only)"
            echo "  - Cores 0-1 will handle all system tasks"
            echo "  - Restart service: sudo systemctl restart ${SERVICE_NAME}"
            echo "  - Check status: sudo $0 status"
            echo ""
            ;;

        revert)
            echo "=== Reverting CPU Isolation (Ryzen 9 5900X) ==="
            echo ""

            # Disable services first
            systemctl disable set-irq-affinity-diretta-5900x.service "${GOVERNOR_SERVICE}" 2>/dev/null || true

            revert_grub_config
            revert_systemd_config

            echo ""
            echo "INFO: Reloading systemd daemon..."
            systemctl daemon-reload

            echo ""
            echo "=== Configuration Reverted ✓ ==="
            echo ""
            echo "IMPORTANT: A REBOOT is required to remove CPU isolation."
            echo ""
            ;;

        status)
            check_status
            ;;

        redistribute)
            echo "=== Manual Thread Redistribution (Ryzen 9 5900X) ==="
            echo ""

            # Check if service is running
            if ! systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
                echo "ERROR: ${SERVICE_NAME} is not running"
                exit 1
            fi

            # Get main PID
            local main_pid
            main_pid=$(systemctl show "${SERVICE_NAME}" -p MainPID --value 2>/dev/null)
            if [[ -z "$main_pid" || "$main_pid" == "0" ]]; then
                echo "ERROR: Could not get PID for ${SERVICE_NAME}"
                exit 1
            fi

            echo "Service PID: $main_pid"
            echo ""

            # Check isolation status
            if grep -q "isolcpus=" /proc/cmdline; then
                echo "CPU Isolation: ACTIVE ✓"
                echo "Isolated cores: $(grep -o "isolcpus=[^ ]*" /proc/cmdline | cut -d= -f2)"
            else
                echo "CPU Isolation: NOT ACTIVE (requires reboot after 'apply')"
            fi
            echo ""

            # Run distribution script
            if [[ -f "${THREAD_DIST_SCRIPT_PATH}" ]]; then
                echo "Running thread distribution script..."
                "${THREAD_DIST_SCRIPT_PATH}" "$main_pid"
            else
                echo "ERROR: Thread distribution script not found"
                echo "Run '$0 apply' first"
                exit 1
            fi

            echo ""
            echo "=== Current Thread Layout ==="
            echo "TID      CPU  COMMAND"
            ps -T -o tid=,psr=,comm= -p "$main_pid" 2>/dev/null | while read -r tid psr comm; do
                if [[ $psr -ge 2 && $psr -le 11 ]]; then
                    printf "%-8s %-4s %s (isolated ✓)\n" "$tid" "$psr" "$comm"
                else
                    printf "%-8s %-4s %s (housekeeping)\n" "$tid" "$psr" "$comm"
                fi
            done
            ;;

        *)
            usage
            ;;
    esac
}

main "$@"
