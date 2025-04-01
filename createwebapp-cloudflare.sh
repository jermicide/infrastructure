#!/bin/bash

# Azure Static Web App with Cloudflare Custom Domain Setup
# This script creates an Azure Static Web App from a GitHub repo,
# adds the custom domain validation entries to Cloudflare DNS,
# and then adds the custom domain to the Static Web App.

# =============== CONFIGURATION ===============

# Azure Configuration
AZURE_RESOURCE_GROUP="$2"
AZURE_LOCATION="eastus2"  # Change as needed

# GitHub Configuration
GITHUBPAT=${GITHUBPAT:-""}  # GitHub Personal Access Token from environment variable

# Static Web App Configuration
WEBAPP_NAME="$1"
GITHUB_REPO_URL="$3"
GITHUB_BRANCH="main"
APP_LOCATION="/"            # Location of application code (relative to repo root)
OUTPUT_LOCATION="."         # No build output - serve files directly
API_LOCATION=""             # No API
SKU="Standard"              # Free, Standard, or Dedicated

# Custom Domain Configuration
CUSTOM_DOMAIN="$4"          # e.g., example.com or www.example.com
# Extract domain root from the custom domain
if [[ "$CUSTOM_DOMAIN" == www.* ]]; then
    # If domain starts with www, remove the www. prefix
    DOMAIN_ROOT="${CUSTOM_DOMAIN#www.}"
else
    # Otherwise, use the custom domain as is
    DOMAIN_ROOT="$CUSTOM_DOMAIN"
fi

# Cloudflare API Configuration
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN}"
CLOUDFLARE_API_URL="https://api.cloudflare.com/client/v4"
# No CLOUDFLARE_ZONE_ID environment variable - we'll always look it up

# =============== FUNCTIONS ===============

show_usage() {
    echo "Usage: $0 <webapp_name> <resource_group> <github_repo_url> <custom_domain>"
    echo ""
    echo "Example: $0 mystaticsite myresourcegroup https://github.com/username/repo www.example.com"
    echo ""
    echo "Environment variables required:"
    echo "  GITHUBPAT - GitHub Personal Access Token"
    echo "  CLOUDFLARE_API_TOKEN - Cloudflare API Token"
    echo "  CLOUDFLARE_ZONE_ID - Cloudflare Zone ID for your domain"
    exit 1
}

