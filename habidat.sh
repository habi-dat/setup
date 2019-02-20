#!/bin/bash
set +x

# general
source setup.env

red=`tput setaf 1`
green=`tput setaf 2`
yellow=`tput setaf 3`
reset=`tput sgr0`

print_done() {
	tput setaf 2
	echo "[DONE]"
	tput sgr0	
}

check_exists() {
	if [ -d "store/$1" ]
	then
		if [ "$2" ==  "force" ]
		then	
			echo "Force reinstall $1, removing old installation...."
			docker-compose -f "store/$1/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-$1"  down -v --remove-orphans
			rm -rf "store/$1"
		else
			return 1
		fi		
	fi
	return 0
}

remove_module() {
	if [ ! -d "store/$1" ]
	then
		echo "Module $1 not installed, skip removing..."
		exit 1		
	fi
	echo "Removing $1 module...."
	docker-compose -f "store/$1/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-$1"  down -v --remove-orphans
	rm -rf "store/$1"	
}

setup_module() {
	echo "Setup $1 module..."
	cd "$1"
	./setup.sh
	cp version "../store/$1"
	if [ -f dependencies ]
	then
	  cp dependencies "../store/$1"
	fi
	cd ..
	print_done		
}

check_dependencies () {

	echo "Checking dependencies for module $1..."
	if [ ! -f "$1/dependencies" ]
	then
		return
	fi
	dependencies_missing=()
	while read -r module
	do
		if [ ! -d "store/$module" ]
		then
			echo "${red}[NOT INSTALLED]${reset} $module"
			dependencies_missing+=($module)
		else
			echo "${green}[INSTALLED]${reset} $module"
		fi
	done < "$1/dependencies"
	if [ ${#dependencies_missing[@]} != "0" ]
	then

		read -p "There are missing dependencies, do you want to install them? [y/n] " -n 1 -r
		echo    
		if [[ ! $REPLY =~ ^[Yy]$ ]]
		then
			echo "Please install dependencies first, abort..."
	    	exit 1
	    else
			for setupModule in $dependencies_missing
			do
				check_dependencies $setupModule
				setup_module $setupModule
			done	    	
		fi			
	fi
}

check_child_dependecies () {

	echo "Checking child dependencies for module $1..."
	dependencies_installed="false"
	for installedModule in store/*/
	do
		dependenciesFile=$installedModule"dependencies"
		if [ -f $dependenciesFile ]
		then
			while read -r module
			do
				if [ "$module" == "$1" ]
				then
					dependency=$(basename $(dirname $dependenciesFile))
					echo "${red}[INSTALLED]${reset} $dependency"
					dependencies_installed="true"
				fi
			done < "$dependenciesFile"
		fi
	done
	if [ $dependencies_installed == "true" ]
	then
		echo "Please remove child dependencies first, abort..."
		exit 1
	fi
	
}


if [ "$1" == "setup" ]
then
	if [ -z "$2" ]
	then
		echo "Usage: setup <module>|all [force]"
		exit 1
	fi

	if [ "$3" == "force" ]
	then
		read -p "Using force option deletes all data of installed modules, are you sure? [y/n] " -n 1 -r
		echo    
		if [[ ! $REPLY =~ ^[Yy]$ ]]
		then
	    	exit 1
		fi		
	fi

	if [ $2 == "all" ]
	then
		for setupModule in "nginx" "auth" "nextcloud" "discourse" "direktkredit"
		do
			check_exists "$setupModule" "$3"
			if [ $? == "1" ] && [ "force" != "$3" ]
			then
				echo "Module $setupModule already installed, skipping..."
			else
				check_dependencies $setupModule
				setup_module $setupModule
			fi			
		done
	else
		check_exists "$2" "$3"
		if [ "$?" == "1" ] && [ "force" != "$3" ]
		then
			echo "Module $2 already installed, use force option to remove module (including data)"
			exit 1
		fi

		if [ "$2" == "nginx" ] || [ "$2" == "auth" ] || [ "$2" == "nextcloud" ] || [ "$2" == "discourse" ] || [ "$2" == "mediawiki" ] ||  [ "$2" == "direktkredit" ]
		then
			check_dependencies $2
			setup_module $2
		else 
			echo "Module $2 unknown, available modules are: nginx, auth, nextcloud, discourse, direktkredit"
		fi
	fi
elif [ "$1" == "rm" ]
then

	if [ -z "$2" ]
	then
		echo "Usage: rm <module>"
		exit 1
	fi

	if [ "$2" == "nginx" ] || [ "$2" == "auth" ] || [ "$2" == "nextcloud" ] || [ "$2" == "discourse" ] || [ "$2" == "mediawiki" ] ||  [ "$2" == "direktkredit" ]
	then
		read -p "Do you really want to remove module $2 (all data will be lost) [y/n] " -n 1 -r
		echo    
		if [[ ! $REPLY =~ ^[Yy]$ ]]
		then
		    exit 1
		fi		
		check_child_dependecies $2
		remove_module $2
	else 
		echo "Module $2 unknown, available modules are: nginx, auth, nextcloud, discourse, direktkredit"
	fi
elif [ "$1" == "modules" ]
then
	for module in "nginx" "auth" "nextcloud" "discourse" "direktkredit"
	do
		if [ -d "store/$module" ]
		then
			echo "${green}[INSTALLED]${reset} $module"
		else
			echo "${yellow}[NOT INSTALLED]${reset} $module"
		fi	
	done
else
	echo "Usage: setup|rm|modules"
fi

