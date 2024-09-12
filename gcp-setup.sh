#!/bin/bash

# Script used to configure/prepare the GCP project so the Multicloud Defense Controller can manage it
# The executor of this script needs the following permissions/roles

# Logging Admin - roles/logging.admin
# Pub/Sub Admin - roles/pubsub.admin
# Security Admin - roles/iam.securityAdmin
# Service Account Admin - roles/iam.serviceAccountAdmin
# Service Account Key Admin - roles/iam.serviceAccountKeyAdmin
# Service Usage Admin - roles/serviceusage.serviceUsageAdmin
# Storage Admin - roles/storage.admin
# Compute Admin - roles/compute.admin
# DNS Administrator - roles/dns.admin
# Service Account Token Creator  - roles/iam.serviceAccountTokenCreator

# Create 2 service accounts (for Multicloud Defense Controller and Multicloud Defense Gateway)
# Create a pub/sub topic and subscription
# Create storage bucket for the flow logs

prefix=ciscomcd
webhook_endpoint=

usage() {
    echo "Usage: $0 [args]"
    echo "-h This help message"
    echo "-p <prefix> - Prefix to use for the Service Accounts, defaults to ciscomcd"
    echo "-w <webhook_endpoint> - Your Webhook Endpoint, used for real time inventory"
    exit 1
}

while getopts "hp:w:" optname; do
    case "${optname}" in
        h)
            usage
            ;;
        p)
            prefix=${OPTARG}
            ;;
        w)
            webhook_endpoint=${OPTARG}
            ;;
    esac
done

output=$(gcloud projects list --sort-by projectId --format 'value(projectId)')
project=($output)
echo "Select your project"
echo
num=1
for i in ${project[@]}; do
	echo "[$num] $i"
	num=$(expr $num + 1 )
done
num=$(expr $num - 1)
echo
read -p "Enter number from 1 - $num:  " yn
echo
yn=$(expr $yn - 1)
echo "You selected ${project[$yn]}"
echo
read -p "Continue configuring this project? [y/n] " -n 1 -r
if [[ $REPLY != y ]]; then
    exit 1
fi
echo
echo
gcloud config set project ${project[$yn]}

# Enable API Services on the project
echo "Enable API Services on the project"
apis=(
    compute.googleapis.com
    iam.googleapis.com
    pubsub.googleapis.com
    logging.googleapis.com
    dns.googleapis.com
    secretmanager.googleapis.com
)
for api in ${apis[@]}; do
    echo "Enable $api"
    gcloud services enable $api
done

project_id=$(gcloud config list --format 'value(core.project)')
sa_controller_name=${prefix}-controller
sa_gateway_name=${prefix}-gateway

echo "Creating service accounts"

echo "Creating Multicloud Defense Controller service account: $sa_controller_name"
controller_result=$(gcloud iam service-accounts list --format=json --filter=name:$sa_controller_name | jq -r .[0].email)
if [ "$controller_result" != "null" ]; then
    echo "Multicloud Defense Controller service account already exists, Skipping"
else
    gcloud iam service-accounts create $sa_controller_name \
        --description="service account used by Multicloud Defense to create resources in the project" \
        --display-name=$sa_controller_name \
        --no-user-output-enabled --quiet
fi

echo "Creating Multicloud Defense Gateway service account: $sa_gateway_name"
gateway_result=$(gcloud iam service-accounts list --format=json --filter=name:$sa_gateway_name | jq -r .[0].email)
if [ "$gateway_result" != "null" ]; then
    echo "Multicloud Defense Gateway service account already exists, Skipping"
else
    gcloud iam service-accounts create $sa_gateway_name \
        --description="service account used by Multicloud Defense gateway to access GCP Secrets" \
        --display-name=$sa_gateway_name \
        --no-user-output-enabled --quiet
fi

# wait for the service accounts to be created
while true; do
    echo "Wait until service accounts are created.."
    controller_result=$(gcloud iam service-accounts list --format=json --filter=name:$sa_controller_name | jq -r .[0].email)
    gateway_result=$(gcloud iam service-accounts list --format=json --filter=name:$sa_gateway_name | jq -r .[0].email)
    if [ "$controller_result" == "null" ] || [ "$gateway_result" == "null" ]; then
        sleep 5
    else
        break
    fi
done

sa_ciscomcd_controller_email=$controller_result
sa_ciscomcd_gateway_email=$gateway_result

echo
echo "Adding roles to the Multicloud Defense Controller service account: $sa_ciscomcd_controller_email"
controller_roles=(
    "roles/compute.admin"
    "roles/iam.serviceAccountUser"
    "roles/pubsub.admin"
    "roles/logging.admin"
    "roles/storage.admin"
    "roles/iam.serviceAccountTokenCreator"
)
for role in ${controller_roles[@]}; do
    echo "Add \"$role\""
    gcloud projects add-iam-policy-binding $project_id \
        --member serviceAccount:$sa_ciscomcd_controller_email \
        --role "$role" \
        --condition=None \
        --no-user-output-enabled --quiet
done

echo
echo "Adding roles to the Multicloud Defense Gateway service account: $sa_ciscomcd_gateway_email"
gw_roles=(
    "roles/secretmanager.secretAccessor"
    "roles/logging.logWriter"
)

for role in ${gw_roles[@]}; do
    echo "Add \"$role\""
    gcloud projects add-iam-policy-binding $project_id \
        --member serviceAccount:$sa_ciscomcd_gateway_email \
        --role "$role" \
        --condition=None \
        --no-user-output-enabled --quiet
