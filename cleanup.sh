#!/bin/bash

# Shell script to clean up resources
resources=~/resources.json

VPC=$( jq -r '."VPC-ID"' $resources )