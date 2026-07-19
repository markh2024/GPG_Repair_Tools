#!/bin/bash
#
# gpg_keyring_repair.sh
#
# GPG keyring lock repair, diagnostics, and backup/restore utility
#
# Author: Mark Harrington
#
# Usage:
#   ./gpg_keyring_repair.sh                          Run repair (default)
#   ./gpg_keyring_repair.sh repair [options]
#       --dry-run           Show what would change, make no changes
#       --quiet             Suppress colour and non-essential output
#       --name NAME         Non-interactive key generation: real name
#       --email EMAIL       Non-interactive key generation: email address
#
#   ./gpg_keyring_repair.sh backup [options]
#       --key ID            Only export this key (fingerprint/ID/email)
#       --no-encrypt        Skip encrypting the archive (not recommended)
#       --quiet             Suppress colour and non-essential output
#
#   ./gpg_keyring_repair.sh restore <file> [options]
#       --gnupghome DIR     Restore into DIR instead of ~/.gnupg
#       --test              Restore into a throwaway temp GNUPGHOME to
#                            inspect the backup without touching your
#                            real keyring
#       --quiet             Suppress colour and non-essential output
#
#   ./gpg_keyring_repair.sh -h | --help              Show usage
#
# See also: gpg_toolkit_menu.sh for an interactive menu over this script.
#

# ===============================
# Strict error handling
# ===============================
set -o errexit    # exit on any unhandled non-zero exit status
set -o nounset     # treat unset variables as an error
set -o pipefail    # a pipeline fails if any stage fails, not just the last
set -o errtrace    # ERR trap is inherited by functions/subshells
IFS=$'\n\t'        # safer word-splitting (keeps spaces in filenames intact)

trap 'error "Unexpected failure at line ${LINENO} (command: ${BASH_COMMAND})"; exit 1' ERR
trap 'echo; warning "Interrupted by user"; exit 130' INT

# ===============================
# Colour definitions
# ===============================
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
RESET='\033[0m'

# Disable colour codes when stdout isn't a terminal (e.g. redirected to a
# file or piped) so logs and captured output don't fill up with raw ANSI
# escape sequences.
if [ ! -t 1 ]
then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    WHITE=''
    RESET=''
fi

info()
{
    echo -e "${BLUE}[INFO]${RESET} $1"
}
success()
{
    echo -e "${GREEN}[ OK ]${RESET} $1"
}
warning()
{
    echo -e "${YELLOW}[WARN]${RESET} $1"
}
error()
{
    echo -e "${RED}[FAIL]${RESET} $1"
}
title()
{
    echo
    echo -e "${CYAN}======================================${RESET}"
    echo -e "${WHITE}$1${RESET}"
    echo -e "${CYAN}======================================${RESET}"
}

# ===============================
# Globals
# ===============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="$SCRIPT_DIR/gpg_repair_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

GPGDIR="$HOME/.gnupg"
BACKUP_ROOT="$SCRIPT_DIR/backups"
MAX_LOGS=10

# Per-command option defaults (declared here so `set -u` never trips on
# them, regardless of which command actually runs).
DRY_RUN=false
QUIET=false
REPAIR_NAME=""
REPAIR_EMAIL=""
BACKUP_KEY=""
NO_ENCRYPT=false
RESTORE_TEST=false
RESTORE_GNUPGHOME=""

title "GPG Keyring Repair Utility"
info "$(date)"

# ===============================
# Log rotation
# ===============================
rotate_logs()
{
    local ALL_LOGS TOTAL EXCESS i
    ALL_LOGS=()
    while IFS= read -r LINE
    do
        ALL_LOGS+=("$LINE")
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -name 'gpg_repair_*.log' | sort)

    TOTAL="${#ALL_LOGS[@]}"
    if [ "$TOTAL" -gt "$MAX_LOGS" ]
    then
        EXCESS=$((TOTAL - MAX_LOGS))
        for ((i = 0; i < EXCESS; i++))
        do
            info "Rotating out old log: ${ALL_LOGS[$i]}"
            rm -f "${ALL_LOGS[$i]}"
        done
    fi
}
rotate_logs

