#!/usr/bin/env bash
# Compare two backups from S3 storage.
# Configuration is read from private/environment/backup.env.
# Required variables: BACKUP_S3_BUCKET, S3_ENDPOINT_URL
set -e -u

BACKUP_ENV="./private/environment/backup.env"
if [ ! -f "${BACKUP_ENV}" ]; then
  echo "ERROR: ${BACKUP_ENV} is missing. Copy backup.env.example and fill in values." >&2
  exit 1
fi
# shellcheck disable=SC1090
. "${BACKUP_ENV}"
: "${BACKUP_S3_BUCKET:?BACKUP_S3_BUCKET must be set in ${BACKUP_ENV}}"
: "${S3_ENDPOINT_URL:?S3_ENDPOINT_URL must be set in ${BACKUP_ENV}}"

# Configuration
BACKUP_DIR="./backup/restore"
DEST="boto3+s3://${BACKUP_S3_BUCKET}/duplicity_web_$(hostname)"
HOME_DIR="/home/admin" # Duplicity needs HOME to read AWS credentials
LOGFILE="/web/logs/compare-backups.log"
CACHE_DIR="/web/backup/.duplicity-cache" # Match location in file-backup.sh
DIFF_FILE="${BACKUP_DIR}/backup_diff.txt"

# Create restore directory if it doesn't exist
mkdir -p "${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}/older"
mkdir -p "${BACKUP_DIR}/newer"
mkdir -p "${CACHE_DIR}"

# Function to list available backups
list_backups() {
  # stderr: this function's stdout is captured by select_backup via $(...),
  # so only the backup list itself may go to stdout.
  echo "Listing available backups..." >&2

  # Use duplicity to list all available backups
  HOME="${HOME_DIR}" duplicity \
    collection-status \
    --no-encryption \
    --s3-endpoint-url "${S3_ENDPOINT_URL}" \
    --log-file "${LOGFILE}" \
    --archive-dir "${CACHE_DIR}" \
    "${DEST}" | grep -E "^Full|^Incremental" | sort -r
}

# Function to let user select a backup
select_backup() {
  local prompt="$1"
  local available_backups

  # Get the list of backups
  available_backups=$(list_backups)

  # Check if we have any backups
  if [ -z "${available_backups}" ]; then
    echo "No backups found. Exiting." >&2
    exit 1
  fi

  # Everything the user sees goes to stderr; only the chosen timestamp is
  # printed to stdout, because the whole function is captured via $(...).
  echo "${prompt}" >&2
  echo "Available backups:" >&2

  # Convert to array for selection. A while-read loop is portable (mapfile is
  # bash 4+, absent on macOS bash 3.2) and set -e-safe (the old `read -d ''`
  # returned 1 at EOF and aborted the whole script under set -e).
  local backup_array=() line
  while IFS= read -r line; do
    backup_array+=("$line")
  done <<<"${available_backups}"

  # Display menu
  local i
  for i in "${!backup_array[@]}"; do
    echo "$((i + 1))) ${backup_array[$i]}" >&2
  done

  # Get user selection (read -rp writes the prompt to stderr)
  local selection
  read -rp "Select backup number: " selection

  # Validate selection
  if ! [[ "${selection}" =~ ^[0-9]+$ ]] || [ "${selection}" -lt 1 ] || [ "${selection}" -gt "${#backup_array[@]}" ]; then
    echo "Invalid selection. Please try again." >&2
    exit 1
  fi

  # Return the selected backup time string (extract date part)
  echo "${backup_array[$((selection - 1))]}" | grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
}

# Function to restore backup to a specific directory
restore_backup() {
  local backup_time="$1"
  local restore_dir="$2"

  echo "Restoring backup from ${backup_time} to ${restore_dir}..."

  # Clear the target directory first
  rm -rf "${restore_dir:?}/"*

  # Restore the backup as of the specified time
  HOME="${HOME_DIR}" duplicity \
    restore \
    --no-encryption \
    --time "${backup_time}" \
    --s3-endpoint-url "${S3_ENDPOINT_URL}" \
    --log-file "${LOGFILE}" \
    --archive-dir "${CACHE_DIR}" \
    --force \
    "${DEST}" "${restore_dir}"

  echo "Restore to ${restore_dir} completed."
}

# Function to compare two directories and create a diff
compare_backups() {
  local older_dir="$1"
  local newer_dir="$2"
  local diff_file="$3"

  echo "Comparing backups..."

  # Use diff to create a comparison between the two directories
  diff -rua "${older_dir}" "${newer_dir}" >"${diff_file}" 2>/dev/null || true

  # Count number of differences
  local diff_count
  diff_count=$(grep -cE "^(\+\+\+|---)" "${diff_file}" || true)

  echo "Comparison completed. Found approximately $((diff_count / 2)) differences."
  echo "Diff file created at: ${diff_file}"
}

# Main script

echo "=== Backup Comparison Tool ==="
echo "This tool will help you compare two backups from S3 storage."

# Select older backup
older_backup=$(select_backup "First, select the OLDER backup:")

# Select newer backup
newer_backup=$(select_backup "Now, select the NEWER backup:")

# Make sure newer backup is actually newer
if [[ "${older_backup}" > "${newer_backup}" ]]; then
  echo "The first backup selected is newer than the second one. Swapping..."
  temp_backup="${older_backup}"
  older_backup="${newer_backup}"
  newer_backup="${temp_backup}"
fi

# Restore backups
restore_backup "${older_backup}" "${BACKUP_DIR}/older"
restore_backup "${newer_backup}" "${BACKUP_DIR}/newer"

# Compare the restored backups
compare_backups "${BACKUP_DIR}/older" "${BACKUP_DIR}/newer" "${DIFF_FILE}"

echo ""
echo "=== Summary ==="
echo "Older backup: ${older_backup}"
echo "Newer backup: ${newer_backup}"
echo "Comparison complete!"
echo "To view the differences, check the diff file at:"
echo "${DIFF_FILE}"
echo ""
echo "You can also explore the restored files in:"
echo "Older backup: ${BACKUP_DIR}/older"
echo "Newer backup: ${BACKUP_DIR}/newer"
