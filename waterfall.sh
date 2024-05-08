#!/bin/sh

pipeline="$1"

[ -z "$pipeline" ] && echo "Usage: $0 <pipeline url>" && exit 1

# https://gitlab.spack.io/spack/spack/-/pipelines/698256

base_url=$(echo "$pipeline" | awk -F/ '{print $1 "//" $2 $3 "/"}')
project=$(echo "$pipeline" | awk -F/ '{print $4 "%2F" $5}')
pipeline=$(echo "$pipeline" | awk -F/ '{print $8}')

url="$base_url/api/v4/projects/$project"

bridges_url="$url/pipelines/$pipeline/bridges?per_page=100"

# Obtain the child pipeline ids
child_pipelines=$(curl -LfsS "$bridges_url" | jq -r '.[].downstream_pipeline.id')

fetch_jobs() {
    jobs_url="$url/pipelines/$1/jobs"
    per_page=100
    page=1
    batch=8

    while true; do
        curl --parallel --parallel-immediate -LfsS "$jobs_url?include_retried=true&per_page=$per_page&page=[$page-$((page + batch - 1))]" -o "jobs-$1-#1.json"
        jq -e "length < $per_page" "jobs-$1-$((page + batch - 1)).json" > /dev/null && break
        page=$((page + batch))
    done
}

echo "Fetching main pipeline"
fetch_jobs "$pipeline"

for child_pipeline in $child_pipelines; do
    echo "Fetching pipeline $child_pipeline"
    fetch_jobs "$child_pipeline"
done

# Finally output as trace.json
jq \
'map(['\
'select(.started_at and .finished_at) | '\
'{name: (.name), cat: "PERF", ph: "B", pid: .pipeline.id, tid: .id, ts: (.started_at | sub("\\.[0-9]+Z$"; "Z") | fromdate * 10e5)},'\
'{name: (.name), cat: "PERF", ph: "E", pid: .pipeline.id, tid: .id, ts: (.finished_at | sub("\\.[0-9]+Z$"; "Z") | fromdate * 10e5)}'\
']) | flatten(1) | .[]' jobs-*.json | jq -s > trace_.json

python3 - <<EOF
import json
from typing import Dict, List, Tuple
from collections import defaultdict

data = json.load(open("trace_.json"))
data.sort(key=lambda x: (x["ts"], x["ph"] == "E"))
processes: Dict[str, List[List[dict]]] = defaultdict(list)
new_thread_id: Dict[Tuple[str, str], int] = {}

def event_id(event):
    return (event["pid"], event["tid"])

for event in data:
    process = processes[event["pid"]]

    if event["ph"] == "B":
        event_key = event_id(event)
        for i, events in enumerate(process):
            if events[-1]["ph"] == "E" and events[-1]["ts"] <= event["ts"]:
                events.append(event)
                event["tid"] = i
                new_thread_id[event_key] = i
                break
        else:
            process.append([event])
            event["tid"] = len(process) - 1
            new_thread_id[event_key] = len(process) - 1
    elif event["ph"] == "E":
        event["tid"] = new_thread_id[event_id(event)]
        process[event["tid"]].append(event)

new_processes = [event for process in processes.values() for events in process for event in events]

json.dump(new_processes, open("trace.json", "w"))
EOF

realpath trace.json
