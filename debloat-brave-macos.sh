#!/usr/bin/env bash
#
# Brave Browser Debloater for macOS
# Disables non-core Brave features to mimic Brave Origin
#
# WARNING: Some policies (BraveAIChatEnabled, SyncDisabled,
# BraveWalletDisabled, PromotionsEnabled, BackgroundModeEnabled,
# BrowserSignin) cause Brave v147+ to crash with SIGTRAP even when
# written to the managed plist with correct types. They are excluded.
#
# Leo AI can be disabled manually at brave://settings/leo instead.
#
# CRITICAL: On macOS, Brave boolean policies MUST be written to the
# managed preferences location (/Library/Managed Preferences/) using
# proper boolean types. Writing them to the user preferences plist
# via `defaults write -bool` causes Brave to crash on startup.
#
# Usage:
#   chmod +x debloat-brave-macos.sh
#   sudo ./debloat-brave-macos.sh                        # Apply debloat (stable)
#   sudo ./debloat-brave-macos.sh --channel beta         # Apply debloat for Beta
#   sudo ./debloat-brave-macos.sh --channel nightly      # Apply debloat for Nightly
#   sudo ./debloat-brave-macos.sh --dry-run              # Preview what would change
#   sudo ./debloat-brave-macos.sh --restore              # Restore from a previous backup
#

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Channel detection: parse --channel before anything else ---
CHANNEL="stable"
_args=("$@")
for (( _i=0; _i<${#_args[@]}; _i++ )); do
    case "${_args[$_i]}" in
        --channel=*)
            CHANNEL="${_args[$_i]#*=}"
            if [[ -z "$CHANNEL" ]]; then
                echo "Error: --channel requires a value (stable|beta|nightly). See --help."
                exit 1
            fi
            ;;
        --channel)
            if (( _i+1 < ${#_args[@]} )) && [[ "${_args[$(( _i+1 ))]}" != -* ]]; then
                CHANNEL="${_args[$(( _i+1 ))]}"
                (( _i++ ))
            else
                echo "Error: --channel requires a value (stable|beta|nightly). See --help."
                exit 1
            fi
            ;;
    esac
done

case "$CHANNEL" in
    beta)
        BROWSER_BUNDLE_ID="com.brave.Browser.Beta"
        BRAVE_APP_NAME="Brave Browser Beta"
        BRAVE_PROCESS_NAME="Brave Browser Beta"
        ;;
    nightly)
        BROWSER_BUNDLE_ID="com.brave.Browser.Nightly"
        BRAVE_APP_NAME="Brave Browser Nightly"
        BRAVE_PROCESS_NAME="Brave Browser Nightly"
        ;;
    stable)
        BROWSER_BUNDLE_ID="com.brave.Browser"
        BRAVE_APP_NAME="Brave Browser"
        BRAVE_PROCESS_NAME="Brave Browser"
        ;;
    *)
        echo "Unknown channel: $CHANNEL. Valid options: stable, beta, nightly"
        exit 1
        ;;
esac

if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_HOME="$(eval echo ~${SUDO_USER})"
else
    REAL_HOME="${HOME}"
fi
USER_PLIST="${REAL_HOME}/Library/Preferences/${BROWSER_BUNDLE_ID}.plist"
MANAGED_PLIST="/Library/Managed Preferences/${BROWSER_BUNDLE_ID}.plist"
BACKUP_DIR="${REAL_HOME}/.brave-debloat-backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Policy definitions with CORRECT macOS types.
# Boolean policies are written to /Library/Managed Preferences/ via PlistBuddy.
# Integer policies are also written there.
#
# NOTE: Some policies cause Brave to crash with SIGTRAP/CHECK failures even
# when written to the managed plist with correct types. These have been removed:
#   BraveAIChatEnabled:bool:false  - Leo AI is deeply integrated; disabling crashes
#   SyncDisabled:bool:true          - Breaks browser state restoration on launch
#   BraveWalletDisabled:bool:true   - May trigger CHECK assertion in v147+
#   PromotionsEnabled:bool:false     - May trigger assertion failures
#   BackgroundModeEnabled:bool:false - May cause startup instability
#   BrowserSignin:int:0             - Affects core sign-in infrastructure
declare -a POLICIES=(
    # --- Boolean policies (feature toggles) ---
    "BraveRewardsDisabled:bool:true"
    "BraveVPNDisabled:bool:true"
    "BraveWalletDisabled:bool:true"
    "BraveNewsDisabled:bool:true"
    "BraveTalkDisabled:bool:true"
    "TorDisabled:bool:true"
    "BraveWaybackMachineEnabled:bool:false"
    "BraveP3AEnabled:bool:false"
    "BraveStatsPingEnabled:bool:false"
    "BraveWebDiscoveryEnabled:bool:false"
    "BraveSpeedreaderEnabled:bool:false"
    "MetricsReportingEnabled:bool:false"
)

