#!/bin/bash

# --- Usage ---
# Run this script with the JSON file path, curl_connect_timeout, and arg_value as arguments.
# Example: ./scan_and_curl_parallel.sh /path/to/your/network_data.json 5 QmY...XYZ
#          $0                               $1                             $2 $3

# --- Configuration ---
# Define the TCP port to scan
TARGET_PORT="5001"

# Define the nc scan timeout in seconds (for initial port check)
NC_SCAN_TIMEOUT="1"

# Define the maximum number of concurrent curl commands to run
MAX_CONCURRENT_CURLS=10 # <--- Adjust this value based on your system's resources and network

# --- Script Logic ---

# Check if all required arguments are provided
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
  echo "Error: Missing arguments."
  echo "Usage: $0 <json_file_path> <curl_connect_timeout_seconds> <arg_value>"
  echo "Example: $0 ./network_nodes.json 5 QmY...XYZ"
  exit 1
fi

# Get arguments
JSON_FILE="$1"
CURL_CONNECT_TIMEOUT="$2" # Curl connection timeout from argument 2
CURL_ARG_VALUE="$3"       # Arg value for curl from argument 3

# Check if the JSON file exists and is readable
if [ ! -f "$JSON_FILE" ]; then
  echo "Error: File '$JSON_FILE' does not exist or is not a regular file."
  echo "Please check the file path."
  exit 1
elif [ ! -r "$JSON_FILE" ]; then
  echo "Error: File '$JSON_FILE' is not readable."
  echo "Please check file permissions."
  exit 1
fi

echo "--- Starting to extract unique IP addresses from '$JSON_FILE' ---"
echo "--- Scanning TCP port $TARGET_PORT ---"
echo "--- Executing 'curl' command with a maximum of $MAX_CONCURRENT_CURLS concurrent processes if reachable ---"

echo "Scan Results & Curl Command Output:"
echo "-----------------------------------------------------"

# Function to run the curl command in the background
# Takes HOST_TO_SCAN, CURL_TARGET_IP, TARGET_PORT, CURL_CONNECT_TIMEOUT, CURL_ARG_VALUE as arguments
execute_curl_parallel() {
  local ip_address="$1"
  local host_to_scan="$2" # This is currently not used in curl, but keep for consistency
  local curl_target_ip="$3" # This is the formatted IP for curl
  local target_port="$4"
  local curl_connect_timeout="$5"
  local curl_arg_value="$6"

  CURL_URL="http://${curl_target_ip}:${target_port}/api/v0/pin/add?arg=${curl_arg_value}&progress=false"

  echo "  [+] $ip_address:$target_port - Reachable. Executing curl command in background..."
  echo "      Command: curl -s --connect-timeout $curl_connect_timeout -X POST \"$CURL_URL\""
  
  # Execute curl in the background, redirecting its output to a temporary file
  # The output includes both stdout and stderr of curl, prefixed for clarity
  (
    echo "--- Curl output for $ip_address:$target_port ---"
    curl -s --connect-timeout "$curl_connect_timeout" -X POST "$CURL_URL"
    CURL_EXIT_CODE=$?
    if [ $CURL_EXIT_CODE -eq 0 ]; then
        echo "Curl command for $ip_address completed successfully (Exit Code: $CURL_EXIT_CODE)."
    else
        echo "Curl command for $ip_address failed (Exit Code: $CURL_EXIT_CODE)."
        # If you want full verbose output on failure, remove -s from the curl command above.
    fi
    echo "-------------------------------------"
  ) & # Run in background
}

# Counter for currently running curl processes
running_curls=0

# Extract multiaddrs, identify IP versions, format them,
# then sort them and remove duplicates before scanning
jq -r '
  .found_nodes[] |
  .multiaddrs[] |
  select(
    startswith("/ip4/") or
    startswith("/ip6/")
  ) |
  (
    if startswith("/ip4/") then
      split("/")[2]
    elif startswith("/ip6/") then
      "[" + split("/")[2] + "]"
    else
      empty
    end
  )
' < "$JSON_FILE" | sort -u | while read -r IP_ADDRESS; do # Process each unique IP

  # Prepare IP addresses for nc and curl
  if [[ "$IP_ADDRESS" == \[*\] ]]; then
    HOST_TO_SCAN="${IP_ADDRESS//[\[\]]/}"
    CURL_TARGET_IP="$IP_ADDRESS"
    IS_IPV6=true
  else
    HOST_TO_SCAN="$IP_ADDRESS"
    CURL_TARGET_IP="$IP_ADDRESS"
    IS_IPV6=false
  fi

  # --- Perform Port Scan with nc ---
  if $IS_IPV6; then
    nc -z -w "$NC_SCAN_TIMEOUT" -v -n -6 "$HOST_TO_SCAN" "$TARGET_PORT" 2>&1 | grep "succeeded!" &>/dev/null
  else
    nc -z -w "$NC_SCAN_TIMEOUT" -v -n -4 "$HOST_TO_SCAN" "$TARGET_PORT" 2>&1 | grep "succeeded!" &>/dev/null
  fi

  # Check nc's exit status code
  if [ $? -eq 0 ]; then
    # If a slot is available, start a new curl process
    if (( running_curls < MAX_CONCURRENT_CURLS )); then
      execute_curl_parallel "$IP_ADDRESS" "$HOST_TO_SCAN" "$CURL_TARGET_IP" "$TARGET_PORT" "$CURL_CONNECT_TIMEOUT" "$CURL_ARG_VALUE"
      ((running_curls++))
    else
      # If max concurrent curls reached, wait for any background process to finish
      wait -n # Wait for the next background job to complete (Bash 4.3+)
      execute_curl_parallel "$IP_ADDRESS" "$HOST_TO_SCAN" "$CURL_TARGET_IP" "$TARGET_PORT" "$CURL_CONNECT_TIMEOUT" "$CURL_ARG_VALUE"
      # No need to decrement running_curls here; wait -n effectively frees a slot
    fi
  fi
done

# Wait for all remaining background curl processes to finish
echo "-----------------------------------------------------"
echo "All IP addresses processed. Waiting for remaining background curl commands to finish..."
wait # Wait for all remaining background jobs to complete

echo "--- All processes complete ---"
