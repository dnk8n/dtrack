#!/usr/bin/env bash

# Install CyanAudit
# Run by dtrack-ops init with PGHOST pointing at the database server.
/opt/cyanaudit/install.pl -h "${PGHOST:-localhost}" "$@"

# Install more efficient C based audit event logger - Not working :(
# psql -h localhost $@ -f /opt/cyanaudit/tools/install_c_fn_log_audit_event.sql
