#!/bin/bash

#!/bin/bash

if [[ $# -eq 1 ]] 
then
	echo "Starting mediawiki $1 instance..."

    docker-compose -f ../store/mediawiki/$1/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$1" start

else
	echo "Starting all mediawiki instances..."

	for dir in ../store/mediawiki/*/  # list directories 
	do
	    dir=${dir%*/}      # remove the trailing "/"    
	    id=${dir##*/}

		echo "Updating mediawiki $id instance..."
	    docker-compose -f ../store/mediawiki/$id/docker-compose.yml -p "$HABIDAT_DOCKER_PREFIX-mediawiki-$id" start
	done
fi
