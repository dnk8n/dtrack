#!/usr/bin/env bash

# Install CyanAudit
/opt/cyanaudit/install.pl -h localhost "$@"

# Install more efficient C based audit event logger - Not working :(
# psql -h localhost $@ -f /opt/cyanaudit/tools/install_c_fn_log_audit_event.sql
