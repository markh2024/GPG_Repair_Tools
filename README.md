# GPG_Repair_Tools 

# MD Harrington Bexleyheath Kent London UK 


---
A Bash utility for diagnosing and repairing a stuck/locked GPG keyring, and
for backing up and restoring your GPG keys, trust database, revocation
certificates, and configuration.

---


# gpg_keyring_repair.sh


---

## 1. What the script does

It has three modes, selected by the first argument:

| Command | Purpose |
|---|---|
| `repair` (default) | Diagnoses and fixes the most common causes of a "keyring is locked / gpg hangs" problem |
| `backup` | Exports everything needed to fully restore your GPG identity elsewhere |
| `restore <file>` | Re-imports a backup produced by `backup` |

```bash
./gpg_keyring_repair.sh            # repair (default)
./gpg_keyring_repair.sh backup
./gpg_keyring_repair.sh restore ~/gpg_backups/gpg_backup_20260719_115131.tar.gz.gpg
./gpg_keyring_repair.sh --help
```

Every run writes a timestamped log to `~/gpg_repair_YYYYMMDD_HHMMSS.log`
(everything printed to the terminal is duplicated there via `tee`).

---

## 2. Why GPG errors like this happen

GPG keeps its state — keys, trust database, agent socket, caches — in
`~/.gnupg`. Most "it just hangs" or "keyring is locked" problems trace back
to one of a handful of causes:

- **Stale lock files.** GPG creates `.lock` files while writing to the
  keyring so two processes can't corrupt it by writing at once. If a `gpg`
  process is killed (crash, `kill -9`, terminal closed mid-operation) it can
  leave the lock behind even though nothing is actually using it anymore.
  Every subsequent `gpg` invocation then waits on a lock that will never be
  released.

- **A hung or orphaned `gpg-agent`.** `gpg-agent` manages your unlocked
  private key material and talks to `pinentry` for passphrases. If the
  agent's socket goes stale (e.g. after a reboot, a suspended session, or an
  agent that crashed), `gpg` operations can hang indefinitely waiting for a
  response that will never come. Killing and relaunching the agent almost
  always clears this.

- **Wrong permissions on `~/.gnupg`.** GPG refuses to operate — often with a
  cryptic error rather than a clear one — if the directory or its files are
  group/world-readable. It expects `700` on the directory and `600` on the
  files inside it. This commonly happens after copying the directory with
  `cp -r` or restoring from a backup that didn't preserve permissions.

- **No secret key present.** Signing, decrypting, or self-testing an
  operation that needs a private key fails immediately if `gpg -K` shows
  nothing. This is a normal state for a freshly created account, not
  necessarily a corruption — the fix is simply to generate a key.

- **Missing `pinentry`, or a `pinentry` that can't reach a display/TTY.**
  If GPG needs to prompt for a passphrase and no pinentry program can
  actually present the prompt (e.g. running over a bare SSH session without
  `GPG_TTY` set, or in a script with no TTY at all), the operation hangs
  rather than failing cleanly. Batch key generation in this script avoids
  this specific case by using `%no-protection`, which skips setting a
  passphrase on the generated key.

- **Version-specific keyring format changes.** Modern GnuPG (2.1+) migrated
  from the old `secring.gpg` file to per-key files under
  `private-keys-v1.d/`. Tools or scripts written for GPG 1.x that expect
  `secring.gpg` will misbehave on newer installs — worth knowing if the
  repair steps here don't match what you see referenced elsewhere.

---

## 3. Program flow

### `repair` (default)

```
check_gpg                    → confirm gpg is installed, offer to install if not
[1]  gpg --version
[2]  list running gpg processes
[3]  confirm ~/.gnupg exists (create if missing)
[4]  find *.lock files
[5]  identify what (if anything) holds each lock, via lsof
[6]  kill gpg-agent
[7]  remove locks that are confirmed stale (no process holding them)
[8]  fix permissions: 700 on ~/.gnupg, 600 on files inside it
[9]  relaunch gpg-agent
[10] check_secret_key       → if none found, generate_gpg_key runs interactively
[11] gpg -K                  (secret key listing, sanity check)
[12] gpg --list-keys         (public key listing, sanity check)
```

