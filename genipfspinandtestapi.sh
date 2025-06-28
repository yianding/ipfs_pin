#!/bin/bash

# --- Usage ---
# Run this script with the JSON file path as the ONLY argument.
# The curl_connect_timeout and arg_value will be passed *when ipfspin.sh is executed*.
# Example: ./generate_dynamic_curls.sh /path/to/your/network_data.json
#          $0                               $1

# --- Configuration ---
# Define the output file for curl commands
OUTPUT_FILE="ipfspin.sh"
# Define the target port for IPFS API
TARGET_PORT="5001" 
# Define a timeout for the initial port connectivity test (in seconds)
CONNECT_TEST_TIMEOUT=2 
# Define a timeout for the actual 'pin add' test curl command (in seconds)
CURL_TEST_TIMEOUT=5 

# Define the default CID for testing the pin add API.
TEST_CID="Qma1Av2N8ZT5o7eNrKjoKLQweWnHJtWSzCPYKN5Nn4ZLrK" 

# --- New Configuration for Concurrency ---
# Maximum number of concurrent tests to run simultaneously
# Adjust this based on your system's resources and network conditions.
# Too high can lead to resource exhaustion or false negatives due to too many open connections.
MAX_CONCURRENT_TESTS=1000

# --- Script Logic ---

# Check if the JSON file path is provided
if [ -z "$1" ]; then
  echo "Error: Please provide the JSON file path as an argument."
  echo "Usage: $0 <json_file_path>"
  echo "Example: $0 ./network_nodes.json"
  exit 1
fi

# Get argument
JSON_FILE="$1"

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

# Clear or create the output file and add a shebang for easy execution
echo "#!/bin/bash" > "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE" # Add a newline for readability

echo "--- Starting to extract unique IP addresses from '$JSON_FILE' ---"
echo "--- Testing connectivity and API response (concurrently), then generating 'curl' commands to '$OUTPUT_FILE' ---"
echo "    (Commands in '$OUTPUT_FILE' will use \$1 for their timeout and \$2 for arg_value)"
echo "    (Connectivity test timeout: ${CONNECT_TEST_TIMEOUT}s, API response test timeout: ${CURL_TEST_TIMEOUT}s)"
echo "    (Using TEST_CID: ${TEST_CID})"
echo "    (Max concurrent tests: ${MAX_CONCURRENT_TESTS})"

echo "Command Generation Log (may appear out of order due to concurrency):"
echo "-----------------------------------------------------"

# Define a temporary file to store results from concurrent tests
TEMP_RESULTS_FILE=$(mktemp)

# Function to perform the connectivity and API test for a single IP
# This function will be run in the background for each IP
perform_test() {
  local ip_address="$1"
  local target_port="$2"
  local connect_test_timeout="$3"
  local curl_test_timeout="$4"
  local test_cid="$5"
  local generated_command=""

  #echo "  [Test] Starting test for ${ip_address}:${target_port}..."

  # Step 1: Port Connectivity Test using nc
  if nc -z -w "${connect_test_timeout}" "${ip_address}" "${target_port}" &> /dev/null; then
    #echo "    [Test] ✅ Port ${target_port} open for ${ip_address}. Proceeding to API test."

    # Step 2: API Response Test using curl
    TEST_URL="http://${ip_address}:${target_port}/api/v0/pin/add?arg=${test_cid}&progress=false"
    
    API_RESPONSE=$(curl --connect-timeout "${curl_test_timeout}" -X POST "${TEST_URL}" 2>/dev/null)
    CURL_EXIT_CODE=$?

    if [ "$CURL_EXIT_CODE" -eq 0 ]; then
      if echo "$API_RESPONSE" | grep -iqE 'error|failed|fault|invalid|already pinned'; then
        echo "    [Test] ❌ API response indicates error/existing pin for ${ip_address}. Skipping."
      else
        echo "    [Test] ✅ API response seems OK for ${ip_address}. Generating command."
        # If tests pass, print the generated command to TEMP_RESULTS_FILE
        GENERATED_COMMAND="curl --connect-timeout \$1 -X POST \"http://${ip_address}:${target_port}/api/v0/pin/add?arg=\$2&progress=false\" &"
        echo "$GENERATED_COMMAND" >> "$TEMP_RESULTS_FILE"
      fi
    else
      #echo "    [Test] ❌ API test curl command failed with exit code $CURL_EXIT_CODE for ${ip_address}. Skipping."
      :
    fi
  else
     echo "    [Test] ❌ Port ${target_port} closed or timed out for ${ip_address}. Skipping."
  fi
}

# Ensure the temporary file is cleaned up on exit
trap "rm -f $TEMP_RESULTS_FILE" EXIT

# Use process substitution and mapfile to read IPs into an array in the current shell
mapfile -t UNIQUE_IP_ADDRESSES < <(
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
  ' < "$JSON_FILE" | sort -u
)

# Array to store process IDs (PIDs) of background jobs
PIDS=()
commands_generated_count=0 # This will be counted from the TEMP_RESULTS_FILE at the end
total_ips_processed=0

# Iterate over the UNIQUE_IP_ADDRESSES array to launch concurrent tests
for IP_ADDRESS in "${UNIQUE_IP_ADDRESSES[@]}"; do
  ((total_ips_processed++))
  # Run the test function in the background
  perform_test "${IP_ADDRESS}" "${TARGET_PORT}" "${CONNECT_TEST_TIMEOUT}" "${CURL_TEST_TIMEOUT}" "${TEST_CID}" &
  PIDS+=($!) # Add the PID of the background job to the PIDS array

  # Limit concurrent jobs
  if (( ${#PIDS[@]} >= MAX_CONCURRENT_TESTS )); then
    # Wait for the first job to finish, then remove it from the array
    wait "${PIDS[0]}"
    PIDS=("${PIDS[@]:1}") # Remove the first element
  fi
done

# Wait for all remaining background jobs to complete
echo "-----------------------------------------------------"
echo "Waiting for all background tests to complete..."
wait "${PIDS[@]}" # Wait for any remaining processes
echo "All background tests finished."

# Read the generated commands from the temporary file
mapfile -t CURL_COMMANDS < "$TEMP_RESULTS_FILE"
commands_generated_count=${#CURL_COMMANDS[@]}

echo "-----------------------------------------------------"
echo "Summary of IP processing:"
echo "  Total unique IPs found: ${#UNIQUE_IP_ADDRESSES[@]}"
echo "  Commands generated (passed all tests): ${commands_generated_count}"
echo "  Skipped (unreachable or API error) IPs: $(( total_ips_processed - commands_generated_count ))"


if [ ${#CURL_COMMANDS[@]} -eq 0 ]; then
    echo "Warning: No curl commands were generated. This might mean no unique IPs were found or none passed the tests."
    echo "-----------------------------------------------------"
fi

# --- Write all collected curl commands to the output file ---
echo -e "\n--- Writing $commands_generated_count generated commands to '$OUTPUT_FILE' ---"
for cmd in "${CURL_COMMANDS[@]}"; do
  echo "$cmd" >> "$OUTPUT_FILE"
done

echo "-----------------------------------------------------"
echo "--- Process Complete. Commands saved to '$OUTPUT_FILE' ---"
echo "To execute: 'chmod +x $OUTPUT_FILE', then './$OUTPUT_FILE <timeout_seconds> <arg_value>'"
echo "Example: './$OUTPUT_FILE 10 QmYmyoZQYxP6UvV4u2oVqFm5x4Z9X0X0X0X0X0X0X0'"