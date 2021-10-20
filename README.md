# cli-gcp-setup
Onboarding script for GCP. This script will create service account used by Valtix Controller and Valtix Gateway. 

# Usage
```
gcp-setup.sh -h
Usage: ./gcp-setup.sh [args]
-h This help message
-p <prefix> - Prefix to use for the Service Accounts, defaults to valtix
```

The script creates two service account with name \<prefix\>-controller and \<prefix\>-gateway. 
  
# Output
The script outputs the information required by the Valtix Controller for onboarding your GCP account

# Cleanup
A cleanup/uninstall script `delete-gcp-setup.sh` is created by the setup script. Run this script if you want to delete the role and the app

# Manual Cleanup
1. Go to your GCP project.
1. Navigate to IAM role -> Service Accounts.
1. Search for the 2 service account that was created. It would be named \<prefix\>-controller and \<prefix\>-gateway
1. Delete the 2 service accounts
