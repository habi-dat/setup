#!/bin/bash
set +x

../store/discourse/launcher start $HABIDAT_DOCKER_PREFIX-discourse-data
../store/discourse/launcher start $HABIDAT_DOCKER_PREFIX-discourse