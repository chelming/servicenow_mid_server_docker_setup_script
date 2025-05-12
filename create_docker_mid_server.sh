#!/usr/bin/env bash

# Instructions:
#   1. Create a user account on the instance first.
#         - Do not use the auto-generated password. Reset it to a valid value. 
#   2. Add the mid_server role to the new account.
#   3. Set the Internal Integration User flag.
#   4. Install or validate your host has the jq and unzip packages installed.
#   5. Set the variables below as needed.

# You can override these variables with environment variables of the same name
SERVICENOW_INSTANCE=${SERVICENOW_INSTANCE:-"InstanceName"}
MID_DISPLAY_NAME=${MID_DISPLAY_NAME:-"MID-Server-Name"}
MID_SERVER_NAME=${MID_SERVER_NAME:-"${SERVICENOW_INSTANCE}_docker_linux_mid_server"}
MID_USERNAME=${MID_USERNAME:-"demo.mid"}
MID_PASSWORD=${MID_PASSWORD:-"secret"}

#   6. Execute the script.
#        - The instance will be queried for the correct MID version
#        - The linux docker recipe file will be downloaded from ServiceNow.
#        - The recipe will be extracted and the image built.
#        - An export folder will be created to map the container MID's exports
#          to the host.
#        - A docker-compose.yaml file will be created and an instance started.
#
# NOTE: To update the MID Server after a platform patch or upgrade, just
#       execute the script again. The existing MID will be shutdown and a 
#       new MID server created and linked to the existing MID Server record
#       in ServiceNow. You will need to re-validate the instance and manually
#       remove the old docker container.



# Define color codes for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Function to display error messages and exit
error_exit() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

# Function to display informational messages
info() {
    echo -e "${GREEN}INFO: $1${NC}"
}

# Function to display warning messages
warning() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

# Function to check if required commands are installed
check_dependencies() {
    for cmd in jq unzip curl docker; do
        if ! command -v "$cmd" &> /dev/null; then
            error_exit "$cmd is required but not installed. Please install it and try again."
        fi
    done
    info "All required dependencies are installed."
}

# Function to validate environment variables
validate_variables() {
    local missing=0

    if [ -z "$SERVICENOW_INSTANCE" ] || [ "$SERVICENOW_INSTANCE" = "InstanceName" ]; then
        warning "SERVICENOW_INSTANCE is not set or is still the default value."
        missing=1
    fi

    if [ -z "$MID_DISPLAY_NAME" ] || [ "$MID_DISPLAY_NAME" = "MID-Server-Name" ]; then
        warning "MID_DISPLAY_NAME is not set or is still the default value."
        missing=1
    fi

    if [ -z "$MID_USERNAME" ] || [ "$MID_USERNAME" = "demo.mid" ]; then
        warning "MID_USERNAME is not set or is still the default value."
        missing=1
    fi

    if [ -z "$MID_PASSWORD" ] || [ "$MID_PASSWORD" = "secret" ]; then
        warning "MID_PASSWORD is not set or is still the default value."
        missing=1
    fi

    if [ $missing -eq 1 ]; then
        echo
        error_exit "Please set the required variables in the script or as environment variables."
    fi

    info "All required variables are set."
}

# Function to detect the available docker compose command
detect_docker_compose() {
    local cmd=""

    # Check if "docker compose" works as a command
    if docker compose version &> /dev/null; then
        cmd="docker compose"
        info "'docker compose' command is available."
    elif docker-compose version &> /dev/null; then
        cmd="docker-compose"
        info "'docker-compose' is installed."
    else
        error_exit "No docker compose command found. Please install a recent version of Docker to use the compose command."
    fi

    echo "$cmd"
}

# Run dependency checks
check_dependencies

# Validate variables
validate_variables

# Detect which docker compose command to use
DOCKER_COMPOSE_CMD=$(detect_docker_compose)

# Export the available command for later use
export DOCKER_COMPOSE_CMD
info "Using command: $DOCKER_COMPOSE_CMD"

# If there is a docker compose file, then make sure the container is stopped.
if test -f ./docker-compose.yaml || test -f ./docker-compose.yml; then
    info "Shutting down the existing MID Server container..."
    $DOCKER_COMPOSE_CMD down || error_exit "Failed to stop existing container."
fi

# Get the instance MID Server version
URL="https://${SERVICENOW_INSTANCE}.service-now.com/api/now/table/sys_properties?sysparm_query=name=mid.version&sysparm_fields=value&sysparm_limit=1"
RESPONSE_JSON=$(curl -s ${URL} --request GET --header "Accept:application/json" --user ${MID_USERNAME}:${MID_PASSWORD})

# Verify curl was successful
if [ $? -ne 0 ]; then
    error_exit "Failed to connect to ServiceNow instance. Please check your network connection and instance availability."
fi

# Verify we got a valid JSON response (not an HTML error page)
if ! echo "${RESPONSE_JSON}" | jq -e . >/dev/null 2>&1; then
    error_exit "Invalid JSON response received from ServiceNow. Please check your instance name and credentials."
fi

# Verify the result contains the version information
if ! RELEASE=$(jq -r '.result[0].value' <<< ${RESPONSE_JSON}); then
    error_exit "Failed to parse MID server version from response."
