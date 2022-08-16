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
    echo "-w <webhook_endpoint> - Valtix Webhook Endpoint, used for traffic visibility"
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

echo "Setting up traffic log in project: $project_id"
gcloud config set project $project_id

vpc_list=(${vpcs//,/ })
flow_log_enabled_subnets=()
flow_log_enabled_regions=()
for vpc in ${vpc_list[@]}; do
    echo "Enabling flow logs for all subnets in vpc: $vpc"
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

    if [ ${#subnets_array[@]} == 0 ]; then
        echo "All subnets of vpc '$vpc' have flow logs enabled"
        continue
    fi

    for i in ${!subnets_array[@]}; do
        subnet=${subnets_array[$i]}
        region=${subnets_regions_array[$i]}
        echo "  Enabling flow logs for subnet $subnet in $region"
        gcloud compute networks subnets update $subnet \
            --enable-flow-logs --region=$region
        flow_log_enabled_subnets+=($subnet)
        flow_log_enabled_regions+=($region)
    done
done

dns_policy_name=${prefix}-dns-policy
echo "Creating Valtix DNS policy '$dns_policy_name' and associating it with given vpcs"
dns_policy_id=$(gcloud dns policies describe $dns_policy_name --format=json 2>/dev/null | jq -r .id)
if [ "$dns_policy_id" != "" ]; then
    echo "Valtix dns policy already exists. Updating associated vpcs"
    gcloud dns policies update $dns_policy_name --enable-logging --networks=${vpcs// /}
else
    gcloud dns policies create $dns_policy_name --enable-logging --networks=${vpcs// /} \
        --description="valtix dns policy for dns logs"
fi

traffic_log_sink_name=${prefix}-traffic-log-sink
traffic_log_topic_name=${prefix}-traffic-log-topic
traffic_log_subscription_name=${prefix}-traffic-log-subscription

echo "Creating Valtix traffic log logging sink: $traffic_log_sink_name"
traffic_log_sink_id=$(gcloud logging sinks describe $traffic_log_sink_name --format=json 2>/dev/null | jq -r .name)
if [ "$traffic_log_sink_id" != "" ]; then
     echo "Valtix traffic log logging sink already exists, Skipping"
else
    gcloud logging sinks create $traffic_log_sink_name \
        storage.googleapis.com/$storage_bucket \
        --log-filter='logName="projects/'"$project_id"'/logs/compute.googleapis.com%2Fvpc_flows" OR "projects/'"$project_id"'/logs/dns.googleapis.com%2Fdns_queries"'
fi

# grant objectCreator role to the writer identity of logging sink on the storage bucket
traffic_log_sink_writer_identity=$(gcloud logging sinks --format=json describe $traffic_log_sink_name 2>/dev/null | jq -r .writerIdentity)
echo "Granting objectCreator role to $traffic_log_sink_writer_identity on bucket $storage_bucket"
gsutil iam ch $traffic_log_sink_writer_identity:objectCreator \
    gs://$storage_bucket

# check if a pub/sub topic exists
echo "Creating Valtix traffic log pub/sub topic: $traffic_log_topic_name"
traffic_log_topic_id=$(gcloud pubsub topics describe $traffic_log_topic_name --format=json 2>/dev/null | jq -r .name)
if [ "$traffic_log_topic_id" != "" ]; then
    echo "Valtix traffic log pub/sub topic already exists, Skipping"
else
    gcloud pubsub topics create $traffic_log_topic_name
fi

echo "Creating Valtix traffic log pub/sub subscription: $traffic_log_subscription_name"
traffic_log_subscription_id=$(gcloud pubsub subscriptions describe $traffic_log_subscription_name --format=json 2>/dev/null | jq -r .name)
if [ "$traffic_log_subscription_id" != "" ]; then
     echo "Valtix traffic log pub/sub subscription already exists, Skipping"
else
    gcloud pubsub subscriptions create $traffic_log_subscription_name \
        --topic=$traffic_log_topic_name \
        --push-endpoint=$webhook_endpoint
fi

# enable cloud storage notification to traffic log topic
echo "Enabling storage bucket object change notification to be sent to traffic log topic $traffic_log_topic_name"
traffic_log_topic_id=$(gsutil notification list gs://$storage_bucket | grep $traffic_log_topic_name)
if [ "$traffic_log_topic_id" != "" ]; then
    echo "Storage bucket object change notification already enabled"
else
    gsutil notification create -t $traffic_log_topic_name -f json gs://$storage_bucket
fi

cleanup_file=delete-gcp-traffic-visibility.sh
echo "Create uninstaller script in the current directory '$cleanup_file'"
echo > $cleanup_file
for i in ${!flow_log_enabled_subnets[@]}; do
    subnet=${flow_log_enabled_subnets[$i]}
    region=${flow_log_enabled_regions[$i]}
    echo gcloud compute networks subnets update $subnet \
        --no-enable-flow-logs --region=$region >> $cleanup_file
done

echo "gcloud dns policies update ${dns_policy_name} --networks '' --no-enable-logging --quiet" >> $cleanup_file
echo "gcloud dns policies delete ${dns_policy_name} --quiet" >> $cleanup_file
echo "gcloud logging sinks delete ${traffic_log_sink_name} --quiet" >> $cleanup_file
echo "gcloud pubsub subscriptions delete ${traffic_log_subscription_name} --quiet" >> $cleanup_file
echo "gcloud pubsub topics delete ${traffic_log_topic_name} --quiet" >> $cleanup_file
echo "rm $cleanup_file" >> $cleanup_file
chmod +x $cleanup_file