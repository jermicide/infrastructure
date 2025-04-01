# Azure Static Web App Deployment Scripts

This repository contains two Bash scripts that automate the deployment of Azure Static Web Apps with custom domain configuration. Choose the script that matches your DNS provider.

## Scripts Overview

- **`createwebapp-godaddy.sh`**: Creates an Azure Static Web App and configures custom domains using GoDaddy DNS
- **`createwebapp-cloudflare.sh`**: Creates an Azure Static Web App and configures custom domains using Cloudflare DNS

Both scripts handle the complete workflow:
1. Create an Azure Static Web App from a GitHub repository
2. Configure DNS records for custom domain validation
3. Add the custom domain to the Azure Static Web App

## Prerequisites

### General Requirements
- Azure CLI installed
- `jq` installed (for JSON parsing)
- `curl` installed
- A GitHub repository containing your static website code
- A GitHub Personal Access Token with repo scope permissions

### For GoDaddy Script
- A domain managed by GoDaddy
- GoDaddy API Key and Secret

### For Cloudflare Script
- A domain managed by Cloudflare
- Cloudflare API Token with Zone:DNS permissions

## Environment Variables

### Required for Both Scripts
- `GITHUBPAT`: GitHub Personal Access Token

### For GoDaddy Script
- `GODADDY_API_KEY`: Your GoDaddy API Key
- `GODADDY_API_SECRET`: Your GoDaddy API Secret

### For Cloudflare Script
- `CLOUDFLARE_API_TOKEN`: Your Cloudflare API Token

## Usage

### GoDaddy Version

```bash
./createwebapp-godaddy.sh <webapp_name> <resource_group> <github_repo_url> <custom_domain>
```

### Cloudflare Version

```bash
./createwebapp-cloudflare.sh <webapp_name> <resource_group> <github_repo_url> <custom_domain>
```

### Parameters

1. `webapp_name`: The name of your Azure Static Web App
2. `resource_group`: The Azure resource group where the app will be created
3. `github_repo_url`: The URL of your GitHub repository (e.g., https://github.com/username/repo)
4. `custom_domain`: The custom domain to use (e.g., www.example.com or example.com)

## Script Behavior

- If the Azure resource group doesn't exist, it will be created
- If a Static Web App with the same name already exists, it will be deleted and recreated
- The scripts will automatically extract the domain root from the custom domain (e.g., "example.com" from "www.example.com")
- DNS records for domain validation will be created automatically
- For apex domains (e.g., example.com) with GoDaddy, an A record will be added
- For apex domains with Cloudflare, a CNAME record will be added (utilizing Cloudflare's CNAME flattening)
- For subdomains (e.g., www.example.com), a CNAME record will be added for both providers
- The script waits for DNS validation before completing

## Getting API Credentials

### GoDaddy API Key
1. Go to https://developer.godaddy.com/keys
2. Sign in with your GoDaddy account
3. Create a production API key and secret

### Cloudflare API Token
1. Log in to the Cloudflare dashboard
2. Go to "My Profile" > "API Tokens"
3. Create a token with "Zone:DNS:Edit" permissions for the specific zone (domain)

## Example Usage

```bash
# Set environment variables
export GITHUBPAT="your_github_token"
export GODADDY_API_KEY="your_godaddy_key"
export GODADDY_API_SECRET="your_godaddy_secret"

# Run the GoDaddy script
./createwebapp-godaddy.sh mywebapp myresourcegroup https://github.com/myusername/myrepo www.example.com
```

```bash
# Set environment variables
export GITHUBPAT="your_github_token"
export CLOUDFLARE_API_TOKEN="your_cloudflare_token"

# Run the Cloudflare script
./createwebapp-cloudflare.sh mywebapp myresourcegroup https://github.com/myusername/myrepo www.example.com
```

## Notes

- SSL/TLS certificates for your custom domains are automatically provisioned by Azure
- DNS propagation may take some time (typically 30 mins to a few hours)
- The scripts have a built-in wait option for DNS propagation
- For apex domains, a special handling for DNS records is implemented

## Troubleshooting

- **DNS validation fails**: Ensure your API credentials have the correct permissions and try increasing the wait time
- **GitHub token errors**: Ensure your PAT has the repo scope and hasn't expired
- **Azure CLI errors**: Run `az login` before executing the script
- **API rate limiting**: If you encounter rate limits, wait a few minutes and try again

## License

MIT