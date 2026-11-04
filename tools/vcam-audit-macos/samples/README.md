# Audit samples (macOS)

Sanitized `audit-virtualcam.sh` output from a real Mac goes here, committed as
`scan-<hostname/context>.json` with identifiers (serials, UUIDs, host names)
redacted.

None is committed yet: every build so far ran on CI runners without a camera
and the audit has not been executed on a real Mac. To produce one:

    sudo ./audit-virtualcam.sh --output samples/scan-mac.json

then redact unique IDs and commit.
