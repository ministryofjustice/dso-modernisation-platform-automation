#!/usr/bin/env bash
#
# get_oracle_workflow_options_list.sh (defensive, commented version)
#
# Purpose:
#   Scan Ansible group_vars YAML files and produce an alphabetically sorted,
#   nicely aligned list of "target databases" suitable for a workflow picker.
#
# Behavioural rules (preserved from the original):
#   - Input 1: a file with one application name per line (e.g., hmpps_oem, delius-core, delius-mis).
#              Hyphens are converted to underscores when matching filenames.
#   - Input 2: path to the Ansible group_vars directory containing files named like:
#                environment_name_<app>_*.yml
#
#   - Delius apps (delius-core, delius-mis):
#       * Consider ONLY files that end with "_primarydb.yml".
#       * Output ONLY the environment/host (no DB name) because there's one DB per host.
#
#   - Other apps:
#       * For each YAML file, read keys from .db_configs via yq.
#       * Exclude databases whose name starts with "DR" (standbys).
#       * Only include RCVCAT when the filename contains "hmpps_oem".
#       * Output "<environment> <database>" pairs.
#
#   - Output surrounded by "CUT HERE" banners, sorted and aligned in columns.
#
# Requirements:
#   - bash 4+  (arrays, [[ .. ]])
#   - yq v4 (mikefarah) for YAML querying
#   - standard tools: sort, awk, sed, find, basename
#
# Exit codes:
#   0  success
#   1  usage or validation errors (missing args, paths)
#   2  dependency errors (yq missing or incompatible)
#   3  unexpected runtime failure (trapped ERR)
#

set -Euo pipefail
shopt -s nullglob # Globs that don't match expand to nothing rather than themselves

trap 'echo "ERROR: Script failed on line $LINENO" >&2; exit 3' ERR

###############################################################################
# Helpers
###############################################################################
usage() {
  cat >&2 <<'USAGE'
Usage:
  get_oracle_workflow_options_list.sh <DBA_APPLICATIONS_LIST> <GROUP_VARS_DIRECTORY>

Where:
  <DBA_APPLICATIONS_LIST>  Text file: one application name per line (e.g., hmpps_oem, delius-core).
  <GROUP_VARS_DIRECTORY>   Directory containing environment_name_<app>_*.yml files.

Notes:
  - Hyphens in app names are converted to underscores for filename matching.
  - Requires yq v4 (mikefarah) to query YAML.
USAGE
}

require_yq_v4() {
  if ! command -v yq >/dev/null 2>&1; then
    echo "ERROR: 'yq' is not installed or not in PATH. Please install mikefarah/yq v4." >&2
    exit 2
  fi
  local v
  v="$(yq --version 2>/dev/null || true)"
  # Expected form: "yq (https://github.com/mikefarah/yq/) version 4.x.x"
  if [[ "$v" != *"version 4."* ]]; then
    echo "ERROR: Detected '$v'. This script requires mikefarah/yq version 4.x." >&2
    exit 2
  fi
}

strip_prefix() {
  # Strip leading "environment_name_" from a filename (no path)
  local name="$1"
  printf '%s' "${name#environment_name_}"
}

strip_suffix_yml() {
  # Strip trailing ".yml"
  local name="$1"
  printf '%s' "${name%.yml}"
}

###############################################################################
# Validate input
###############################################################################
if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

DBA_APPLICATIONS_LIST="$1"
GROUP_VARS_DIRECTORY="$2"

if [[ ! -f "$DBA_APPLICATIONS_LIST" ]]; then
  echo "ERROR: Applications list not found: $DBA_APPLICATIONS_LIST" >&2
  exit 1
fi
if [[ ! -d "$GROUP_VARS_DIRECTORY" ]]; then
  echo "ERROR: Ansible group_vars directory not found: $GROUP_VARS_DIRECTORY" >&2
  exit 1
fi

require_yq_v4