# ===============================
# Shared helpers
# ===============================
usage()
{
    cat <<USAGE_EOF
Usage: $0 [repair|backup|restore <file>|-h|--help] [options]

  repair [options]           Run lock/permission diagnostics and repair
    --dry-run                   Show what would change, make no changes
    --quiet                     Suppress colour and non-essential output
    --name NAME                 Non-interactive key generation: real name
    --email EMAIL                Non-interactive key generation: email

  backup [options]            Export public keys, secret keys, owner
                               trust, revocation certificates, and
                               config to an archive. Encrypted by
                               default. A .sha256 checksum is written
                               alongside the archive.
    --key ID                    Only export this key (fingerprint/ID/email)
    --no-encrypt                 Skip encryption (not recommended)
    --quiet                     Suppress colour and non-essential output

  restore <file> [options]    Restore from a backup archive produced by
                               'backup'. Checksum is verified automatically
                               if a matching .sha256 file is present.
    --gnupghome DIR              Restore into DIR instead of ~/.gnupg
    --test                      Restore into a throwaway temp GNUPGHOME to
                                 inspect the backup without touching your
                                 real keyring
    --quiet                     Suppress colour and non-essential output

  -h, --help                  Show this help text
USAGE_EOF
}

apply_quiet_mode()
{
    if [ "$QUIET" = true ]
    then
        RED=''
        GREEN=''
        YELLOW=''
        BLUE=''
        CYAN=''
        WHITE=''
        RESET=''
        info() { :; }
        title() { :; }
    fi
}

check_gpg()
{
    if ! command -v gpg >/dev/null 2>&1
    then
        error "gpg not installed"
        read -p "Install GPG now? (y/n): " ANSWER
        if [[ "$ANSWER" == "y" ]]
        then
            if command -v zypper >/dev/null 2>&1
            then
                sudo zypper install -y gpg2
            elif command -v apt >/dev/null 2>&1
            then
                sudo apt install -y gnupg
            else
                error "Unknown package manager - install GPG manually"
                exit 1
            fi
            success "GPG installed"
        else
            error "GPG is required - exiting"
            exit 1
        fi
    fi
}

