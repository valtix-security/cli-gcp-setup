#!/bin/bash
# This script is provided by Valtix to enable traffic visibility for your GCP project. It will
# enable both flow logs and dns logs for the vpc list you provide.
#

prefix=valtix
project_id=""
storage_bucket=""
vpcs=""
webhook_endpoint=""

####################################################################################

usage() {
    echo "Usage: $0 [args]"
    echo "-h This help message"
    echo "-i <project_id> - ID of the project you want to enable traffic visibility for"
    echo "-p <prefix> - Prefix to use for the traffic visibility related resources, defaults to valtix"
    echo "-s <storage_bucket> - Name of the storage bucket used to store flow logs and dns logs"
    echo "-v <vpcs> - Comma separate list of vpc names you want to enable traffic visibility for"
    echo "-w <webhook_endpoint> - Your Webhook Endpoint, used for traffic visibility"
    exit 1
}

while getopts "hi:p:s:v:w:" optname; do
    case "${optname}" in
        h)
            usage
            ;;
        i)
            project_id=${OPTARG}
            ;;
        p)
            prefix=${OPTARG}
            ;;
        s)
            storage_bucket=${OPTARG}
            ;;
        v)
            vpcs=${OPTARG}
            ;;
        w)
            webhook_endpoint=${OPTARG}
            ;;
    esac
done

printf 'Setting up traffic log in project: %s\n' $project_id
gcloud config set project $project_id

printf 'Enabling flow logs for vpcs %s' ${vpcs// /}
vpc_list=(${vpcs//,/ })
for vpc in ${vpc_list[@]}; do
    #check which subnets do not have flow logs enabled
    subnets=$(gcloud compute networks subnets list --network=$vpc --format=json)

    subnets_array=()
    subnets_regions_array=()

    for subnet in $(echo "${subnets}" | jq -c '.[]'); do
        name=$(echo ${subnet} | jq '.name')
        region=$(echo ${subnet} | jq '.region')
        flag=$(echo ${subnet} | jq '.enableFlowLogs')
        if [ "$flag" != "true" ]; then
            subnets_array+=(${name//\"/})
            subnets_regions_array+=(${region//\"/})
        fi
    done

    for i in ${!subnets_array[@]}; do
        subnet=${subnets_array[$i]}
        region=${subnets_regions_array[$i]}
        printf 'Going to enable vpc flow logs for subnet %s in region %s\n' $subnet $region
        read -p "Do you want to continue? " -n 1 -r
        echo    # (optional) move to a new line
        if [[ ! $REPLY =~ ^[Yy]$ ]]
        then
            exit 1
        fi
        
        gcloud compute networks subnets update $subnet \
            --enable-flow-logs --region=$region
            
    done
done

# enable dns logs for given vpcs
printf 'Enabling dns logs...\n'
dns_policy_name=${prefix}-dns-policy
dns_policy_id=$(gcloud dns policies list --format=json --filter=name:$dns_policy_name | jq -r .[0].id)
if [ "$dns_policy_id" != "null" ]; then
    printf 'Valtix dns policy already exist. Updating associated vpcs\n'
    gcloud dns policies update $dns_policy_name --enable-logging --networks=${vpcs// /}
else
    printf 'Creating valtix dns policy and associating it with given vpcs: %s\n', $dns_policy_name
    gcloud dns policies create $dns_policy_name --enable-logging --networks=${vpcs// /} \
        --description="valtix dns policy for dns logs"
    printf 'Created valtix dns policy and associated with given vpcs: %s\n', $dns_policy_name
fi


traffic_log_sink_name=${prefix}-traffic-log-sink
traffic_log_topic_name=${prefix}-traffic-log-topic
traffic_log_subscription_name=${prefix}-traffic-log-subscription
printf 'Valtix traffic log pub/sub topic: %s\n' $traffic_log_topic_name
printf 'Valtix traffic log pub/sub subscription: %s\n' $traffic_log_subscription_name
printf 'Valtix traffic log logging sink: %s\n' $traffic_log_sink_name

# check if a logging sink exists
traffic_log_sink_id=$(gcloud logging sinks list --format=json --filter=name:$traffic_log_sink_name | jq -r .[0].name)
if [ "$traffic_log_sink_id" != "null" ]; then
     printf 'Valtix traffic log logging sink already exists. Skipping\n'
else
    printf 'Creating valtix traffic log logging sink: %s\n', $traffic_log_sink_name
    gcloud logging sinks create $traffic_log_sink_name \
        storage.googleapis.com/$storage_bucket \
        --log-filter='logName="projects/'"$project_id"'/logs/cloudaudit.googleapis.com%2Factivity" OR "projects/'"$project_id"'/logs/dns.googleapis.com%2Fdns_queries"'
    printf 'Created valtix traffic log logging sink: %s\n', $traffic_log_sink_name
fi

# check if a pub/sub topic exists
traffic_log_topic_id=$(gcloud pubsub topics list --format=json --filter=name:$traffic_log_topic_name | jq -r .[0].name)
if [ "$traffic_log_topic_id" != "null" ]; then
    printf 'Valtix traffic log pub/sub topic already exist. Skipping\n'
else
    printf 'Creating valtix traffic log pub/sub topic: %s\n', $traffic_log_topic_name
    gcloud pubsub topics create $traffic_log_topic_name
    printf 'Created valtix traffic log pub/sub topic: %s\n', $traffic_log_topic_name
fi

# check if a pub/sub subscription exists
traffic_log_subscription_id=$(gcloud pubsub subscriptions list --format=json --filter=name:$traffic_log_subscription_name | jq -r .[0].name)
if [ "$traffic_log_subscription_id" != "null" ]; then
     printf 'Valtix traffic log pub/sub subscription already exists. Skipping\n'
else
    printf 'Creating valtix traffic log pub/sub subscription: %s\n', $traffic_log_subscription_name
    gcloud pubsub subscriptions create $traffic_log_subscription_name \
        --topic=$traffic_log_topic_name \
        --push-endpoint=$webhook_endpoint
    printf 'Created valtix traffic log pub/sub subscription: %s\n', $traffic_log_subscription_name
fi


# grant objectCreator role to the writer identity of logging sink on the storage bucket
traffic_log_sink_writer_identity=$(gcloud logging sinks --format=json describe $traffic_log_sink_name | jq -r .writerIdentity)
if [ "$traffic_log_sink_writer_identity" == "null" ]; then
    printf 'Valtix traffic logging sink does not have proper writer identity\n'
    exists 1
else
    printf 'Granting objectCreator role to valtix traffic logging sink writer identity\n'
    gsutil iam ch $traffic_log_sink_writer_identity:objectCreator \
        gs://$storage_bucket
fi

# enable cloud storage notification to traffic log topic
gsutil notification create -t $traffic_log_topic_name -f json gs://$storage_bucket

printf 'Flow logs and dns logs have been enabled for vpcs %s\n' ${vpcs// /}