done

# enabling real time inventory
inventory_topic_name=${prefix}-inventory-topic
inventory_subscription_name=${prefix}-inventory-subscription
inventory_sink_name=${prefix}-inventory-sink

echo
echo "Setting up real time inventory in project: $project_id"

# check if a pub/sub topic exists
echo "Creating Multicloud Defense inventory pub/sub topic: $inventory_topic_name"
inventory_topic_id=$(gcloud pubsub topics describe $inventory_topic_name --format=json 2>/dev/null | jq -r .name)
if [ "$inventory_topic_id" != "" ]; then
    echo "Multicloud Defense inventory pub/sub topic already exists, Skipping"
else
    gcloud pubsub topics create $inventory_topic_name
fi

# check if a pub/sub subscription exists
echo "Creating Multicloud Defense inventory pub/sub subscription: $inventory_subscription_name"
inventory_subscription_id=$(gcloud pubsub subscriptions describe $inventory_subscription_name --format=json 2>/dev/null | jq -r .name)
if [ "$inventory_subscription_id" != "" ]; then
     echo "Multicloud Defense inventory pub/sub subscription already exists, Skipping"
else
    gcloud pubsub subscriptions create $inventory_subscription_name \
        --topic=$inventory_topic_name \
        --push-endpoint=$webhook_endpoint \
        --push-auth-service-account=$sa_ciscomcd_controller_email
fi

# check if a logging sink exists
echo "Creating Multicloud Defense inventory logging sink: $inventory_sink_name"
inventory_sink_id=$(gcloud logging sinks describe $inventory_sink_name --format=json 2>/dev/null | jq -r .name)
if [ "$inventory_sink_id" != "" ]; then
     echo "Multicloud Defense inventory logging sink already exists, Skipping"
else
    gcloud logging sinks create $inventory_sink_name \
        pubsub.googleapis.com/projects/$project_id/topics/$inventory_topic_name \
        --log-filter='resource.type=("gce_instance" OR "gce_network" OR "gce_subnetwork" OR "gce_forwarding_rule" OR "gce_target_pool" OR "gce_backend_service" OR "gce_target_http_proxy" OR "gce_target_https_proxy") logName="projects/'"$project_id"'/logs/cloudaudit.googleapis.com%2Factivity"'
fi

# grant pub/sub publisher role to the writer identity of logging sink on the topic
inventory_sink_writer_identity=$(gcloud logging sinks --format=json describe $inventory_sink_name 2>/dev/null | jq -r .writerIdentity)
if [ "$inventory_sink_writer_identity" == "" ]; then
    echo "Multicloud Defense inventory logging sink does not have proper writer identity"
else
    echo "Granting publisher role to $inventory_sink_writer_identity"
    gcloud pubsub topics add-iam-policy-binding $inventory_topic_name \
        --member=$inventory_sink_writer_identity \
        --role=roles/pubsub.publisher
fi

# create a cloud storage bucket for traffic logs
storage_bucket_name=${prefix}-log-bucket
echo "Creating cloud storage bucket for traffic logs: $storage_bucket_name"
err_msg=$(gsutil du -s gs://$storage_bucket_name 2>/dev/null | grep "$storage_bucket_name")
if [ "$err_msg" != "" ]; then
    echo "Cloud Storage Bucket already exists, Skipping"
else
    gsutil mb gs://$storage_bucket_name
fi

echo "Create JSON key for the Multicloud Defense Controller Service Account and downloading to ${prefix}_key.json"
gcloud iam service-accounts keys create ~/${prefix}_key.json \
  --iam-account $sa_ciscomcd_controller_email

private_key=$(cat ~/${prefix}_key.json | jq -r .private_key)
echo "-----------------------------------------------------------------------------------"
echo "# Information required to onboard this project to the Multicloud Defense Controller"
echo "-----------------------------------------------------------------------------------"
echo "Project ID: ${project_id}"
echo "Client Email: ${sa_ciscomcd_controller_email}"
echo "Private Key: ${private_key}"
echo "Storage Bucket: $storage_bucket_name"

cleanup_file=delete-gcp-setup.sh
echo > $cleanup_file
echo "Create uninstaller script in the current directory '$cleanup_file'"
for role in ${controller_roles[@]}; do
    echo gcloud projects remove-iam-policy-binding $project_id \
        --member serviceAccount:$sa_ciscomcd_controller_email \
        --role "$role" \
        --condition=None \
        --no-user-output-enabled --quiet >> $cleanup_file
done
for role in ${gw_roles[@]}; do
    echo gcloud projects remove-iam-policy-binding $project_id \
        --member serviceAccount:$sa_ciscomcd_gateway_email \
        --role "$role" \
        --condition=None \
        --no-user-output-enabled --quiet >> $cleanup_file
done
echo "gcloud iam service-accounts delete ${sa_ciscomcd_gateway_email} --quiet" >> $cleanup_file
echo "gcloud iam service-accounts delete ${sa_ciscomcd_controller_email} --quiet" >> $cleanup_file
echo "gcloud logging sinks delete ${inventory_sink_name} --quiet" >> $cleanup_file
echo "gcloud pubsub subscriptions delete ${inventory_subscription_name} --quiet" >> $cleanup_file
echo "gcloud pubsub topics delete ${inventory_topic_name} --quiet" >> $cleanup_file
echo "gsutil rm -r gs://${storage_bucket_name}" >> $cleanup_file
echo "rm $cleanup_file" >> $cleanup_file