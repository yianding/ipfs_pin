#!/bin/bash

# --- Usage ---
# Run this script with the JSON file path as the ONLY argument.
# The curl_connect_timeout and arg_value will be passed *when out.sh is executed*.
# Example: ./generate_dynamic_curls.sh /path/to/your/network_data.json
#          $0                               $1

# --- Configuration ---
# Define the output file for curl commands
OUTPUT_FILE="ipfspin.sh"

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
echo "--- Generating 'curl' commands to '$OUTPUT_FILE' ---"
echo "    (Each command in '$OUTPUT_FILE' will use \$1 for timeout and \$2 for arg_value)"

echo "Command Generation Log:"
echo "-----------------------------------------------------"

# Define the target port (still needed for URL construction)
TARGET_PORT="5001" 

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

# Array to store generated curl commands
declare -a CURL_COMMANDS=()
commands_generated_count=0

# Iterate over the UNIQUE_IP_ADDRESSES array
for IP_ADDRESS in "${UNIQUE_IP_ADDRESSES[@]}"; do
  # Prepare IP addresses for curl URL construction
  CURL_TARGET_IP="$IP_ADDRESS" 
  
  # Construct the full curl command string using $1 and $2
  # These $1 and $2 will be variables when out.sh is executed later
  GENERATED_COMMAND="curl --connect-timeout \$1 -X POST \"http://${CURL_TARGET_IP}:${TARGET_PORT}/api/v0/pin/add?arg=\$2&progress=false\" &"
  
  # Add the generated command to the array
  CURL_COMMANDS+=("$GENERATED_COMMAND")
  ((commands_generated_count++)) # Increment counter

  #echo "  Generated command for $IP_ADDRESS: $GENERATED_COMMAND"
  #echo "      -----------------------------------------------------"
done

if [ ${#CURL_COMMANDS[@]} -eq 0 ]; then
    echo "Warning: No curl commands were generated. This might mean no unique IPs were found from the JSON file."
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
