#!/bin/bash

echo "Destroying discourse containers..."

../store/discourse/launcher destroy $HABIDAT_DOCKER_PREFIX-discourse-data
../store/discourse/launcher destroy $HABIDAT_DOCKER_PREFIX-discourse

echo "Deleting discourse volumes..."
docker volume rm $HABIDAT_DOCKER_PREFIX-discourse_data
docker volume rm $HABIDAT_DOCKER_PREFIX-discourse

rm -rf ../store/discourse

sleep 5