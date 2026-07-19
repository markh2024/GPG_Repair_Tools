#!/bin/bash
#
# gpg_keyring_repair.sh
#
# GPG keyring lock repair, diagnostics, and backup/restore utility
#
# Author: Mark Harrington
#
# Usage:
#   ./gpg_keyring_repair.sh                 Run the repair/diagnostic flow (default)
#   ./gpg_keyring_repair.sh repair          Same as above, explicit
#   ./gpg_keyring_repair.sh backup          Export keys, trust, revocation certs, config
#   ./gpg_keyring_repair.sh restore <file>  Restore from a backup archive (.tar.gz or .tar.gz.gpg)
#   ./gpg_keyring_repair.sh -h | --help     Show usage
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

title "GPG Keyring Repair Utility"
info "$(date)"

# ===============================
# Shared helpers
# ===============================
usage()
{
    cat <<EOF
Usage: $0 [repair|backup|restore <file>|-h|--help]

  repair            Run lock/permission diagnostics and repair (default)
  backup            Export public keys, secret keys, owner trust,
                     revocation certificates, and config to a backup archive
  restore <file>    Restore from a backup archive produced by 'backup'
  -h, --help        Show this help text
EOF
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

generate_gpg_key()
{
    title "No GPG key found - generating one"
    read -p "Enter your name: " USER_NAME
    read -p "Enter your email address: " USER_EMAIL
    info "Generating GPG key (this can take a moment)..."

    # %no-protection avoids gpg hanging on a pinentry prompt for a
    # passphrase when run non-interactively/in batch mode.
    if gpg --batch --generate-key <<EOF
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: $USER_NAME
Name-Email: $USER_EMAIL
Expire-Date: 0
%no-protection
%commit
EOF
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
    info "Checking for secret keys..."
    if gpg --list-secret-keys 2>/dev/null | grep -q "^sec"
    then
        success "Secret key found"
    else
        warning "No secret keys found"
        generate_gpg_key
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
    if gpgconf --kill gpg-agent 2>/dev/null
    then
        success "gpg-agent stopped"
    else
        warning "gpg-agent was not running"
    fi
    sleep 2

    title "[7] Removing stale locks"
    for LOCK in $(find "$GPGDIR" -name "*.lock")
    do
        if lsof "$LOCK" >/dev/null 2>&1
        then
            warning "Lock active - keeping: $LOCK"
        else
            info "Removing stale lock: $LOCK"
            rm -f "$LOCK"
            success "Removed $LOCK"
        fi
    done

    title "[8] Repairing permissions"
    chmod 700 "$GPGDIR"
    find "$GPGDIR" -type f -exec chmod 600 {} \;
    success "Permissions corrected"

    title "[9] Restarting gpg-agent"
    if gpgconf --launch gpg-agent
    then
        success "gpg-agent started"
    else
        error "Failed to start gpg-agent"
    fi
    sleep 1

    title "[10] Secret key check"
    check_secret_key

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
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_DIR="$BACKUP_ROOT/backup_$TIMESTAMP"
    mkdir -p "$BACKUP_DIR"
    info "Staging backup in: $BACKUP_DIR"

    info "Exporting public keys..."
    if gpg --export --armor > "$BACKUP_DIR/public_keys.asc" 2>/dev/null && [ -s "$BACKUP_DIR/public_keys.asc" ]
    then
        success "Public keys exported"
    else
        warning "No public keys exported (keyring may be empty)"
    fi

    info "Exporting secret keys..."
    if gpg --export-secret-keys --armor > "$BACKUP_DIR/secret_keys.asc" 2>/dev/null && [ -s "$BACKUP_DIR/secret_keys.asc" ]
    then
        success "Secret keys exported"
        warning "secret_keys.asc contains your private key material - handle with care"
    else
        warning "No secret keys exported (none present?)"
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

    read -p "Encrypt the archive with a passphrase? (recommended, since it may contain secret keys) (y/n): " ENCRYPT_ANSWER
    if [[ "$ENCRYPT_ANSWER" == "y" ]]
    then
        if gpg --symmetric --cipher-algo AES256 "$ARCHIVE"
        then
            rm -f "$ARCHIVE"
            success "Encrypted archive created: ${ARCHIVE}.gpg"
            warning "Store the passphrase safely - it is NOT recoverable if lost"
        else
            error "Encryption failed - unencrypted archive left at $ARCHIVE"
        fi
    else
        warning "Archive left unencrypted at $ARCHIVE - store it somewhere safe"
    fi

    rm -rf "$BACKUP_DIR"
    success "Backup complete"
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
        gpg --import "$BACKUP_DIR/public_keys.asc"
        success "Public keys imported"
    fi

    if [ -f "$BACKUP_DIR/secret_keys.asc" ]
    then
        warning "This will import private keys into:"
        echo "$GPGDIR"
        read -p "Continue? (yes/no): " CONFIRM
        if [[ "$CONFIRM" != "yes" ]]
        then
            warning "Restore cancelled"
            rm -rf "$WORKDIR"
            exit 0
        fi

        info "Importing secret keys..."
        gpg --import "$BACKUP_DIR/secret_keys.asc"
        success "Secret keys imported"
    fi

    if [ -f "$BACKUP_DIR/owner_trust.txt" ]
    then
        info "Restoring owner trust..."
        gpg --import-ownertrust "$BACKUP_DIR/owner_trust.txt"
        success "Owner trust restored"
    fi

    if [ -d "$BACKUP_DIR/revocation_certs" ]
    then
        mkdir -p "$GPGDIR/openpgp-revocs.d"
        shopt -s nullglob
        local REVFILES=("$BACKUP_DIR"/revocation_certs/*.rev)
        if [ "${#REVFILES[@]}" -gt 0 ]
        then
            cp "${REVFILES[@]}" "$GPGDIR/openpgp-revocs.d/"
            chmod 600 "$GPGDIR"/openpgp-revocs.d/*.rev
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
            cp "$CFG" "$GPGDIR/"
            success "Restored $(basename "$CFG")"
        done
        shopt -u nullglob
    fi

    rm -rf "$WORKDIR"

    info "Restarting gpg-agent..."
    gpgconf --kill gpg-agent 2>/dev/null || warning "gpg-agent was not running"
    gpgconf --launch gpg-agent
    success "Restore complete"
}

# ===============================
# Entry point
# ===============================
COMMAND="${1:-repair}"

case "$COMMAND" in
    repair)
        repair_flow
        ;;
    backup)
        backup_gpg
        ;;
    restore)
        restore_gpg "${2:-}"
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
