#!/bin/bash


if [[ $# -eq 1 ]] 
then
	echo "Destroying containers and volumes for $1 instance..."

    docker-compose -f ../store/mediawiki/$1/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$1" down -v --remove-orphans
    rm -r -r ../store/mediawiki/$1

else
	echo "Destroying containers and volumes for all instances..."

	for dir in ../store/mediawiki/*/  # list directories 
	do
	    dir=${dir%*/}      # remove the trailing "/"    
	    id=${dir##*/}

	    docker-compose -f ../store/mediawiki/$id/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$id" down -v --remove-orphans
	    rm -r -r ../store/mediawiki/$id
	done

	rm -r ../store/mediawiki
fi