Steps `[6]` and `[7]` are ordered deliberately: the agent is stopped
*before* locks are evaluated for removal, so a lock isn't mistaken for
"stale" just because the process holding it briefly disappears mid-check
and then a new agent immediately re-locks it.

### `backup`

```
check_gpg
create ~/gpg_backups/backup_<timestamp>/
  export public keys      → public_keys.asc
  export secret keys      → secret_keys.asc
  export owner trust      → owner_trust.txt
  copy revocation certs   → revocation_certs/*.rev
  copy config files       → config/{gpg.conf,gpg-agent.conf,dirmngr.conf}
chmod the staging dir go-rwx
tar.gz the staging dir     → ~/gpg_backups/gpg_backup_<timestamp>.tar.gz
prompt: encrypt with gpg --symmetric? (recommended — it holds private key material)
delete the staging directory, leaving only the archive
```

### `restore <file>`

```
check_gpg
if the file ends in .gpg → decrypt it into a temp dir first
extract the tar.gz into a temp dir
import public_keys.asc
import secret_keys.asc
import owner_trust.txt      (gpg --import-ownertrust)
copy revocation_certs/*.rev back into ~/.gnupg/openpgp-revocs.d/
copy config/* back into ~/.gnupg/
delete the temp dir
restart gpg-agent
```

---

## 4. Changed Feature from initial basic script 

- **All defined functions are now actually called.** `check_gpg` and
  `check_secret_key` existed before but were dead code — the main script
  duplicated `check_gpg`'s logic inline (without the install prompt) and
  never called `check_secret_key` at all, so `generate_gpg_key` could never
  run.
- **`set -euo pipefail` plus `errtrace`** turns silent failures into loud,
  immediate ones with a line number, instead of the script plowing on with
  a corrupted state.
- **`IFS=$'\n\t'`** — combined with the unquoted `for LOCK in $(find ...)`
  loops already in the script — means filenames containing spaces are
  handled correctly instead of being split into multiple words.
- **Colour-coded `info`/`success`/`warning`/`error`/`title` functions**
  replace plain `echo` for section headers and status lines, making it much
  easier to scan the log for what actually went wrong.
- **`%no-protection`** added to the batch key-generation heredoc — without
  it, GPG 2.1+ waits on a pinentry passphrase prompt that a non-interactive
  script can never answer.
- Backup/restore added as a self-contained feature so a keyring can be
  fully rebuilt on a new machine, not just repaired in place.

---

## 5. Further improvements being made , enhancements  (Busy with at present) 

- **Default the backup to encrypted**, rather than asking. A private key
  export sitting unencrypted on disk, even briefly, is the highest-risk
  artifact this script produces.
- **Checksum the archive.** Write a `sha256sum` alongside the backup archive
  so you can verify it wasn't corrupted or tampered with before restoring
  from it, especially if it's copied to removable media or cloud storage.
- **Recommend offline/removable storage for the backup** in the script's
  own output — a backup that contains your secret key shouldn't live only
  on the same disk as the original.
- **Proper flag parsing (`getopts`) for `repair`**, e.g. `--dry-run` (show
  what would be removed/changed without doing it) and `--quiet` (suppress
  colour and non-essential output for cron/CI use).
- **A non-interactive mode for `generate_gpg_key`** that accepts
  `--name`/`--email` as flags instead of always prompting, so `repair` can
  be run unattended when that's desired.
- **Per-key export option** in `backup` (`--key <id>`) for exporting a
  single identity rather than the whole keyring, useful if you manage
  multiple keys and only want to move one.
- **Restore into an isolated `GNUPGHOME`** as an option, so a backup can be
  test-restored and verified without touching the live keyring.
- **Log rotation** — the script currently creates a new log file on every
  run with no cleanup; on a machine where this runs frequently (e.g. via
  cron) that directory will grow indefinitely.
- **Version check** — `gpg --version` output could be parsed to warn if
  running against GPG 1.x, since the lock-file layout and secret key
  storage format differ meaningfully from 2.1+.
