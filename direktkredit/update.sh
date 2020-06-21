#!/bin/bash
set -e

source ../store/nginx/networks.env
source ../store/auth/passwords.env
source ../store/direktkredit/passwords.env

envsubst < docker-compose.yml > ../store/direktkredit/docker-compose.yml

echo "Pulling images and recreate containers (for all projects)..."

cd ../store/direktkredit
./update-projects.sh all
./update-projects.sh nginx
cd ../../direktkredit
