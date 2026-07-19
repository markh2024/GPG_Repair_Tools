# Program Flow

## `repair` (default)

```
gpg_keyring_repair.sh [repair]
        |
        v
  check_gpg  ──(not installed)──> prompt to install ──(no)──> exit 1
        |
        v
[1] gpg --version
        |
[2] list running gpg processes
        |
[3] confirm ~/.gnupg exists ──(missing)──> create it
        |
[4] find *.lock files
        |
[5] lsof each lock to see what (if anything) holds it
        |
[6] gpgconf --kill gpg-agent
        |
[7] remove locks confirmed stale (not held by any process)
        |
[8] chmod 700 ~/.gnupg ; chmod 600 files inside it
        |
[9] gpgconf --launch gpg-agent
        |
[10] check_secret_key ──(none found)──> generate_gpg_key (interactive)
        |
[11] gpg -K   (secret key sanity check)
        |
[12] gpg --list-keys   (public key sanity check)
        |
        v
   Repair completed
```

## `backup`

```
gpg_keyring_repair.sh backup
        |
        v
  check_gpg
        |
  mkdir backups/backup_<timestamp>/
        |
  export public keys      -> public_keys.asc
        |
  export secret keys      -> secret_keys.asc
        |
  export owner trust      -> owner_trust.txt
        |
  copy revocation certs   -> revocation_certs/*.rev
        |
  copy config files       -> config/*
        |
  write MANIFEST.txt (date, user, host, gpg version, file list)
        |
  chmod go-rwx on the staging dir
        |
  tar -czf  ->  backups/gpg_backup_<timestamp>.tar.gz
        |
  prompt: encrypt with gpg --symmetric? ──(yes)──> AES256-encrypted .tar.gz.gpg
        |                                          (unencrypted archive deleted)
       (no)
        |
  delete staging dir, keep only the archive
        |
        v
   Backup complete
```

## `restore <file>`

```
gpg_keyring_repair.sh restore <file>
        |
        v
  check_gpg
        |
  file missing / no path given? ──> error, exit
        |
  ends in .gpg? ──(yes)──> gpg --decrypt into temp dir
        |
  tar -xzf into temp dir
        |
  backup_* directory found inside? ──(no)──> error, exit
        |
  import public_keys.asc
        |
  secret_keys.asc present?
        |
       (yes) -> WARNING + "Continue? (yes/no)" confirmation
        |             |
        |          (no) -> cancel, clean up temp dir, exit 0
        |             |
        |           (yes)
        |             |
        v             v
  import secret_keys.asc
        |
  gpg --import-ownertrust owner_trust.txt
        |
  copy revocation_certs/*.rev -> ~/.gnupg/openpgp-revocs.d/
        |
  copy config/* -> ~/.gnupg/
        |
  delete temp dir
        |
  restart gpg-agent
        |
        v
   Restore complete
```