check_prerequisites() {
    echo "Checking prerequisites..."
    
    # Check command line arguments
    if [ $# -lt 4 ]; then
        echo "Error: Missing required arguments."
        show_usage
    fi
    
    # Check if Azure CLI is installed
    if ! command -v az &> /dev/null; then
        echo "Azure CLI not found. Please install it: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    fi
    
    # Check if jq is installed
    if ! command -v jq &> /dev/null; then
        echo "jq not found. Please install it: https://stedolan.github.io/jq/download/"
        exit 1
    fi
    
    # Check if curl is installed
    if ! command -v curl &> /dev/null; then
        echo "curl not found. Please install it."
        exit 1
    fi
    
    # Validate configuration
    if [[ -z "$AZURE_RESOURCE_GROUP" || -z "$WEBAPP_NAME" || 
          -z "$GITHUB_REPO_URL" || -z "$CUSTOM_DOMAIN" || 
          -z "$CLOUDFLARE_API_TOKEN" || -z "$GITHUBPAT" ]]; then
        echo "Error: Missing required configuration. Please fill in all the required fields."
        echo "Make sure the GITHUBPAT and CLOUDFLARE_API_TOKEN environment variables are set."
        exit 1
    fi
    
    echo "Prerequisites check completed."
}

login_to_azure() {
    echo "Logging in to Azure..."
    
    # Check if already logged in
    if az account show &> /dev/null; then
        echo "Already logged in to Azure."
    else
        az login
    fi
}

create_resource_group_if_not_exists() {
    echo "Ensuring resource group exists..."
    
    # Check if resource group exists
    if az group show --name "$AZURE_RESOURCE_GROUP" &> /dev/null; then
        echo "Resource group $AZURE_RESOURCE_GROUP already exists."
    else
        echo "Creating resource group $AZURE_RESOURCE_GROUP in $AZURE_LOCATION..."
        az group create --name "$AZURE_RESOURCE_GROUP" --location "$AZURE_LOCATION"
    fi
}

create_static_web_app() {
    echo "Creating Azure Static Web App..."
    
    # Check if the static web app already exists
    if az staticwebapp show --name "$WEBAPP_NAME" --resource-group "$AZURE_RESOURCE_GROUP" &> /dev/null; then
        echo "Static Web App $WEBAPP_NAME already exists. Deleting it first..."
        
        # Delete the existing static web app
        az staticwebapp delete \
            --name "$WEBAPP_NAME" \
            --resource-group "$AZURE_RESOURCE_GROUP" \
            --yes
        
        # Wait for deletion to complete
        echo "Waiting for deletion to complete..."
        sleep 30
    fi
    
    echo "Creating Static Web App $WEBAPP_NAME..."
    
    # Create static web app using Azure CLI with GitHub token
    az staticwebapp create \
        --name "$WEBAPP_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --source "$GITHUB_REPO_URL" \
        --branch "$GITHUB_BRANCH" \
        --app-location "$APP_LOCATION" \
        --output-location "$OUTPUT_LOCATION" \
        --api-location "$API_LOCATION" \
        --sku "$SKU" \
        --token "$GITHUBPAT"
    
    if [ $? -ne 0 ]; then
        echo "Failed to create Static Web App."
        exit 1
    fi
    
    # Get the default hostname
    DEFAULT_HOSTNAME=$(az staticwebapp show --name "$WEBAPP_NAME" --resource-group "$AZURE_RESOURCE_GROUP" --query "defaultHostname" -o tsv)
    echo "Static Web App created with default hostname: $DEFAULT_HOSTNAME"
}

get_zone_id() {
    echo "Getting Cloudflare Zone ID for domain: $DOMAIN_ROOT"
    
    # Always look up the zone ID from Cloudflare API
    ZONE_RESPONSE=$(curl -s -X GET "$CLOUDFLARE_API_URL/zones?name=$DOMAIN_ROOT" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json")
    
    CLOUDFLARE_ZONE_ID=$(echo "$ZONE_RESPONSE" | jq -r '.result[0].id')
    
    if [[ "$CLOUDFLARE_ZONE_ID" == "null" || -z "$CLOUDFLARE_ZONE_ID" ]]; then
        echo "Failed to get Zone ID for domain $DOMAIN_ROOT"
        echo "Response: $ZONE_RESPONSE"
        exit 1
    fi
    
    echo "Cloudflare Zone ID: $CLOUDFLARE_ZONE_ID"
}

add_cloudflare_dns_entries() {
    echo "Adding DNS entries to Cloudflare..."
    
    # First set the hostname with TXT validation method
    echo "Setting up custom domain with TXT validation..."
    az staticwebapp hostname set \
        --name "$WEBAPP_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --hostname "$CUSTOM_DOMAIN" \
        --validation-method "dns-txt-token" \
        --no-wait
    
    # Get validation token from Azure
    echo "Getting custom domain validation token from Azure..."
    echo "This might take a few seconds to generate..."
    
    # Wait for token to be generated
    sleep 10
    
    # Try to get the validation token
    VALIDATION_TOKEN=""
    MAX_ATTEMPTS=12
    ATTEMPT=1
    
    while [ -z "$VALIDATION_TOKEN" ] && [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
        echo "Attempt $ATTEMPT of $MAX_ATTEMPTS to get validation token..."
        
        VALIDATION_TOKEN=$(az staticwebapp hostname show \
            --name "$WEBAPP_NAME" \
            --resource-group "$AZURE_RESOURCE_GROUP" \
            --hostname "$CUSTOM_DOMAIN" \
            --query "validationToken" -o tsv)
        
        if [ -z "$VALIDATION_TOKEN" ] || [ "$VALIDATION_TOKEN" == "null" ]; then
            echo "Validation token not ready yet. Waiting 10 seconds..."
            sleep 10
            ATTEMPT=$((ATTEMPT+1))
            VALIDATION_TOKEN=""
        else
            echo "Validation token obtained successfully."
            break
        fi
    done
    
    if [ -z "$VALIDATION_TOKEN" ]; then
        echo "Failed to get validation token after multiple attempts."
        echo "You may need to view the token in the Azure Portal and add the DNS records manually."
        exit 1
    fi
    
    # The domain verification is the same as the validation token
    DOMAIN_VERIFICATION="$VALIDATION_TOKEN"
    
    echo "Validation Token: $VALIDATION_TOKEN"
    echo "Domain Verification: $DOMAIN_VERIFICATION"
    
    # Determine TXT record name
    if [[ "$CUSTOM_DOMAIN" == "$DOMAIN_ROOT" ]]; then
        # Apex domain
        TXT_RECORD_NAME="_dnsauth"
    else
        # Subdomain (e.g., www)
        SUBDOMAIN="${CUSTOM_DOMAIN%%.$DOMAIN_ROOT}"
        TXT_RECORD_NAME="_dnsauth.$SUBDOMAIN"
    fi
    
    echo "Adding TXT record to Cloudflare DNS: $TXT_RECORD_NAME"
    
    # Add TXT record for domain validation
    TXT_RESPONSE=$(curl -s -X POST "$CLOUDFLARE_API_URL/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"type\": \"TXT\",
            \"name\": \"$TXT_RECORD_NAME\",
            \"content\": \"$DOMAIN_VERIFICATION\",
            \"ttl\": 600
        }")
    
    if [[ $(echo "$TXT_RESPONSE" | jq -r '.success') != "true" ]]; then
        echo "Failed to add TXT record to Cloudflare DNS."
        echo "Response: $TXT_RESPONSE"
        exit 1
    fi
    
    echo "TXT record added successfully."
    
    # Now add CNAME or A record for the domain
    if [[ "$CUSTOM_DOMAIN" == "$DOMAIN_ROOT" ]]; then
        # For apex domain, add A record
        echo "Adding A record for apex domain..."
        
        # Get the IP addresses for the Azure Static Web App
        IP_ADDRESSES=$(dig +short "$DEFAULT_HOSTNAME")
        
        # Take the first IP address (simplified approach)
        IP_ADDRESS=$(echo "$IP_ADDRESSES" | head -n 1)
        
        A_RESPONSE=$(curl -s -X POST "$CLOUDFLARE_API_URL/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{
                \"type\": \"A\",
                \"name\": \"@\",
                \"content\": \"$IP_ADDRESS\",
                \"ttl\": 600,
                \"proxied\": true
            }")
        
        if [[ $(echo "$A_RESPONSE" | jq -r '.success') != "true" ]]; then
            echo "Failed to add A record to Cloudflare DNS."
            echo "Response: $A_RESPONSE"
            exit 1
        fi
        
        echo "A record added successfully."
    else
        # For subdomain, add CNAME record
        SUBDOMAIN="${CUSTOM_DOMAIN%%.$DOMAIN_ROOT}"
        echo "Adding CNAME record for subdomain: $SUBDOMAIN"
        
        CNAME_RESPONSE=$(curl -s -X POST "$CLOUDFLARE_API_URL/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{
                \"type\": \"CNAME\",
                \"name\": \"$SUBDOMAIN\",
                \"content\": \"$DEFAULT_HOSTNAME\",
                \"ttl\": 600,
                \"proxied\": true
            }")
        
        if [[ $(echo "$CNAME_RESPONSE" | jq -r '.success') != "true" ]]; then
            echo "Failed to add CNAME record to Cloudflare DNS."
            echo "Response: $CNAME_RESPONSE"
            exit 1
        fi
        
        echo "CNAME record added successfully."
    fi
    
    echo "DNS entries added to Cloudflare successfully."
    echo "Note: DNS propagation may take some time (typically 30 mins to a few hours)."
}

add_custom_domain_to_static_web_app() {
    echo "Adding custom domain to Azure Static Web App..."
    
    # Check if we should wait for DNS propagation
    read -p "DNS entries need time to propagate. Do you want to wait 10 minutes before continuing? (y/n): " WAIT_RESPONSE
    if [[ "$WAIT_RESPONSE" =~ ^[Yy]$ ]]; then
        echo "Waiting 10 minutes for DNS propagation..."
        sleep 600
    fi
    
    # Add custom domain to static web app
    az staticwebapp hostname add \
        --hostname "$CUSTOM_DOMAIN" \
        --name "$WEBAPP_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --validation-method "dns-txt-token"
    
    if [ $? -ne 0 ]; then
        echo "Failed to add custom domain to Static Web App."
        echo "This could be due to DNS propagation delay. You may need to retry later."
        exit 1
    fi
    
    echo "Custom domain added successfully to the Static Web App."
}

# =============== MAIN SCRIPT ===============

echo "==== Azure Static Web App with Cloudflare Custom Domain Setup ===="
echo ""

# Check if help is requested
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_usage
fi

check_prerequisites "$@"
login_to_azure
create_resource_group_if_not_exists
create_static_web_app
get_zone_id
add_cloudflare_dns_entries
add_custom_domain_to_static_web_app

echo ""
echo "Setup completed successfully!"
echo "Your Static Web App should now be accessible at: https://$CUSTOM_DOMAIN"
echo "Note: It may take a few minutes for the SSL certificate to be provisioned."