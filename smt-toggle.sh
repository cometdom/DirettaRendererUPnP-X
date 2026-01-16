#!/bin/bash
#
# smt-toggle.sh
# Universal SMT/Hyper-Threading toggle script
# Works on AMD (SMT) and Intel (Hyper-Threading)
# Auto-detects CPU topology
#
# Author: Dominique & Claude
# Version: 1.0
# Date: 2025-01-16
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "${RED}ERROR: This script must be run as root. Please use 'sudo'.${NC}" >&2
        exit 1
    fi
}

print_header() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  $1"
    echo "═══════════════════════════════════════════════════════"
    echo ""
}

# =============================================================================
# CPU DETECTION
# =============================================================================

detect_cpu_info() {
    # Detect CPU vendor
    CPU_VENDOR=$(lscpu | grep "Vendor ID:" | awk '{print $3}')
    
    # Detect total CPUs, threads per core, cores per socket
    TOTAL_CPUS=$(lscpu | grep "^CPU(s):" | awk '{print $2}')
    THREADS_PER_CORE=$(lscpu | grep "Thread(s) per core:" | awk '{print $4}')
    CORES_PER_SOCKET=$(lscpu | grep "Core(s) per socket:" | awk '{print $4}')
    SOCKETS=$(lscpu | grep "Socket(s):" | awk '{print $2}')
    
    # Calculate physical cores
    PHYSICAL_CORES=$((CORES_PER_SOCKET * SOCKETS))
    
    # Detect CPU model
    CPU_MODEL=$(lscpu | grep "Model name:" | sed 's/Model name:\s*//')
}

# =============================================================================
# SMT STATUS
# =============================================================================

get_smt_status() {
    # Check if SMT control is available
    if [[ ! -f /sys/devices/system/cpu/smt/control ]]; then
        echo "unsupported"
        return
    fi
    
    # Read current status
    local status
    status=$(cat /sys/devices/system/cpu/smt/control)
    echo "$status"
}

get_smt_status_grub() {
    # Check if nosmt is in GRUB config
    if grep -q "nosmt" /etc/default/grub 2>/dev/null; then
        echo "disabled_grub"
        return
    fi
    
    # Check if nosmt is in current kernel cmdline
    if grep -q "nosmt" /proc/cmdline 2>/dev/null; then
        echo "disabled_boot"
        return
    fi
    
    echo "enabled"
}

# =============================================================================
# STATUS DISPLAY
# =============================================================================

show_status() {
    print_header "SMT/Hyper-Threading Status"
    
    detect_cpu_info
    
    echo -e "${BLUE}CPU Information:${NC}"
    echo "  Model:           $CPU_MODEL"
    echo "  Vendor:          $CPU_VENDOR"
    echo "  Sockets:         $SOCKETS"
    echo "  Physical cores:  $PHYSICAL_CORES"
    echo "  Threads/core:    $THREADS_PER_CORE"
    echo "  Total CPUs:      $TOTAL_CPUS"
    echo ""
    
    # Runtime status
    local runtime_status
    runtime_status=$(get_smt_status)
    
    echo -e "${BLUE}Runtime Status:${NC}"
    case "$runtime_status" in
        "on")
            echo -e "  SMT/HT: ${GREEN}ENABLED${NC} (running)"
            ;;
        "off")
            echo -e "  SMT/HT: ${RED}DISABLED${NC} (runtime)"
            ;;
        "notsupported")
            echo -e "  SMT/HT: ${YELLOW}NOT SUPPORTED${NC} by this CPU"
            ;;
        "notimplemented")
            echo -e "  SMT/HT: ${YELLOW}NOT IMPLEMENTED${NC} in this kernel"
            ;;
        "unsupported")
            echo -e "  SMT/HT: ${YELLOW}CONTROL NOT AVAILABLE${NC}"
            ;;
    esac
    echo ""
    
    # GRUB/Boot status
    local grub_status
    grub_status=$(get_smt_status_grub)
    
    echo -e "${BLUE}Boot Configuration (GRUB):${NC}"
    case "$grub_status" in
        "disabled_grub")
            echo -e "  GRUB config: ${RED}nosmt parameter present${NC}"
            echo "  Next boot:   SMT will be DISABLED"
            ;;
        "disabled_boot")
            echo -e "  Current boot: ${RED}nosmt active${NC}"
            echo "  GRUB config:  May have been set manually"
            ;;
        "enabled")
            echo -e "  GRUB config: ${GREEN}SMT enabled${NC} (no nosmt parameter)"
            echo "  Next boot:   SMT will be ENABLED"
            ;;
    esac
    echo ""
    
    # Online CPUs
    echo -e "${BLUE}Online CPUs:${NC}"
    if [[ -f /sys/devices/system/cpu/online ]]; then
        local online_cpus
        online_cpus=$(cat /sys/devices/system/cpu/online)
        echo "  $online_cpus"
    else
        echo "  Unable to read"
    fi
    echo ""
    
    # Recommendations
    if [[ "$runtime_status" == "on" && "$THREADS_PER_CORE" == "2" ]]; then
        echo -e "${YELLOW}Note:${NC} SMT is currently enabled."
        echo "  For audio workloads, disabling SMT may improve latency consistency."
        echo "  Use: sudo $0 disable"
    fi
}

