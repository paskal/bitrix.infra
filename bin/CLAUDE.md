# Shell Scripts Style Guide

## Path Handling
- ALWAYS use relative paths via `SCRIPT_DIR`, never absolute paths like `/web/...`
- Define at script start: `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"`
- Reference files relative to SCRIPT_DIR: `$SCRIPT_DIR/../private/environment/mysql.env`
- Temporary files in `/tmp/` are acceptable

## Script Structure
```sh
#!/bin/sh
# Script description
#
# Usage:
#   script-name command  - Description
#
# Config: $SCRIPT_DIR/.config-file

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colours (consistent across scripts)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
CONFIG_FILE="$SCRIPT_DIR/.script-config"

# Functions...

# Main
case "${1:-}" in
command)
    cmd_command
    ;;
*)
    # Usage help
    ;;
esac
```

## POSIX Compatibility
- Use `#!/bin/sh` for cron compatibility
- Avoid bash-specific features (arrays, `[[`, etc.)
- Use `$(...)` not backticks
- Quote all variables: `"$var"` not `$var`

## Error Handling
- Use `set -eu` (exit on error, undefined variables)
- Validate numeric values before SQL use
- Check file existence before sourcing

## Docker/MySQL Access
- Source credentials from environment files
- Use `docker exec` with container name filter
- Never hardcode passwords
