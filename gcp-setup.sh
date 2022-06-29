#!/bin/bash
# This script is provided by Valtix to create the two GCP Project service accounts needed to:
#
# 1. allow Valtix controller access to deploy services into the GCP Project
# 2. allow Valtix gateway access to GCP Secret Manager (optional)
#
prefix=valtix
webhook_endpoint=""
####################################################################################

usage() {
    echo "Usage: $0 [args]"
    echo "-h This help message"
    echo "-p <prefix> - Prefix to use for the Service Accounts, defaults to valtix"
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

test=$(gcloud projects list | grep -Po 'PROJECT_ID: \K.*')
printf "Select your project\n"
num=0
project=($test)
for i in $test
do
	echo "($num) $i"
	num=$(( $num + 1 ))
done
num=$(($num-1))
read -p "Enter number from 0 - $num.  " yn
printf "You selected ${project[$yn]}\n"
gcloud config set project ${project[$yn]}
gcloud services enable compute.googleapis.com
gcloud services enable iam.googleapis.com
gcloud services enable pubsub.googleapis.com
gcloud services enable logging.googleapis.com

#(optional): gcloud services enable secretmanager.googleapis.com
gcloud services enable secretmanager.googleapis.com

project_id=$(gcloud config list --format 'value(core.project)')
sa_controller_name=${prefix}-controller
sa_gateway_name=${prefix}-gateway
printf 'Setting up service accounts in project: %s\n' $project_id
printf 'Valtix controller service account: %s\n' $sa_controller_name
printf 'Valtix gateway service account: %s\n' $sa_gateway_name

# wait for confirmation
read -p "Are you sure you want to go ahead? " -n 1 -r
echo    # (optional) move to a new line
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    exit 1
fi
printf "Creating service accounts..\n"

controller_result=$(gcloud iam service-accounts list --format=json --filter=name:$sa_controller_name | jq -r .[0].email)
if [ "$controller_result" != "null" ]; then
    printf 'Valtix controller service account already exists. Skipping\n'
else
    gcloud iam service-accounts create $sa_controller_name \
        --description="service account used by Valtix to create resources in the project" \
        --display-name=$sa_controller_name \
        --no-user-output-enabled --quiet
fi

gateway_result=$(gcloud iam service-accounts list --format=json --filter=name:$sa_gateway_name | jq -r .[0].email)
if [ "$gateway_result" != "null" ]; then
    printf 'Valtix gateway service account already exists. Skipping\n'
else
    gcloud iam service-accounts create $sa_gateway_name \
        --description="service account used by Valtix gateway to access GCP Secrets" \
        --display-name=$sa_gateway_name \
        --no-user-output-enabled --quiet
fi

# wait for the service accounts to be created
while true; do
    printf "Wait until service accounts are created..\n"
    controller_result=$(gcloud iam service-accounts list --format=json --filter=name:$sa_controller_name | jq -r .[0].email)
    gateway_result=$(gcloud iam service-accounts list --format=json --filter=name:$sa_gateway_name | jq -r .[0].email)
    if [ "$controller_result" == "null" ] || [ "$gateway_result" == "null" ]; then
        sleep 5
    else
        break
    fi
done
sa_valtix_controller_email=$controller_result
sa_valtix_gateway_email=$gateway_result

printf 'Created valtix controller service account: %s\n' $sa_valtix_controller_email
printf 'Created valtix gateway service account: %s\n' $sa_valtix_gateway_email
printf "Binding IAM roles to service accounts..\n"
gcloud projects add-iam-policy-binding $project_id --member \
 serviceAccount:$sa_valtix_controller_email \
 --role "roles/compute.admin" \
 --condition=None \
 --no-user-output-enabled --quiet

gcloud projects add-iam-policy-binding $project_id --member \
 serviceAccount:$sa_valtix_controller_email \
 --role "roles/iam.serviceAccountUser" \
 --condition=None \
 --no-user-output-enabled --quiet

gcloud projects add-iam-policy-binding $project_id --member \
 serviceAccount:$sa_valtix_controller_email \
 --role "roles/pubsub.admin" \
 --condition=None \
 --no-user-output-enabled --quiet

gcloud projects add-iam-policy-binding $project_id --member \
 serviceAccount:$sa_valtix_controller_email \
 --role "roles/logging.admin" \
 --condition=None \
 --no-user-output-enabled --quiet

# This step is optional.  This is to allow Valtix Gateway service account access secrets from Secret Manager
gcloud projects add-iam-policy-binding $project_id --member \
 serviceAccount:$sa_valtix_gateway_email \
 --role "roles/secretmanager.secretAccessor" \
 --condition=None \
 --no-user-output-enabled --quiet

gcloud projects add-iam-policy-binding $project_id --member \
 serviceAccount:$sa_valtix_gateway_email \
 --role "roles/logging.logWriter" \
 --condition=None \
 --no-user-output-enabled --quiet

# enabling real time inventory
inventory_topic_name=${prefix}-inventory-topic
inventory_subscription_name=${prefix}-inventory-subscription
inventory_sink_name=${prefix}-inventory-sink
printf 'Setting up real time inventory in project: %s\n' $project_id
printf 'Valtix inventory pub/sub topic: %s\n' $inventory_topic_name
printf 'Valtix inventory pub/sub subscription: %s\n' $inventory_subscription_name
printf 'Valtix inventory logging sink: %s\n' $inventory_sink_name

# check if a pub/sub topic exists
inventory_topic_id=$(gcloud pubsub topics list --format=json --filter=name:$inventory_topic_name | jq -r .[0].name)
if [ "$inventory_topic_id" != "null" ]; then
    printf 'Valtix inventory pub/sub topic already exist. Skipping\n'
else
    printf 'Creating valtix inventory pub/sub topic: %s\n', $inventory_topic_name
    gcloud pubsub topics create $inventory_topic_name
    printf 'Created valtix inventory pub/sub topic: %s\n', $inventory_topic_name
fi

# check if a pub/sub subscription exists
inventory_subscription_id=$(gcloud pubsub subscriptions list --format=json --filter=name:$inventory_subscription_name | jq -r .[0].name)
if [ "$inventory_subscription_id" != "null" ]; then
     printf 'Valtix inventory pub/sub subscription already exists. Skipping\n'
else
    printf 'Creating valtix inventory pub/sub subscription: %s\n', $inventory_subscription_name
    gcloud pubsub subscriptions create $inventory_subscription_name \
        --topic=$inventory_topic_name \
        --push-endpoint=$webhook_endpoint
    printf 'Created valtix inventory pub/sub subscription: %s\n', $inventory_subscription_name
fi

# check if a logging sink exists
inventory_sink_id=$(gcloud logging sinks list --format=json --filter=name:$inventory_sink_name | jq -r .[0].name)
if [ "$inventory_sink_id" != "null" ]; then
     printf 'Valtix inventory logging sink already exists. Skipping\n'
else
    printf 'Creating valtix inventory logging sink: %s\n', $inventory_sink_name
    gcloud logging sinks create $inventory_sink_name \
        pubsub.googleapis.com/projects/$project_id/topics/$inventory_topic_name \
        --log-filter='resource.type=("gce_instance" OR "gce_network" OR "gce_subnetwork" OR "gce_forwarding_rule" OR "gce_target_pool" OR "gce_backend_service" OR "gce_target_http_proxy" OR "gce_target_https_proxy") logName="projects/'"$project_id"'/logs/cloudaudit.googleapis.com%2Factivity"'
    printf 'Created valtix inventory logging sink: %s\n', $inventory_sink_name
fi

# grant pub/sub publisher role to the writer identity of logging sink on the topic
inventory_sink_writer_identity=$(gcloud logging sinks --format=json describe $inventory_sink_name | jq -r .writerIdentity)
if [ "$inventory_sink_writer_identity" == "null" ]; then
    printf 'Valtix inventory logging sink does not have proper writer identity\n'
    exists 1
else
    printf 'Granting publisher role to valtix inventory logging sink writer identity\n'
    gcloud pubsub topics add-iam-policy-binding $inventory_topic_name \
        --member=$inventory_sink_writer_identity \
        --role=roles/pubsub.publisher
fi

printf "Downloading JSON key to %s_key.json..\n" $prefix
gcloud iam service-accounts keys create ~/${prefix}_key.json \
  --iam-account $sa_valtix_controller_email

private_key=$(cat ~/${prefix}_key.json | jq -r .private_key)
printf "#############################################################################\n"
printf "##Below information will be needed to onboard project to Valtix Controller\n"
printf "#############################################################################\n"
printf "Project ID: ${project_id}\n"
printf "Client Email: ${sa_valtix_controller_email}\n"
printf "Private Key: \n${private_key}\n"
printf "#############################################################################\n"

cleanup_file=delete-gcp-setup.sh
echo "Create uninstaller script in the current directory '$cleanup_file'"
echo "gcloud iam service-accounts delete ${sa_valtix_gateway_email} --quiet" > $cleanup_file
echo "gcloud iam service-accounts delete ${sa_valtix_controller_email} --quiet" >> $cleanup_file
echo "gcloud logging sinks delete ${inventory_sink_name} --quiet" >> $cleanup_file
echo "gcloud pubsub subscriptions delete ${inventory_subscription_name} --quiet" >> $cleanup_file
echo "gcloud pubsub topics delete ${inventory_topic_name} --quiet" >> $cleanup_file
echo "rm $cleanup_file" >> $cleanup_file
chmod +x $cleanup_file