# =============================================================================
# ENABLE SMT
# =============================================================================

enable_smt_runtime() {
    print_header "Enabling SMT/Hyper-Threading (Runtime)"
    
    local status
    status=$(get_smt_status)
    
    if [[ "$status" == "unsupported" ]]; then
        echo -e "${YELLOW}WARNING: SMT control not available on this system.${NC}"
        echo "This may be due to:"
        echo "  - Old kernel (< 4.10)"
        echo "  - CPU doesn't support SMT"
        echo "  - Already controlled by BIOS"
        exit 1
    fi
    
    if [[ "$status" == "on" ]]; then
        echo -e "${GREEN}SMT is already ENABLED.${NC}"
        return
    fi
    
    echo "Enabling SMT..."
    echo "on" > /sys/devices/system/cpu/smt/control
    
    # Verify
    status=$(get_smt_status)
    if [[ "$status" == "on" ]]; then
        echo -e "${GREEN}✓ SUCCESS: SMT is now ENABLED${NC}"
        echo ""
        echo "Online CPUs: $(cat /sys/devices/system/cpu/online)"
    else
        echo -e "${RED}✗ FAILED: Could not enable SMT (status: $status)${NC}"
        exit 1
    fi
}

enable_smt_grub() {
    print_header "Enabling SMT/Hyper-Threading (Permanent - GRUB)"
    
    if ! grep -q "nosmt" /etc/default/grub 2>/dev/null; then
        echo -e "${GREEN}SMT already enabled in GRUB (no nosmt parameter).${NC}"
        return
    fi
    
    echo "Removing 'nosmt' from GRUB configuration..."
    
    # Backup GRUB config
    cp /etc/default/grub /etc/default/grub.backup-$(date +%Y%m%d-%H%M%S)
    echo "✓ Backup created"
    
    # Remove nosmt parameter (standalone or with value)
    sed -i -E 's/ nosmt([" ]|=[^" ]*)?/ /g' /etc/default/grub
    sed -i -E 's/nosmt ([" ])/\1/g' /etc/default/grub
    
    echo "✓ Removed 'nosmt' from /etc/default/grub"
    
    # Update GRUB
    echo ""
    echo "Updating GRUB configuration..."
    if command -v grub2-mkconfig &> /dev/null; then
        # Fedora/RHEL/CentOS
        grub2-mkconfig -o /boot/grub2/grub.cfg
    elif command -v update-grub &> /dev/null; then
        # Debian/Ubuntu
        update-grub
    else
        echo -e "${YELLOW}WARNING: Could not find grub2-mkconfig or update-grub.${NC}"
        echo "Please update GRUB manually:"
        echo "  Fedora: grub2-mkconfig -o /boot/grub2/grub.cfg"
        echo "  Ubuntu: update-grub"
        exit 1
    fi
    
    echo ""
    echo -e "${GREEN}✓ SUCCESS: GRUB updated${NC}"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Reboot required for changes to take effect.${NC}"
    echo "After reboot, all CPU threads will be available."
}

# =============================================================================
# DISABLE SMT
# =============================================================================