check_gpg_version()
{
    local VERLINE VERNUM MAJOR MINOR REST
    VERLINE=$(gpg --version | head -n 1)
    VERNUM=$(echo "$VERLINE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    if [ -z "$VERNUM" ]
    then
        warning "Could not determine GPG version for a compatibility check"
        return 0
    fi
    MAJOR="${VERNUM%%.*}"
    REST="${VERNUM#*.}"
    MINOR="${REST%%.*}"
    if (( MAJOR < 2 || (MAJOR == 2 && MINOR < 1) ))
    then
        warning "GPG $VERNUM detected. This script assumes GPG 2.1+ (per-key private-keys-v1.d secret key storage, gpg-agent-driven locking). Lock file layout and secret key storage differ meaningfully on 1.x - some steps here may not behave as documented."
    else
        success "GPG $VERNUM meets the 2.1+ baseline this script assumes"
    fi
}

generate_gpg_key()
{
    local NAME="${1:-}" EMAIL="${2:-}"
    title "No GPG key found - generating one"

    if [ -z "$NAME" ]
    then
        read -p "Enter your name: " NAME
    fi
    if [ -z "$EMAIL" ]
    then
        read -p "Enter your email address: " EMAIL
    fi

    if [ "$DRY_RUN" = true ]
    then
        info "[DRY-RUN] Would generate a 4096-bit RSA key for $NAME <$EMAIL>"
        return 0
    fi

    info "Generating GPG key for $NAME <$EMAIL> (this can take a moment)..."

    # %no-protection avoids gpg hanging on a pinentry prompt for a
    # passphrase when run non-interactively/in batch mode.
    if gpg --batch --generate-key <<KEYGEN_EOF
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: $NAME
Name-Email: $EMAIL
Expire-Date: 0
%no-protection
%commit
KEYGEN_EOF
    then
        success "GPG key generation complete"
        gpg --list-secret-keys
    else
        error "GPG key generation failed"
        exit 1
    fi
}

check_secret_key()
{
    local NAME="${1:-}" EMAIL="${2:-}"
    info "Checking for secret keys..."
    if gpg --list-secret-keys 2>/dev/null | grep -q "^sec"
    then
        success "Secret key found"
    else
        warning "No secret keys found"
        generate_gpg_key "$NAME" "$EMAIL"
    fi
}

# ===============================
# Repair / diagnostics flow
# ===============================
repair_flow()
{
    check_gpg

    title "[1] GPG version"
    gpg --version | head -n 3
    check_gpg_version

    title "[2] Running GPG processes"
    if ! pgrep -af gpg
    then
        warning "No GPG processes found"
    fi

    title "[3] Checking GPG directory"
    info "Using: $GPGDIR"
    if [ ! -d "$GPGDIR" ]
    then
        warning "$GPGDIR does not exist - creating it"
        mkdir -p "$GPGDIR"
        success "Created $GPGDIR"
    fi

    title "[4] Checking lock files"
    local LOCKS
    LOCKS=$(find "$GPGDIR" -name "*.lock")
    if [ -z "$LOCKS" ]
    then
        success "No lock files found"
    else
        warning "Lock files present:"
        echo "$LOCKS"
    fi

    title "[5] Checking lock owners"
    if [ -n "$LOCKS" ]
    then
        for LOCK in $LOCKS
        do
            info "Lock: $LOCK"
            if ! lsof "$LOCK" 2>/dev/null
            then
                info "No process owns this lock"
            fi
        done
    fi

    title "[6] Stopping gpg-agent"
    if [ "$DRY_RUN" = true ]
    then
        info "[DRY-RUN] Would run: gpgconf --kill gpg-agent"
    else
        if gpgconf --kill gpg-agent 2>/dev/null
        then
            success "gpg-agent stopped"
        else
            warning "gpg-agent was not running"
        fi
        sleep 2
    fi

    title "[7] Removing stale locks"
    for LOCK in $(find "$GPGDIR" -name "*.lock")
    do
        if lsof "$LOCK" >/dev/null 2>&1
        then
            warning "Lock active - keeping: $LOCK"
        elif [ "$DRY_RUN" = true ]
        then
            info "[DRY-RUN] Would remove stale lock: $LOCK"
        else
            info "Removing stale lock: $LOCK"
            rm -f "$LOCK"
            success "Removed $LOCK"
        fi
    done

    title "[8] Repairing permissions"
    if [ "$DRY_RUN" = true ]
    then
        info "[DRY-RUN] Would run: chmod 700 $GPGDIR ; chmod 600 on files inside it"
    else
        chmod 700 "$GPGDIR"
        find "$GPGDIR" -type f -exec chmod 600 {} \;
        success "Permissions corrected"
    fi

    title "[9] Restarting gpg-agent"
    if [ "$DRY_RUN" = true ]
    then
        info "[DRY-RUN] Would run: gpgconf --launch gpg-agent"
    else
        if gpgconf --launch gpg-agent
        then
            success "gpg-agent started"
        else
            error "Failed to start gpg-agent"
        fi
        sleep 1
    fi

    title "[10] Secret key check"
    if [ "$DRY_RUN" = true ]
    then
        if gpg --list-secret-keys 2>/dev/null | grep -q "^sec"
        then
            success "Secret key found"
        else
            warning "No secret keys found - [DRY-RUN] would prompt to generate one"
        fi
    else
        check_secret_key "$REPAIR_NAME" "$REPAIR_EMAIL"
    fi

    title "[11] Secret key test"
    if ! gpg -K
    then
        warning "No secret keys present"
    fi

    title "[12] Public key test"
    if ! gpg --list-keys
    then
        warning "No public keys present"
    fi

    title "Repair completed"
    if [ "$DRY_RUN" = true ]
    then
        warning "This was a dry run - no changes were made"
    fi
    success "Log saved: $LOGFILE"
}

# ===============================
# Backup
# ===============================
backup_gpg()
{
    title "GPG Key Backup"
    check_gpg

    local TIMESTAMP BACKUP_DIR ARCHIVE
    local EXPORT_ARGS=()
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_DIR="$BACKUP_ROOT/backup_$TIMESTAMP"
    mkdir -p "$BACKUP_DIR"
    info "Staging backup in: $BACKUP_DIR"

    if [ -n "$BACKUP_KEY" ]
    then
        EXPORT_ARGS=("$BACKUP_KEY")
        info "Restricting export to key: $BACKUP_KEY"
    fi

    info "Exporting public keys..."
    if gpg --export --armor "${EXPORT_ARGS[@]}" > "$BACKUP_DIR/public_keys.asc" 2>/dev/null && [ -s "$BACKUP_DIR/public_keys.asc" ]
    then
        success "Public keys exported"
    else
        warning "No public keys exported (keyring may be empty, or key ID not found)"
    fi

    info "Exporting secret keys..."
    if gpg --export-secret-keys --armor "${EXPORT_ARGS[@]}" > "$BACKUP_DIR/secret_keys.asc" 2>/dev/null && [ -s "$BACKUP_DIR/secret_keys.asc" ]
    then
        success "Secret keys exported"
        warning "secret_keys.asc contains your private key material - handle with care"
    else
        warning "No secret keys exported (none present, or key ID not found)"
    fi

    info "Exporting owner trust database..."
    if gpg --export-ownertrust > "$BACKUP_DIR/owner_trust.txt" 2>/dev/null
    then
        success "Owner trust exported"
    else
        warning "Owner trust export failed"
    fi

    info "Copying revocation certificates..."
    mkdir -p "$BACKUP_DIR/revocation_certs"
    shopt -s nullglob
    local REVOCS=("$GPGDIR"/openpgp-revocs.d/*.rev)
    if [ "${#REVOCS[@]}" -gt 0 ]
    then
        cp "${REVOCS[@]}" "$BACKUP_DIR/revocation_certs/"
        success "${#REVOCS[@]} revocation certificate(s) copied"
    else
        warning "No revocation certificates found"
    fi
    shopt -u nullglob

    info "Copying configuration files..."
    mkdir -p "$BACKUP_DIR/config"
    local CFG_COPIED=0
    for CFG in gpg.conf gpg-agent.conf dirmngr.conf
    do
        if [ -f "$GPGDIR/$CFG" ]
        then
            cp "$GPGDIR/$CFG" "$BACKUP_DIR/config/"
            success "Copied $CFG"
            CFG_COPIED=1
        fi
    done
    if [ "$CFG_COPIED" -eq 0 ]
    then
        warning "No configuration files found to copy"
    fi

    info "Writing manifest..."
    cat > "$BACKUP_DIR/MANIFEST.txt" <<EOF
GPG Backup
==========
Created:
$(date)
User:
$(whoami)
Hostname:
$(hostname)
GPG Version:
$(gpg --version | head -n 1)
Key scope:
${BACKUP_KEY:-all keys in keyring}
Files:
$(find "$BACKUP_DIR" -type f)
EOF
    success "Manifest written"

    chmod -R go-rwx "$BACKUP_DIR"

    info "Compressing backup..."
    ARCHIVE="$BACKUP_ROOT/gpg_backup_$TIMESTAMP.tar.gz"
    tar -czf "$ARCHIVE" -C "$BACKUP_ROOT" "backup_$TIMESTAMP"
    chmod 600 "$ARCHIVE"
    success "Archive created: $ARCHIVE"
    rm -rf "$BACKUP_DIR"

    if [ "$NO_ENCRYPT" = true ]
    then
        warning "Encryption skipped (--no-encrypt) - archive left unencrypted at $ARCHIVE"
    else
        info "Encrypting backup (default) - you will be prompted for a passphrase..."
        if gpg --symmetric --cipher-algo AES256 "$ARCHIVE"
        then
            rm -f "$ARCHIVE"
            ARCHIVE="${ARCHIVE}.gpg"
            success "Encrypted archive created: $ARCHIVE"
            warning "Store the passphrase safely - it is NOT recoverable if lost"
        else
            error "Encryption failed - unencrypted archive left at $ARCHIVE"
        fi
    fi

    info "Generating checksum..."
    ( cd "$(dirname "$ARCHIVE")" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256" )
    success "Checksum written: ${ARCHIVE}.sha256"

    title "Backup complete"
    success "Archive: $ARCHIVE"
    warning "This backup may contain private key material. Copy it to offline or removable storage (e.g. a USB drive or encrypted external disk) rather than relying on this disk alone."
    info "Verify integrity later with: sha256sum -c $(basename "${ARCHIVE}.sha256")"
}

# ===============================
# Restore
# ===============================
restore_gpg()
{
    local SOURCE="${1:-}"
    title "GPG Key Restore"
    check_gpg

    if [ -z "$SOURCE" ]
    then
        error "No backup file specified"
        usage
        exit 1
    fi

    if [ ! -f "$SOURCE" ]
    then
        error "Backup file not found: $SOURCE"
        exit 1
    fi

    if [ -f "${SOURCE}.sha256" ]
    then
        info "Verifying checksum..."
        if ( cd "$(dirname "$SOURCE")" && sha256sum -c "$(basename "${SOURCE}.sha256")" )
        then
            success "Checksum verified"
        else
            error "Checksum verification FAILED - the archive may be corrupted or tampered with"
            read -p "Continue anyway? (yes/no): " CKCONFIRM
            if [[ "$CKCONFIRM" != "yes" ]]
            then
                warning "Restore cancelled"
                exit 1
            fi
        fi
    else
        warning "No checksum file found alongside the archive (${SOURCE}.sha256) - integrity not verified"
    fi

    local RESTORE_HOME
    if [ "$RESTORE_TEST" = true ]
    then
        RESTORE_HOME=$(mktemp -d)
        chmod 700 "$RESTORE_HOME"
        info "Test restore mode - using isolated GNUPGHOME: $RESTORE_HOME"
    elif [ -n "$RESTORE_GNUPGHOME" ]
    then
        RESTORE_HOME="$RESTORE_GNUPGHOME"
        mkdir -p "$RESTORE_HOME"
        chmod 700 "$RESTORE_HOME"
        info "Restoring into custom GNUPGHOME: $RESTORE_HOME"
    else
        RESTORE_HOME="$GPGDIR"
        info "Restoring into: $RESTORE_HOME"
    fi

    local WORKDIR ARCHIVE BACKUP_DIR
    WORKDIR=$(mktemp -d)
    ARCHIVE="$SOURCE"

    if [[ "$SOURCE" == *.gpg ]]
    then
        info "Decrypting archive..."
        ARCHIVE="$WORKDIR/decrypted.tar.gz"
        if ! gpg --output "$ARCHIVE" --decrypt "$SOURCE"
        then
            error "Decryption failed"
            rm -rf "$WORKDIR"
            exit 1
        fi
        success "Archive decrypted"
    fi

    info "Extracting archive..."
    tar -xzf "$ARCHIVE" -C "$WORKDIR"
    BACKUP_DIR=$(find "$WORKDIR" -maxdepth 1 -type d -name "backup_*" | head -n 1)

    if [ -z "$BACKUP_DIR" ]
    then
        error "Backup structure not recognised inside archive"
        rm -rf "$WORKDIR"
        exit 1
    fi

    if [ -f "$BACKUP_DIR/public_keys.asc" ]
    then
        info "Importing public keys..."
        GNUPGHOME="$RESTORE_HOME" gpg --import "$BACKUP_DIR/public_keys.asc"
        success "Public keys imported"
    fi

    if [ -f "$BACKUP_DIR/secret_keys.asc" ]
    then
        warning "This will import private keys into:"
        echo "$RESTORE_HOME"
        read -p "Continue? (yes/no): " CONFIRM
        if [[ "$CONFIRM" != "yes" ]]
        then
            warning "Restore cancelled"
            rm -rf "$WORKDIR"
            exit 0
        fi

        info "Importing secret keys..."
        GNUPGHOME="$RESTORE_HOME" gpg --import "$BACKUP_DIR/secret_keys.asc"
        success "Secret keys imported"
    fi

    if [ -f "$BACKUP_DIR/owner_trust.txt" ]
    then
        info "Restoring owner trust..."
        GNUPGHOME="$RESTORE_HOME" gpg --import-ownertrust "$BACKUP_DIR/owner_trust.txt"
        success "Owner trust restored"
    fi

    if [ -d "$BACKUP_DIR/revocation_certs" ]
    then
        mkdir -p "$RESTORE_HOME/openpgp-revocs.d"
        shopt -s nullglob
        local REVFILES=("$BACKUP_DIR"/revocation_certs/*.rev)
        if [ "${#REVFILES[@]}" -gt 0 ]
        then
            cp "${REVFILES[@]}" "$RESTORE_HOME/openpgp-revocs.d/"
            chmod 600 "$RESTORE_HOME"/openpgp-revocs.d/*.rev
            success "${#REVFILES[@]} revocation certificate(s) restored"
        else
            warning "No revocation certificates in backup"
        fi
        shopt -u nullglob
    fi

    if [ -d "$BACKUP_DIR/config" ]
    then
        shopt -s nullglob
        local CFGFILES=("$BACKUP_DIR"/config/*)
        for CFG in "${CFGFILES[@]}"
        do
            cp "$CFG" "$RESTORE_HOME/"
            success "Restored $(basename "$CFG")"
        done
        shopt -u nullglob
    fi

    rm -rf "$WORKDIR"

    if [ "$RESTORE_TEST" = true ]
    then
        title "Test restore complete"
        success "Isolated keyring populated at: $RESTORE_HOME"
        info "Inspect it without touching your real keyring, e.g.:"
        info "  GNUPGHOME=$RESTORE_HOME gpg --list-keys"
        warning "This is a temporary directory - remove it when done: rm -rf $RESTORE_HOME"
    else
        info "Restarting gpg-agent..."
        GNUPGHOME="$RESTORE_HOME" gpgconf --kill gpg-agent 2>/dev/null || warning "gpg-agent was not running"
        GNUPGHOME="$RESTORE_HOME" gpgconf --launch gpg-agent
        success "Restore complete"
    fi
}

# ===============================
# Entry point
# ===============================
COMMAND="${1:-repair}"
if [ $# -gt 0 ]
then
    shift
fi

case "$COMMAND" in
    repair)
        while [ $# -gt 0 ]
        do
            case "$1" in
                --dry-run)
                    DRY_RUN=true
                    shift
                    ;;
                --quiet)
                    QUIET=true
                    shift
                    ;;
                --name)
                    REPAIR_NAME="${2:-}"
                    shift 2
                    ;;
                --email)
                    REPAIR_EMAIL="${2:-}"
                    shift 2
                    ;;
                *)
                    error "Unknown option for repair: $1"
                    usage
                    exit 1
                    ;;
            esac
        done
        apply_quiet_mode
        repair_flow
        ;;
    backup)
        while [ $# -gt 0 ]
        do
            case "$1" in
                --key)
                    BACKUP_KEY="${2:-}"
                    shift 2
                    ;;
                --no-encrypt)
                    NO_ENCRYPT=true
                    shift
                    ;;
                --quiet)
                    QUIET=true
                    shift
                    ;;
                *)
                    error "Unknown option for backup: $1"
                    usage
                    exit 1
                    ;;
            esac
        done
        apply_quiet_mode
        backup_gpg
        ;;
    restore)
        SOURCE=""
        while [ $# -gt 0 ]
        do
            case "$1" in
                --gnupghome)
                    RESTORE_GNUPGHOME="${2:-}"
                    shift 2
                    ;;
                --test)
                    RESTORE_TEST=true
                    shift
                    ;;
                --quiet)
                    QUIET=true
                    shift
                    ;;
                *)
                    if [ -z "$SOURCE" ]
                    then
                        SOURCE="$1"
                        shift
                    else
                        error "Unknown option for restore: $1"
                        usage
                        exit 1
                    fi
                    ;;
            esac
        done
        apply_quiet_mode
        restore_gpg "$SOURCE"
        ;;
    -h|--help)
        usage
        ;;
    *)
        error "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac

echo
title "Log saved: $LOGFILE"
