#!/bin/sh

pipeline="$1"

[ -z "$pipeline" ] && echo "Usage: $0 <pipeline-id>" && exit 1

project=2
url="https://gitlab.spack.io/api/v4/projects/$project"

bridges_url="$url/pipelines/$pipeline/bridges?per_page=100"

# Obtain the child pipeline ids
child_pipelines=$(curl -LfsS "$bridges_url" | jq -r '.[].downstream_pipeline.id')

fetch_pipeline() {
    jobs_url="$url/pipelines/$1/jobs"
    per_page=100
    page=1

    while true; do
        file="jobs-$project-$1-$page.json"
        # Fetch if the file doesn't exist
        fetch_url="$jobs_url?include_retried=true&per_page=$per_page&page=$page"
        [ -f "$file" ] || curl -LfsS "$fetch_url"  -o "$file" || break
        jq -e "length < $per_page" "$file" > /dev/null && break
        page=$((page + 1))
    done
}

echo "Fetching main pipeline"
fetch_pipeline "$pipeline"

for child_pipeline in $child_pipelines; do
    echo "Fetching pipeline $child_pipeline"
    fetch_pipeline "$child_pipeline"
done

# Finally output as trace.json
jq \
'map(['\
'select(.started_at and .finished_at) | '\
'{name: (.name), cat: "PERF", ph: "B", pid: .pipeline.id, tid: .id, ts: (.started_at | sub("\\.[0-9]+Z$"; "Z") | fromdate * 10e5)},'\
'{name: (.name), cat: "PERF", ph: "E", pid: .pipeline.id, tid: .id, ts: (.finished_at | sub("\\.[0-9]+Z$"; "Z") | fromdate * 10e5)}'\
']) | flatten(1) | .[]' jobs-$project-*.json | jq -s > trace.json

echo $(realpath trace.json)
