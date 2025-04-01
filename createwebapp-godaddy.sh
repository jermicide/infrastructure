#!/bin/bash

# Azure Static Web App with GoDaddy Custom Domain Setup
# This script creates an Azure Static Web App from a GitHub repo,
# adds the custom domain validation entries to GoDaddy DNS,
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

# GoDaddy API Configuration
GODADDY_API_KEY="${GODADDY_API_KEY}"
GODADDY_API_SECRET="${GODADDY_API_SECRET}"
GODADDY_API_URL="https://api.godaddy.com/v1"

# =============== FUNCTIONS ===============

show_usage() {
    echo "Usage: $0 <webapp_name> <resource_group> <github_repo_url> <custom_domain>"
    echo ""
    echo "Example: $0 mystaticsite myresourcegroup https://github.com/username/repo www.example.com"
    echo ""
    echo "Environment variables required:"
    echo "  GITHUBPAT - GitHub Personal Access Token"
    echo "  GODADDYAPIKEY - GoDaddy API Key"
    echo "  GODADDYAPISECRET - GoDaddy API Secret"
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
          -z "$GITHUB_REPO_URL" || -z "$CUSTOM_DOMAIN" || -z "$DOMAIN_ROOT" || 
          -z "$GODADDY_API_KEY" || -z "$GODADDY_API_SECRET" || -z "$GITHUBPAT" ]]; then
        echo "Error: Missing required configuration. Please fill in all the required fields."
        echo "Make sure the GITHUBPAT environment variable is set with your GitHub token."
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
        echo "Static Web App $WEBAPP_NAME already exists."
    else
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
    fi
    
    # Get the default hostname
    DEFAULT_HOSTNAME=$(az staticwebapp show --name "$WEBAPP_NAME" --resource-group "$AZURE_RESOURCE_GROUP" --query "defaultHostname" -o tsv)
    echo "Static Web App created with default hostname: $DEFAULT_HOSTNAME"
}

add_godaddy_dns_entries() {
    echo "Adding DNS entries to GoDaddy..."
    
    # Get validation info from Azure
    echo "Getting custom domain validation info from Azure..."
    VALIDATION_INFO=$(az staticwebapp hostname get-validation-info \
        --hostname "$CUSTOM_DOMAIN" \
        --name "$WEBAPP_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP")
    
    if [ $? -ne 0 ]; then
        echo "Failed to get validation info for custom domain."
        exit 1
    fi
    
    # Extract validation token and domain verification record
    VALIDATION_TOKEN=$(echo "$VALIDATION_INFO" | jq -r '.validationToken')
    DOMAIN_VERIFICATION=$(echo "$VALIDATION_INFO" | jq -r '.domainVerificationToken')
    
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
    
    echo "Adding TXT record to GoDaddy DNS: $TXT_RECORD_NAME"
    
    # Add TXT record for domain validation
    curl -X PUT "$GODADDY_API_URL/domains/$DOMAIN_ROOT/records/TXT/$TXT_RECORD_NAME" \
        -H "Authorization: sso-key $GODADDY_API_KEY:$GODADDY_API_SECRET" \
        -H "Content-Type: application/json" \
        -d "[{\"data\": \"$DOMAIN_VERIFICATION\", \"ttl\": 600}]"
    
    if [ $? -ne 0 ]; then
        echo "Failed to add TXT record to GoDaddy DNS."
        exit 1
    fi
    
    echo "TXT record added successfully."
    
    # Now add CNAME or A record for the domain
    if [[ "$CUSTOM_DOMAIN" == "$DOMAIN_ROOT" ]]; then
        # For apex domain, add A record
        # Get the IP address from Azure Static Web App
        echo "Adding A record for apex domain..."
        
        # For apex domain, we need the regional IP address
        # This is a simplified approach - in production you'd need to handle this differently
        IP_ADDRESS=$(dig +short "$DEFAULT_HOSTNAME")
        
        curl -X PUT "$GODADDY_API_URL/domains/$DOMAIN_ROOT/records/A/@" \
            -H "Authorization: sso-key $GODADDY_API_KEY:$GODADDY_API_SECRET" \
            -H "Content-Type: application/json" \
            -d "[{\"data\": \"$IP_ADDRESS\", \"ttl\": 600}]"
        
        if [ $? -ne 0 ]; then
            echo "Failed to add A record to GoDaddy DNS."
            exit 1
        fi
        
        echo "A record added successfully."
    else
        # For subdomain, add CNAME record
        SUBDOMAIN="${CUSTOM_DOMAIN%%.$DOMAIN_ROOT}"
        echo "Adding CNAME record for subdomain: $SUBDOMAIN"
        
        curl -X PUT "$GODADDY_API_URL/domains/$DOMAIN_ROOT/records/CNAME/$SUBDOMAIN" \
            -H "Authorization: sso-key $GODADDY_API_KEY:$GODADDY_API_SECRET" \
            -H "Content-Type: application/json" \
            -d "[{\"data\": \"$DEFAULT_HOSTNAME\", \"ttl\": 600}]"
        
        if [ $? -ne 0 ]; then
            echo "Failed to add CNAME record to GoDaddy DNS."
            exit 1
        fi
        
        echo "CNAME record added successfully."
    fi
    
    echo "DNS entries added to GoDaddy successfully."
    echo "Note: DNS propagation may take some time (typically 30 mins to 48 hours)."
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

echo "==== Azure Static Web App with GoDaddy Custom Domain Setup ===="
echo ""

# Check if help is requested
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_usage
fi

check_prerequisites "$@"
login_to_azure
create_resource_group_if_not_exists
create_static_web_app
add_godaddy_dns_entries
add_custom_domain_to_static_web_app

echo ""
echo "Setup completed successfully!"
echo "Your Static Web App should now be accessible at: https://$CUSTOM_DOMAIN"
echo "Note: It may take a few minutes for the SSL certificate to be provisioned."