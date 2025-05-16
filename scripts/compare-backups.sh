#!/usr/bin/env bash
set -e -u

# Compare two backups from S3 storage
# This script allows user to choose two backups from a list,
# restore them to separate directories, and create a diff between them

# Configuration
BACKUP_DIR="./backup/restore"
DEST="boto3+s3://favor-group-backup/duplicity_web_$(hostname)"
S3_ENDPOINT="https://storage.yandexcloud.net"
HOME_DIR="/home/admin"  # Duplicity needs HOME to read AWS credentials
LOGFILE="/web/logs/compare-backups.log"
CACHE_DIR="/web/backup/.duplicity-cache"  # Match location in file-backup.sh
DIFF_FILE="${BACKUP_DIR}/backup_diff.txt"

# Create restore directory if it doesn't exist
mkdir -p "${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}/older"
mkdir -p "${BACKUP_DIR}/newer"
mkdir -p "${CACHE_DIR}"

# Function to list available backups
list_backups() {
  echo "Listing available backups..."
  
  # Use duplicity to list all available backups
  HOME="${HOME_DIR}" duplicity \
    collection-status \
    --no-encryption \
    --s3-endpoint-url "${S3_ENDPOINT}" \
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
    echo "No backups found. Exiting."
    exit 1
  fi
  
  # Display backups and let user choose
  echo "${prompt}"
  echo "Available backups:"
  
  # Convert to array for selection
  IFS=$'\n' read -rd '' -a backup_array <<< "${available_backups}"
  
  # Display menu
  for i in "${!backup_array[@]}"; do
    echo "$((i+1))) ${backup_array[$i]}"
  done
  
  # Get user selection
  local selection
  read -rp "Select backup number: " selection
  
  # Validate selection
  if ! [[ "${selection}" =~ ^[0-9]+$ ]] || [ "${selection}" -lt 1 ] || [ "${selection}" -gt "${#backup_array[@]}" ]; then
    echo "Invalid selection. Please try again."
    exit 1
  fi
  
  # Return the selected backup time string (extract date part)
  echo "${backup_array[$((selection-1))]}" | grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
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
    --s3-endpoint-url "${S3_ENDPOINT}" \
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
  diff -rua "${older_dir}" "${newer_dir}" > "${diff_file}" 2>/dev/null || true
  
  # Count number of differences
  local diff_count
  diff_count=$(grep -E "^(\+\+\+|---)" "${diff_file}" | wc -l)
  
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