###############################################################################
# Read applications; normalize names for filename matching
###############################################################################
declare -a APPS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  # Skip blank lines and comments
  [[ -z "${line// }" ]] && continue
  [[ "$line" =~ ^[[:space:]]*# ]] && continue

  # Convert hyphens to underscores for filename matching
  app_normalized="${line//-/_}"
  APPS+=("$app_normalized")
done < "$DBA_APPLICATIONS_LIST"

if [[ ${#APPS[@]} -eq 0 ]]; then
  echo "WARNING: No application names found in $DBA_APPLICATIONS_LIST. Output will be empty." >&2
fi
###############################################################################
# Discover candidate group_vars files for each app
###############################################################################
declare -a GROUP_VARS_FILES=()
for app in "${APPS[@]}"; do
  # Match: environment_name_<app>_*.yml inside GROUP_VARS_DIRECTORY
  # Use a glob rather than running external 'find' for speed and simplicity.
  for fpath in "$GROUP_VARS_DIRECTORY"/environment_name_"$app"_*.yml; do
    # 'nullglob' makes this loop skip if nothing matches
    [[ -e "$fpath" ]] || continue
    GROUP_VARS_FILES+=("$(basename "$fpath")")
  done
done

# Deduplicate file list while keeping order
declare -A SEEN=()
declare -a UNIQUE_FILES=()
for fname in "${GROUP_VARS_FILES[@]}"; do
  if [[ -z "${SEEN[$fname]:-}" ]]; then
    SEEN["$fname"]=1
    UNIQUE_FILES+=("$fname")
  fi
done
GROUP_VARS_FILES=("${UNIQUE_FILES[@]}")

###############################################################################
# Build TARGET_DATABASES list according to the business rules
###############################################################################
declare -a TARGET_DATABASES=()

for GROUP_VARS_FILE in "${GROUP_VARS_FILES[@]}"; do
  # Full path for yq reads
  FULL_PATH="$GROUP_VARS_DIRECTORY/$GROUP_VARS_FILE"

  # Delius special-case: filenames containing "delius"
  if [[ "$GROUP_VARS_FILE" == *"delius"* ]]; then
    # Only consider primary DB definition files
    if [[ "$GROUP_VARS_FILE" == *"_primarydb.yml" ]]; then
      # Extract environment/host (strip prefix and suffix)
      base_no_suffix="${GROUP_VARS_FILE%_primarydb.yml}"     # remove trailing _primarydb.yml
      env_only="$(strip_prefix "$base_no_suffix")"            # remove environment_name_
      TARGET_DATABASES+=("$env_only")
    fi
    continue
  fi

  # Non-Delius: read DB names from .db_configs
  # yq v4 expression:
  #   .db_configs? | select(. != null) | keys | .[]
  mapfile -t DATABASES < <(yq -r '.db_configs? | select(. != null) | keys | .[]' "$FULL_PATH" 2>/dev/null || true)

  # If no .db_configs or no keys, skip (silently)
  [[ ${#DATABASES[@]} -eq 0 ]] && continue

  # Environment name is everything after environment_name_ and before .yml
  env_name="$(strip_suffix_yml "$(strip_prefix "$GROUP_VARS_FILE")")"

  for db in "${DATABASES[@]}"; do
    # RCVCAT is only real in hmpps_oem environments
    if [[ "$db" == "RCVCAT" ]]; then
      if [[ "$GROUP_VARS_FILE" == *"hmpps_oem"* ]]; then
        TARGET_DATABASES+=("$env_name $db")
      fi
      continue
    fi

    # Exclude standby DBs: names starting with "DR"
    if [[ "$db" == DR* ]]; then
      continue
    fi

    TARGET_DATABASES+=("$env_name $db")
  done
done

###############################################################################
# Formatting: compute max length and print sorted, aligned list with banners
###############################################################################
# Compute max display width (length of "env[ space db ]")
MAX_LENGTH=0
for s in "${TARGET_DATABASES[@]:-}"; do
  # shellcheck disable=SC3045
  (( ${#s} > MAX_LENGTH )) && MAX_LENGTH=${#s}
done

HEADER=">>>>>>>>CUT HERE FOR TARGET DATABASE LIST>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
FOOTER="<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"

echo "$HEADER"

# Print all target databases in alphabetical order, aligned so DB names line up.
# Matching the original approach: pad width = 2 + MAX - length($1 $2)
# (awk concatenates $1$2 without a space; the +2 compensates visually).
if [[ ${#TARGET_DATABASES[@]:-} -gt 0 ]]; then
  printf '%s\n' "${TARGET_DATABASES[@]}" \
  | LC_ALL=C sort \
  | awk -v MAX="$MAX_LENGTH" '{
       L = length($1 $2);
       PAD = 2 + MAX - L;
       if (NF == 1) {
         # Delius lines: only environment/host
         printf("%s\n", $1);
       } else {
         # Two columns: env and DB
         printf("%s%*s%s\n", $1, PAD, "", $2);
       }
     }'
fi

echo "$FOOTER"
