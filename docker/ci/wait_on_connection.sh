#!/bin/bash

set -e

host=$1
port=$2

echo "Waiting for $host:$port..."
until nc -z $host $port;
do
    sleep 1
done
echo "$host:$port is available"

# If this is Elasticsearch, also wait for cluster health
if [ "$port" = "9200" ]; then
    echo "Waiting for Elasticsearch cluster health..."
    until curl -sf "http://$host:$port/_cluster/health?wait_for_status=yellow&timeout=30s" > /dev/null 2>&1;
    do
        sleep 2
    done
    echo "Elasticsearch cluster is ready"
fi
