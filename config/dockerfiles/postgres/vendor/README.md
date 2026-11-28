# Vendored third-party source

## Cyan Audit

`cyanaudit-2.2.3-806f6c5.zip` is an unmodified copy of the upstream source
archive, kept here so image builds do not depend on upstream staying online or
unchanged.

| | |
| --- | --- |
| Upstream | https://bitbucket.org/neadwerx/cyanaudit |
| Version | 2.2.3 (`default_version` in `cyanaudit.control`) |
| Commit | `806f6c5095c5ec309c285f83fa33f0d795ae5781` (master, 2026-11-16) |
| Fetched | 2026-11-28 from `https://bitbucket.org/neadwerx/cyanaudit/get/806f6c5095c5ec309c285f83fa33f0d795ae5781.zip` (byte-identical to `get/master.zip` on that date) |
| SHA-256 | see `cyanaudit-2.2.3-806f6c5.zip.sha256` |
| License | PostgreSQL License, Copyright (c) 2013 Nead Werx, Inc. See `LICENSE.cyanaudit` (also inside the archive). |

The license allows use, copying, modification and distribution, including in
the published container image, as long as the copyright notice and license
text stay with the copies. The archive and the image's `/opt/cyanaudit` both
include `LICENSE`.

The Dockerfile copies the archive into the build stage, verifies it with
`sha256sum -c`, and fails the build on a mismatch.

### Upgrading

1. Download the new commit: `https://bitbucket.org/neadwerx/cyanaudit/get/<commit>.zip`.
2. Read its `LICENSE` and `doc/CHANGELOG.md`; check the license has not changed.
3. Save it as `cyanaudit-<version>-<short commit>.zip`, where `<version>` is
   `default_version` from its `cyanaudit.control`, and write the matching
   `.sha256` file (`sha256sum <file> > <file>.sha256`).
4. Update `CYANAUDIT` in the Dockerfile, update this table, delete the old
   archive, and let CI run the database tests against it.
