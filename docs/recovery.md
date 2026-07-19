# Recovery Scenarios

# MD Harrington BexleyHeath Kent UK 

Practical walkthroughs for the situations this toolkit is meant to solve.

## "GPG hangs / says the keyring is locked"

```bash
./gpg_keyring_repair.sh repair
```

Read the log section by section:
- **[4]/[5]** tell you whether a lock file exists and whether any live
  process actually owns it.
- **[7]** only removes a lock once step 6 has stopped `gpg-agent` and the
  lock is confirmed to have no owner — an active lock is always left alone
  and reported, never force-removed.

If step **[5]** shows a real process (not just gpg-agent) holding the lock,
that process is actively using the keyring — let it finish rather than
removing the lock underneath it.

## "I'm moving to a new machine and want my GPG identity to come with me"

On the old machine:

```bash
./gpg_keyring_repair.sh backup
```

Say **yes** to the encryption prompt — the archive contains your secret
key material. Move `backups/gpg_backup_<timestamp>.tar.gz.gpg` to the new
machine (USB drive, not email).

On the new machine:

```bash
./gpg_keyring_repair.sh restore /path/to/gpg_backup_<timestamp>.tar.gz.gpg
```

You'll be asked to decrypt (passphrase from the backup step), then asked to
confirm before secret keys are imported into `~/.gnupg`. Check `gpg -K`
afterwards to confirm the key is present.

## "I think my `~/.gnupg` is corrupted and I want to start clean, but keep my key"

1. Back up first, even if things look broken — export can succeed even when
   agent/lock state is unhealthy:
   ```bash
   ./gpg_keyring_repair.sh backup
   ```
2. Move the existing directory aside rather than deleting it outright:
   ```bash
   mv ~/.gnupg ~/.gnupg.broken
   ```
3. Restore from the fresh backup into the newly recreated directory:
   ```bash
   ./gpg_keyring_repair.sh restore backups/gpg_backup_<timestamp>.tar.gz.gpg
   ```
4. Once you've confirmed `gpg -K` and `gpg --list-keys` look right, delete
   `~/.gnupg.broken`.

## "I never generated a key and now something needs one"

Just run the repair flow — step **[10]** detects the missing secret key and
walks you through `generate_gpg_key` interactively (name, email; the key is
generated without a passphrase via `%no-protection` so batch generation
doesn't hang waiting on a pinentry prompt).

## Reading MANIFEST.txt

Every backup archive contains a `MANIFEST.txt` recording the date, user,
hostname, GPG version, and full file list at backup time. If you're not
sure which of several backups in `backups/` corresponds to which machine or
date, extract just that file to check before doing a full restore:

```bash
tar -xzOf backups/gpg_backup_<timestamp>.tar.gz backup_<timestamp>/MANIFEST.txt
```

(For an encrypted `.tar.gz.gpg` archive, decrypt it first with
`gpg --decrypt`, then run the command above against the resulting
`.tar.gz`.)