fi

# Verify we actually got a value and not null
if [ -z "${RELEASE}" ] || [ "${RELEASE}" = "null" ]; then
    error_exit "No MID server version found in the response. Verify the user has proper permissions."
fi

info "Setting up a new MID Server for the ${SERVICENOW_INSTANCE} at version ${RELEASE}."

RELEASE_DATE=$(echo ${RELEASE} | cut -d"_" -f4)
# Verify release date was parsed correctly
if [ -z "${RELEASE_DATE}" ]; then
    error_exit "Failed to extract release date from version string: ${RELEASE}"
fi

REL_MONTH=$(echo ${RELEASE_DATE} | cut -d"-" -f1)
REL_DAY=$(echo ${RELEASE_DATE} | cut -d"-" -f2)
REL_YEAR=$(echo ${RELEASE_DATE} | cut -d"-" -f3)

# Verify all date components are set
if [ -z "${REL_MONTH}" ] || [ -z "${REL_DAY}" ] || [ -z "${REL_YEAR}" ]; then
    error_exit "Failed to parse date components from release date: ${RELEASE_DATE}"
fi

info "Using release date: ${REL_MONTH}-${REL_DAY}-${REL_YEAR}"

# Get the recipe
RECIPE_URL="https://install.service-now.com/glide/distribution/builds/package/app-signed/mid-linux-container-recipe/${REL_YEAR}/${REL_MONTH}/${REL_DAY}/mid-linux-container-recipe.${RELEASE}.linux.x86-64.zip"
info "Downloading MID server recipe from: ${RECIPE_URL}"

# Add a timeout to prevent hanging if download stalls
if ! curl -s -f -OL --connect-timeout 30 --max-time 300 "${RECIPE_URL}"; then
    error_exit "Failed to download MID server recipe. Please check the URL: ${RECIPE_URL}"
fi

# Verify the file exists after download
FILE_NAME="mid-linux-container-recipe.${RELEASE}.linux.x86-64.zip"
if [ ! -f "${FILE_NAME}" ]; then
    error_exit "Downloaded file not found."
fi

# Check file size to ensure it's not too small (should be around 90,000)
FILE_SIZE=$(stat -c%s "${FILE_NAME}" 2>/dev/null || stat -f%z "${FILE_NAME}")
if [ "${FILE_SIZE}" -lt 10000 ]; then
    error_exit "Downloaded file is too small (${FILE_SIZE} bytes) and may be incomplete."
fi

# Create the recipe location and extract the recipe
RECIPE_LOCATION=./recipe
# Use -p flag to avoid error if directory already exists
mkdir -p "${RECIPE_LOCATION}" || error_exit "Failed to create recipe directory"

# Add error checking for unzip operation
if ! unzip -q ./"${FILE_NAME}" -d "${RECIPE_LOCATION}"; then
    error_exit "Failed to extract the recipe files."
fi

# Verify the extraction succeeded and contains expected files
if [ ! -f "${RECIPE_LOCATION}/Dockerfile" ]; then
    error_exit "Extraction completed but Dockerfile is missing."
fi

# Create an export folder and set permissions
mkdir -p ./export || error_exit "Failed to create export directory"
if ! chmod 777 ./export; then
    warning "Failed to set permissions on export directory."
fi

# Build the image and tag with both version and latest
info "Building Docker image. This may take a few minutes..."
if ! docker build --tag ${MID_SERVER_NAME}:${RELEASE} ${RECIPE_LOCATION}; then
    error_exit "Failed to build the docker image."
fi

if ! docker tag ${MID_SERVER_NAME}:${RELEASE} ${MID_SERVER_NAME}:latest; then
    error_exit "Failed to create latest tag"
fi
info "Created Docker image: ${MID_SERVER_NAME}:${RELEASE} and ${MID_SERVER_NAME}:latest"

# Cleanup with error handling
if ! rm -r "${RECIPE_LOCATION}"; then
    warning "Failed to remove recipe directory."
fi
if ! rm "${FILE_NAME}"; then
    warning "Failed to remove zip file."
fi

# Create a shell script to connect to the container's BASH shell
cat > console.sh <<EOF
#!/usr/bin/env bash

docker exec -u 0 -it ${MID_SERVER_NAME} bash
EOF

chmod u+x console.sh

# Create a Docker Compose file and run the container
cat > docker-compose.yaml <<EOF
services:
  ${MID_SERVER_NAME}:
    container_name: ${MID_SERVER_NAME}
    image: ${MID_SERVER_NAME}:latest
    restart: unless-stopped
    volumes:
        # Map the MID Servers export directory to the host
        - ./export:/opt/snc_mid_server/agent/export
    environment:
      MID_INSTANCE_URL: "https://${SERVICENOW_INSTANCE}.service-now.com/"
      MID_INSTANCE_USERNAME: "${MID_USERNAME}"
      MID_INSTANCE_PASSWORD: "${MID_PASSWORD}"
      MID_SERVER_NAME: "${MID_DISPLAY_NAME}"

EOF

DOCKER_COMPOSE_CMD up -d || error_exit "Failed to start the MID Server container."

info "Your MID server will start shortly. Do not forget to validate it!"