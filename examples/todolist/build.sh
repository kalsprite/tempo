#!/bin/bash
set -e

cd "$(dirname "$0")"

# Generate templates
TEMPO="${TEMPO:-../../tempo}"
$TEMPO generate ./views -runtime=../../../runtime

# Build and run
odin run . -out:todolist

echo "Open index.html in your browser"
