#!/bin/bash
set +x

../store/discourse/launcher restart $HABIDAT_DOCKER_PREFIX-discourse-data
../store/discourse/launcher restart $HABIDAT_DOCKER_PREFIX-discourse