print_header() {
    local line1="Brave Browser Debloater for macOS (${BRAVE_APP_NAME})"
    local line2="Disables bloat to mimic Brave Origin experience"
    local max_len=$(( ${#line1} > ${#line2} ? ${#line1} : ${#line2} ))
    local inner=$(( max_len + 4 ))
    local border
    printf -v border '%*s' "$inner" ''
    border="${border// /═}"
    echo -e "${CYAN}"
    echo "╔${border}╗"
    printf "║  %-$(( inner - 4 ))s  ║\n" "${line1}"
    printf "║  %-$(( inner - 4 ))s  ║\n" "${line2}"
    echo "╚${border}╝"
    echo -e "${NC}"
}

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info()  { echo -e "${CYAN}ℹ${NC} $1"; }

check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script requires administrator privileges (sudo)."
        echo ""
        echo "   macOS managed policies MUST be written to:"
        echo "   ${MANAGED_PLIST}"
        echo ""
        echo "   Please run with sudo:"
        echo "     sudo ./debloat-brave-macos.sh"
        echo ""
        exit 1
    fi
}

check_brave_installed() {
    if ! osascript -e "id of app \"${BRAVE_APP_NAME}\"" &>/dev/null; then
        print_error "${BRAVE_APP_NAME} does not appear to be installed."
        echo "   Please install it from https://brave.com and run it at least once."
        exit 1
    fi
    print_success "${BRAVE_APP_NAME} is installed."
}

warn_close_brave() {
    if pgrep -x "${BRAVE_PROCESS_NAME}" &>/dev/null; then
        print_warn "${BRAVE_APP_NAME} is currently running."
        echo ""
        read -rp "   Please close ${BRAVE_APP_NAME} completely and press [Enter] to continue..."
        if pgrep -x "${BRAVE_PROCESS_NAME}" &>/dev/null; then
            print_error "${BRAVE_APP_NAME} is still running. Please close it and try again."
            exit 1
        fi
    fi
    print_success "${BRAVE_APP_NAME} is not running."
}

backup_existing() {
    mkdir -p "${BACKUP_DIR}/${TIMESTAMP}"
    if [[ -f "${MANAGED_PLIST}" ]]; then
        cp "${MANAGED_PLIST}" "${BACKUP_DIR}/${TIMESTAMP}/managed_${BROWSER_BUNDLE_ID}.plist"
        print_success "Backed up managed ${BRAVE_APP_NAME} plist."
    fi
    if [[ -f "${USER_PLIST}" ]]; then
        cp "${USER_PLIST}" "${BACKUP_DIR}/${TIMESTAMP}/${BROWSER_BUNDLE_ID}.plist"
        print_success "Backed up user ${BRAVE_APP_NAME} plist."
    fi
    print_info "Backups saved to: ${BACKUP_DIR}/${TIMESTAMP}"
}

cleanup_user_prefs() {
    print_info "Cleaning up old policies from user preferences..."
    local key
    for entry in "${POLICIES[@]}"; do
        IFS=':' read -r key _ _ <<< "$entry"
        defaults delete "${BROWSER_BUNDLE_ID}" "${key}" 2>/dev/null || true
    done
    print_success "Cleaned up user preferences."
}

create_empty_plist() {
    local target="$1"
    cat > "${target}" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
EOF
    chmod 644 "${target}"
    chown root:wheel "${target}"
}

ensure_managed_plist() {
    if [[ ! -f "${MANAGED_PLIST}" ]]; then
        mkdir -p "/Library/Managed Preferences"
        create_empty_plist "${MANAGED_PLIST}"
        print_info "Created managed preferences plist."
    else
        if ! plutil -lint "${MANAGED_PLIST}" &>/dev/null; then
            print_warn "Existing managed plist is invalid. Backing up and recreating."
            mv "${MANAGED_PLIST}" "${MANAGED_PLIST}.bak.$(date +%s)"
            create_empty_plist "${MANAGED_PLIST}"
        fi
    fi
}

apply_policies() {
    local dry_run="${1:-false}"
    if [[ "$dry_run" == "true" ]]; then
        print_info "[DRY RUN] The following policies would be applied:"
        echo ""
        echo "   Target: ${MANAGED_PLIST}"
        echo ""
    else
        print_info "Applying managed policies via PlistBuddy..."
        echo ""
        ensure_managed_plist
    fi

    local key value dtype
    for entry in "${POLICIES[@]}"; do
        IFS=':' read -r key dtype value <<< "$entry"
        if [[ "$dry_run" == "true" ]]; then
            echo "   Would set: ${key} -> ${value} (${dtype})"
            continue
        fi

        # Remove existing key to ensure clean type
        /usr/libexec/PlistBuddy -c "Delete :${key}" "${MANAGED_PLIST}" 2>/dev/null || true

        # Add with correct type
        if ! /usr/libexec/PlistBuddy -c "Add :${key} ${dtype} ${value}" "${MANAGED_PLIST}" 2>/dev/null; then
            print_error "Failed to set ${key} -> ${value} (${dtype})"
            continue
        fi
        print_success "Set ${key} -> ${value} (${dtype})"
    done

    if [[ "$dry_run" != "true" ]]; then
        # Ensure permissions are correct
        chmod 644 "${MANAGED_PLIST}"
        chown root:wheel "${MANAGED_PLIST}"
        # Flush preferences cache
        killall cfprefsd 2>/dev/null || true
        echo ""
        print_success "All policies applied."
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Debloating complete! (${BRAVE_APP_NAME})${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "The following features have been DISABLED:"
    echo "  • Brave News"
    echo "  • Brave Rewards & Ads"
    echo "  • Brave Wallet & Web3"
    echo "  • Speedreader"
    echo "  • Telemetry (P3A, daily usage ping, metrics)"
    echo "  • Brave Talk"
    echo "  • Tor private windows"
    echo "  • Brave VPN"
    echo "  • Wayback Machine integration"
    echo "  • Web Discovery Project"
    echo ""
    echo -e "${YELLOW}SKIPPED (crash-causing on v147+):${NC}"
    echo "  • Leo AI Chat (policy crashes Brave)"
    echo "  • Sync (policy breaks state restoration)"
    echo ""
    echo -e "${YELLOW}Tip:${NC} To disable Leo AI without a policy, go to"
    echo "  brave://settings/leo and turn it off manually."
    echo ""
    echo -e "${YELLOW}IMPORTANT:${NC} Please restart ${BRAVE_APP_NAME} for all changes to take effect."
    echo ""
    echo "You can verify policies are active by visiting:"
    echo "  brave://policy"
    echo ""
    print_info "To undo these changes, run:"
    echo "  sudo ./debloat-brave-macos.sh --channel ${CHANNEL} --restore"
    echo ""
    echo -e "${YELLOW}Note:${NC} You may see 'Managed by your organization' in Brave's menu."
    echo "      This is normal and expected when policy values are active."
    echo ""
}

restore_backup() {
    echo ""
    print_info "Available backups for ${BRAVE_APP_NAME}:"
    if [[ ! -d "${BACKUP_DIR}" ]]; then
        print_error "No backup directory found."
        exit 1
    fi
    local backups=()
    while IFS= read -r -d '' dir; do
        local bname
        bname="$(basename "$dir")"
        # Only include backups that contain files for the current channel
        if compgen -G "${BACKUP_DIR}/${bname}/*${BROWSER_BUNDLE_ID}*" > /dev/null 2>&1; then
            backups+=("${bname}")
        fi
    done < <(find "${BACKUP_DIR}" -maxdepth 1 -mindepth 1 -type d -print0 | sort -z)
    if [[ ${#backups[@]} -eq 0 ]]; then
        print_error "No backups found for ${BRAVE_APP_NAME}."
        exit 1
    fi
    echo ""
    local i=1
    for b in "${backups[@]}"; do
        echo "  ${i}) ${b}"
        ((i++))
    done
    echo ""
    read -rp "Select a backup to restore (1-${#backups[@]}): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backups[@]} )); then
        print_error "Invalid selection."
        exit 1
    fi
    local selected="${backups[$((choice-1))]}"
    local restore_path="${BACKUP_DIR}/${selected}"
    print_warn "This will restore ${BRAVE_APP_NAME} policies from backup: ${selected}"
    read -rp "Are you sure? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local restored=false
        if [[ -f "${restore_path}/managed_${BROWSER_BUNDLE_ID}.plist" ]]; then
            mkdir -p "$(dirname "${MANAGED_PLIST}")"
            cp "${restore_path}/managed_${BROWSER_BUNDLE_ID}.plist" "${MANAGED_PLIST}"
            chmod 644 "${MANAGED_PLIST}"
            chown root:wheel "${MANAGED_PLIST}"
            print_success "Restored managed plist preferences."
            restored=true
        else
            # Backup was made for this channel but no managed plist existed at backup time —
            # remove the current managed plist to restore that "no policies" state.
            if [[ -f "${MANAGED_PLIST}" ]]; then
                rm -f "${MANAGED_PLIST}"
                print_success "Removed managed policies (none existed at backup time)."
                restored=true
            fi
        fi
        if [[ -f "${restore_path}/${BROWSER_BUNDLE_ID}.plist" ]]; then
            cp "${restore_path}/${BROWSER_BUNDLE_ID}.plist" "${USER_PLIST}"
            print_success "Restored user plist preferences."
            restored=true
        fi
        killall cfprefsd 2>/dev/null || true
        if [[ "$restored" == "true" ]]; then
            print_success "Restore complete. Please restart ${BRAVE_APP_NAME}."
        else
            print_warn "Nothing to restore from this backup."
        fi
    else
        print_info "Restore cancelled."
    fi
}

uninstall_policies() {
    if [[ ! -f "${MANAGED_PLIST}" ]]; then
        print_info "No managed policies plist found for ${BRAVE_APP_NAME}. Nothing to remove."
        return
    fi
    print_warn "This will remove ALL managed policies from ${BRAVE_APP_NAME}."
    read -rp "Are you sure? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Uninstall cancelled."
        return
    fi
    rm -f "${MANAGED_PLIST}"
    print_success "Removed managed policies plist."
    cleanup_user_prefs
    killall cfprefsd 2>/dev/null || true
    echo ""
    print_success "All policies removed. Please restart ${BRAVE_APP_NAME}."
}

show_help() {
    cat << 'EOF'
Brave Browser Debloater for macOS

Usage:
  sudo ./debloat-brave-macos.sh                        Apply debloat (stable)
  sudo ./debloat-brave-macos.sh --channel beta         Apply debloat for Brave Beta
  sudo ./debloat-brave-macos.sh --channel nightly      Apply debloat for Brave Nightly
  sudo ./debloat-brave-macos.sh --dry-run              Preview what would change (no modifications)
  sudo ./debloat-brave-macos.sh --restore              Restore from a previous backup
  sudo ./debloat-brave-macos.sh --uninstall            Remove all managed policies
  ./debloat-brave-macos.sh --help                      Show this help message

Channel-specific operations:
  sudo ./debloat-brave-macos.sh --channel beta --dry-run
  sudo ./debloat-brave-macos.sh --channel nightly --restore
  sudo ./debloat-brave-macos.sh --channel beta --uninstall

Channels:
  stable   Brave Browser              (com.brave.Browser)
  beta     Brave Browser Beta         (com.brave.Browser.Beta)
  nightly  Brave Browser Nightly      (com.brave.Browser.Nightly)

This script disables Brave's non-core features by applying macOS managed
policies with the CORRECT data types via PlistBuddy.

CRITICAL: Brave boolean policies MUST be written to:
  /Library/Managed Preferences/<bundle-id>.plist
Writing them via `defaults write` to the user plist with -bool causes
Brave to crash on startup. This script uses the proper managed path.

Note: --restore and --uninstall both require sudo because the managed
policy file is owned by root.

Features disabled:
  Brave News, Rewards, Wallet/Web3, Speedreader, Telemetry, Talk, Tor,
  VPN, Wayback Machine, Web Discovery Project

Features NOT disabled (caused crashes in v147+):
  Leo AI Chat, Sync

You must close Brave before running this script.
EOF
}

main() {
    # Strip --channel [value] from positional args for the main case switch
    local filtered_args=()
    local _skip=false
    for arg in "$@"; do
        if [[ "$_skip" == "true" ]]; then
            _skip=false
            continue
        fi
        case "$arg" in
            --channel=*) ;;
            --channel)   _skip=true ;;
            *)           filtered_args+=("$arg") ;;
        esac
    done

    case "${filtered_args[0]:-}" in
        --restore)
            check_sudo
            restore_backup
            exit 0
            ;;
        --uninstall)
            check_sudo
            uninstall_policies
            exit 0
            ;;
        --dry-run)
            print_header
            check_sudo
            check_brave_installed
            apply_policies true
            exit 0
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
    esac

    print_header
    check_sudo
    check_brave_installed
    warn_close_brave
    backup_existing
    cleanup_user_prefs
    apply_policies false
    print_summary
}

main "$@"
