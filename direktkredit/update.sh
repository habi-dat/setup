#!/bin/bash
set -e

source ../store/nginx/networks.env
source ../store/auth/passwords.env

envsubst < docker-compose.yml > ../store/direktkredit/docker-compose.yml

echo "Pulling images and recreate containers (for all projects)..."

cd ../store/direktkredit
git pull
./update-projects.sh all
./update-projects.sh nginx
cd ../../direktkredit