disable_smt_runtime() {
    print_header "Disabling SMT/Hyper-Threading (Runtime)"
    
    local status
    status=$(get_smt_status)
    
    if [[ "$status" == "unsupported" ]]; then
        echo -e "${YELLOW}WARNING: SMT control not available on this system.${NC}"
        echo "Use GRUB method instead: sudo $0 disable-permanent"
        exit 1
    fi
    
    if [[ "$status" == "off" ]]; then
        echo -e "${GREEN}SMT is already DISABLED.${NC}"
        return
    fi
    
    echo "Disabling SMT..."
    echo ""
    echo -e "${YELLOW}Note: This will offline half of your CPU threads.${NC}"
    
    detect_cpu_info
    echo "Before: $TOTAL_CPUS CPUs online"
    echo "After:  $PHYSICAL_CORES CPUs will remain online"
    echo ""
    
    echo "off" > /sys/devices/system/cpu/smt/control
    
    # Verify
    status=$(get_smt_status)
    if [[ "$status" == "off" ]]; then
        echo -e "${GREEN}✓ SUCCESS: SMT is now DISABLED${NC}"
        echo ""
        echo "Online CPUs: $(cat /sys/devices/system/cpu/online)"
        echo ""
        echo -e "${YELLOW}Note: This is temporary. To make permanent, use:${NC}"
        echo "  sudo $0 disable-permanent"
    else
        echo -e "${RED}✗ FAILED: Could not disable SMT (status: $status)${NC}"
        exit 1
    fi
}

disable_smt_grub() {
    print_header "Disabling SMT/Hyper-Threading (Permanent - GRUB)"
    
    if grep -q "nosmt" /etc/default/grub 2>/dev/null; then
        echo -e "${GREEN}SMT already disabled in GRUB (nosmt parameter present).${NC}"
        return
    fi
    
    echo "Adding 'nosmt' to GRUB configuration..."
    
    # Backup GRUB config
    cp /etc/default/grub /etc/default/grub.backup-$(date +%Y%m%d-%H%M%S)
    echo "✓ Backup created"
    
    # Add nosmt parameter to GRUB_CMDLINE_LINUX
    sed -i 's|^\(GRUB_CMDLINE_LINUX=".*\)"|\\1 nosmt"|' /etc/default/grub
    
    echo "✓ Added 'nosmt' to /etc/default/grub"
    
    # Update GRUB
    echo ""
    echo "Updating GRUB configuration..."
    if command -v grub2-mkconfig &> /dev/null; then
        # Fedora/RHEL/CentOS
        grub2-mkconfig -o /boot/grub2/grub.cfg
    elif command -v update-grub &> /dev/null; then
        # Debian/Ubuntu
        update-grub
    else
        echo -e "${YELLOW}WARNING: Could not find grub2-mkconfig or update-grub.${NC}"
        echo "Please update GRUB manually:"
        echo "  Fedora: grub2-mkconfig -o /boot/grub2/grub.cfg"
        echo "  Ubuntu: update-grub"
        exit 1
    fi
    
    echo ""
    echo -e "${GREEN}✓ SUCCESS: GRUB updated${NC}"
    echo ""
    
    detect_cpu_info
    echo "Current:     $TOTAL_CPUS CPUs"
    echo "After reboot: $PHYSICAL_CORES CPUs (physical cores only)"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Reboot required for changes to take effect.${NC}"
}

# =============================================================================
# USAGE
# =============================================================================

usage() {
    cat <<EOF
SMT/Hyper-Threading Toggle Script
===================================

Auto-detects CPU topology and manages SMT/Hyper-Threading.
Works on AMD (SMT) and Intel (Hyper-Threading) systems.

Usage: sudo $0 [COMMAND]

Commands:
  status              Show current SMT/HT status (default)
  
  disable             Disable SMT immediately (temporary, lost on reboot)
  disable-permanent   Disable SMT permanently via GRUB (requires reboot)
  
  enable              Enable SMT immediately (temporary if disabled via GRUB)
  enable-permanent    Enable SMT permanently by removing GRUB nosmt parameter
  
  help                Show this help message

Examples:
  # Check current status
  sudo $0 status
  
  # Disable SMT temporarily (for testing)
  sudo $0 disable
  
  # Disable SMT permanently (recommended for audio)
  sudo $0 disable-permanent
  sudo reboot
  
  # Re-enable SMT
  sudo $0 enable-permanent
  sudo reboot

Notes:
  - Runtime changes (disable/enable) are immediate but temporary
  - Permanent changes (disable-permanent/enable-permanent) require reboot
  - For audio workloads, disabling SMT often improves latency consistency
  - GRUB backups are created automatically in /etc/default/

EOF
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    check_root
    
    case "${1:-status}" in
        status)
            show_status
            ;;
        
        disable)
            disable_smt_runtime
            ;;
        
        disable-permanent|disable-perm)
            disable_smt_grub
            ;;
        
        enable)
            enable_smt_runtime
            ;;
        
        enable-permanent|enable-perm)
            enable_smt_grub
            ;;
        
        help|--help|-h)
            usage
            ;;
        
        *)
            echo -e "${RED}ERROR: Unknown command '$1'${NC}" >&2
            echo ""
            usage
            exit 1
            ;;
    esac
}

main "$@"
