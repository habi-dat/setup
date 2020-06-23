#!/bin/bash
set +x

../store/discourse/launcher stop $HABIDAT_DOCKER_PREFIX-discourse-data
../store/discourse/launcher stop $HABIDAT_DOCKER_PREFIX-discourse