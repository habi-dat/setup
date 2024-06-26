#!/bin/bash
set +x

# general
if [ -f ./setup.env ]
then
	source setup.env
fi

red=`tput setaf 1`
green=`tput setaf 2`
yellow=`tput setaf 3`
magenta=`tput setaf 5`
bold=`tput bold` 
reset=`tput sgr0`

usage() {
    prefix "Usage: habidat.sh ${txtunderline}COMMAND${txtreset}"
    prefix
    prefix "Commands:"
    prefix "  help                                           show help."
    prefix "  install <module>|all [force]                   install module or all modules"
    prefix "  remove  <module>                               remove module (caution: all module data is lost)"
    prefix "  start   <module>|all                           start module or all modules"
    prefix "  restart <module>|all                           restart module or all modules"
    prefix "  stop    <module>|all                           stop module or all modules"
    prefix "  up      <module>|all                           [experimental!] up module or all modules (start and/or create containers)"
    prefix "  down    <module>|all                           [experimental!]down module or all modules (stop and remove containers)"
    prefix "  update  <module>|all                           update module or all modules"
    prefix "  pull    <module>|all                           pull module or all modules"
    prefix "  build   <module>|all                           [experimental!] build module or all modules (only if you changed the compose files to build images)"
    prefix "  export  <module>|all [options]                 export module data"    
    prefix "  import  <module>|all <filename>|list           import module data or list available filenames"    
    prefix "  modules                                        list module status"
    prefix
}

upper() {
    echo -n "$1" | tr '[a-z]' '[A-Z]'
}

prefixm() {
	local p=`echo -n "$1" | tr '[a-z]' '[A-Z]'`
	p="$p                                               "
	p="${p:0:12}"
	p="${magenta}${bold}$p${reset}| "	
	local c="s/^/$p/"	
	sed -u -l 1 "$c"	
#	while read line
	#do 
		
		#echo
	#done	 
}

prefix() {
	local p="$HABIDAT_TITLE                              "
	p="${p:0:12}"
	p="${green}${bold}$p${reset}| "
	local c="s/^/$p/"
    echo $1 | sed -u "$c"	
}

prefixr() {
	local p="$HABIDAT_TITLE                              "
	p="${p:0:12}"
	p="${red}${bold}$p${reset}| "
	local c="s/^/$p/"
	echo $1 | sed -u "$c"	

}

print_done() {
	prefix "DONE"
}

update_installed_modules() {
	if [ -d "store/auth" ]
	then
		HABIDAT_USER_INSTALLED_MODULES="nginx,auth"
		if [ -d "store/nextcloud" ]
		then
  			HABIDAT_USER_INSTALLED_MODULES="$HABIDAT_USER_INSTALLED_MODULES,nextcloud"
		fi
		if [ -d "store/discourse" ]
		then
  			HABIDAT_USER_INSTALLED_MODULES="$HABIDAT_USER_INSTALLED_MODULES,discourse"
		fi
		if [ -d "store/direktkredit" ]
		then
  			HABIDAT_USER_INSTALLED_MODULES="$HABIDAT_USER_INSTALLED_MODULES,direktkredit"
		fi
		if [ -d "store/dokuwiki" ]
		then
  			HABIDAT_USER_INSTALLED_MODULES="$HABIDAT_USER_INSTALLED_MODULES,dokuwiki"
		fi
		if [ -d "store/mediawiki" ]
		then
  			HABIDAT_USER_INSTALLED_MODULES="$HABIDAT_USER_INSTALLED_MODULES,mediawiki"
		fi
		if [ -d "store/mailtrain" ]
		then
  			HABIDAT_USER_INSTALLED_MODULES="$HABIDAT_USER_INSTALLED_MODULES,mailtrain"
		fi
		sed -i '/HABIDAT_USER_INSTALLED_MODULES/d' store/auth/user.env
		echo "HABIDAT_USER_INSTALLED_MODULES=$HABIDAT_USER_INSTALLED_MODULES" >> store/auth/user.env		
		#docker compose -f store/auth/docker-compose.yml -p $HABIDAT_DOCKER_PREFIX-auth up -d user
	fi
}

check_exists() {
	if [ -d "store/$1" ]
	then
		if [ "$2" ==  "force" ]
		then	
			prefix "Force reinstall $1, removing old installation...." 
			bash -c "docker compose -f store/$1/docker-compose.yml -p $HABIDAT_DOCKER_PREFIX-$1  down -v --remove-orphans" | prefixm "$1"
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
		prefix "Module $1 not installed, skip removing..."
		exit 1		
	fi
	prefix "Removing $1 module...."
	if [ -f "$1/remove.sh" ]
	then
		cd $1
		./remove.sh ${@:2} | prefixm $1
		cd ..
	else
		docker compose -f "store/$1/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-$1"  down -v --remove-orphans | prefixm "$1"		
   		rm -rf "store/$1"	
	fi
    update_installed_modules		
}

start_module() {
	if [ ! -d "store/$1" ]
	then
		prefix "Module $1 not installed, skip starting..."
		return 0	
	fi

	prefix "Starting $1 module...."
	if [ -f "$1/start.sh" ]
	then
		cd $1
		./start.sh | prefixm $1
		cd ..
	else
		docker compose -f "store/$1/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-$1"  start | prefixm "$1"
	fi
}

restart_module() {
	if [ ! -d "store/$1" ]
	then
		prefix "Module $1 not installed, skip restarting..."
		return 0	
	fi

	prefix "Restarting $1 module...."
	if [ -f "$1/restart.sh" ]
	then
		cd $1
		./restart.sh | prefixm $1
		cd ..
	else
		docker compose -f "store/$1/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-$1"  restart | prefixm "$1"
	fi	
}

stop_module() {
	if [ ! -d "store/$1" ]
	then
		prefix "Module $1 not installed, skip stopping..."
		return 0	
	fi

	prefix "Stopping $1 module...."
	if [ -f "$1/stop.sh" ]
	then
		cd $1
		./stop.sh | prefixm $1
		cd ..
	else
		docker compose -f "store/$1/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-$1"  stop | prefixm "$1"
	fi			
}

down_module() {
	if [ ! -d "store/$1" ]
	then
		prefix "Module $1 not installed, skip downing..."
		return 0	
	fi

	prefix "Downing $1 module...."
	if [ -f "$1/down.sh" ]
	then
		cd $1
		./down.sh | prefixm $1
		cd ..
	else
		docker compose -f "store/$1/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-$1"  down | prefixm "$1"
	fi			
}

up_module() {
	if [ ! -d "store/$1" ]
	then
		prefix "Module $1 not installed, skip upping..."
		return 0	
	fi

	prefix "Upping $1 module...."
	if [ -f "$1/up.sh" ]
	then
		cd "$1"
		./up.sh | prefixm $1		
		cd ..
	else
		docker compose -f "store/$1/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-$1"  up -d | prefixm "$1"
    fi
}

pull_module() {
	if [ ! -d "store/$1" ]
	then
		prefix "Module $1 not installed, skip pulling..."
		return 0	
	fi

	prefix "Pulling $1 module...."
	if [ -f "$1/pull.sh" ]
	then
		cd "$1"
		./pull.sh | prefixm $1		
		cd ..
	else
		docker compose -f "store/$1/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-$1"  pull | prefixm "$1"
    fi	
	
}

build_module() {
	if [ ! -d "store/$1" ]
	then
		prefix "Module $1 not installed, skip building..."
		return 0	
	fi

	prefix "Building $1 module...."
	if [ -f "$1/build.sh" ]
	then
		cd "$1"
		./build.sh | prefixm $1		
		cd ..
	else
		docker compose -f "store/$1/docker-compose.yml" -p "$HABIDAT_DOCKER_PREFIX-$1"  build | prefixm "$1"
    fi		
	
}

setup_module() {
	prefix "Setup $1 module..."
	cd "$1"
	./setup.sh ${@:2} | prefixm $1
	cp version "../store/$1"
	if [ -f dependencies ]
	then
	  cp dependencies "../store/$1"
	fi
	cd ..
    update_installed_modules	
	print_done		
}

update_module() {
	if [ "$1" == "nginx" ] || [ "$1" == "auth" ] || [ "$1" == "nextcloud" ] || [ "$1" == "discourse" ] || [ "$1" == "mediawiki" ] || [ "$1" == "dokuwiki" ] ||  [ "$1" == "direktkredit" ] ||  [ "$1" == "mailtrain" ]	
	then
		if [ ! -d "store/$1" ]
		then
			prefixr "Module $1 not installed, cannot update"
			return 0
		fi		
		versionInstalled=$(cat store/$1/version)
		versionSetup=$(cat $1/version)

		if [ -z "$versionSetup" ] && [ "$2" != "force" ]
		then
			prefixr "Module $1: Setup version not found, cannot update, use force option to update anyway"
			return 1
		elif [ -z "$versionInstalled" ] && [ "$2" != "force" ]
		then
			prefixr "Module $1: Installed version not found, cannot update. Use force option to update anyway"
			return 1			
		elif [ "$versionSetup" == "$versionInstalled" ] && [ "$2" != "force" ]
		then
			prefix "Module $1 is up to date, version $versionInstalled, use force option to update anyway"
			return 0
		elif [ "v$versionSetup" < "v$versionInstalled" ] && [ "$2" != "force" ]
		then
			prefixr "Module $1: installed version $versionInstalled is higher than setup version $versionSetup, downgrad not possible. Use force option to update anyway"
			return 1
		else
			if [ ! -f "$1/update.sh" ]
			then
				prefixr "Module $1 has no update.sh script, cannot update"
				return 1
			fi

			prefix "Updating module $1 from $versionInstalled to $versionSetup..."
			cd "$1"
			if [ "$2" == "force" ]
			then
			  ./update.sh ${@:3} | prefixm $1
			else
			  ./update.sh ${@:2} | prefixm $1
			fi
			cp version "../store/$1"
			cd ..
			print_done
		fi
	else
		prefixr "Module $1 unknown, available modules are: nginx, auth, nextcloud, discourse, mediawiki, dokuwiki, direktkredit, mailtrain"
		return 1
	fi
}

export_module() {
	if [ "$1" == "nginx" ] || [ "$1" == "auth" ] || [ "$1" == "nextcloud" ] || [ "$1" == "discourse" ] || [ "$1" == "mediawiki" ] || [ "$1" == "dokuwiki" ] ||  [ "$1" == "direktkredit" ] ||  [ "$1" == "mailtrain" ]		
	then
		if [ ! -d "store/$1" ]
		then
			prefixr "Module $1 not installed, cannot export"
			return 0
		fi

		if [ ! -f "$1/export.sh" ]
		then
			prefixr "Module $1 has no export.sh script, cannot export"
			return 0
		fi		
		
		cd "$1"
		./export.sh $2 | prefixm $1
		cd ..
		print_done

	else
		prefixr "Module $1 unknown, available modules are: nginx, auth, nextcloud, discourse, mediawiki, dokuwiki, direktkredit, mailtrain"
		return 1
	fi
}


import_module() {
	if [ "$1" == "nginx" ] || [ "$1" == "auth" ] || [ "$1" == "nextcloud" ] || [ "$1" == "discourse" ] || [ "$1" == "mediawiki" ] || [ "$1" == "dokuwiki" ] ||  [ "$1" == "direktkredit" ] ||  [ "$1" == "mailtrain" ]		
	then
		if [ ! -d "store/$1" ]
		then
			prefixr "Module $1 not installed, cannot export"
			return 0
		fi

		if [ ! -f "$1/import.sh" ]
		then
			prefixr "Module $1 has no import.sh script, cannot import"
			return 0
		fi		

		if [ "$2" == "list" ]; then
			echo "Listing available filenames for import"
			ls -ltr $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/$1
			return 0
		else
			if [ ! -f $HABIDAT_BACKUP_DIR/$HABIDAT_DOCKER_PREFIX/$1/$2 ]; then
				echo "Import file $2 not found"
				return 0
			fi
			cd "$1"
			./import.sh $2 | prefixm $1
			cd ..
			print_done
		fi		

	else
		prefixr "Module $1 unknown, available modules are: nginx, auth, nextcloud, discourse, mediawiki, dokuwiki, direktkredit, mailtrain"
		return 1
	fi
}

check_dependencies () {

	prefix "Checking dependencies for module $1..."
	if [ ! -f "$1/dependencies" ]
	then
		return
	fi

	while read -r module
	do
		if [ ! -d "store/$module" ]
		then
			prefix "$module ${red}[NOT INSTALLED]${reset}"
			dependencies_missing+=" "$module
		else
			prefix "$module ${green}[INSTALLED]${reset}"
		fi
	done < "$1/dependencies"
	
	if [ ! -z "$dependencies_missing" ]
	then

		read -p "There are missing dependencies, do you want to install them? [y/n] " -n 1 -r
		echo
		if [[ ! $REPLY =~ ^[Yy]$ ]]
		then
			prefixr "Please install dependencies first, abort..."
	    	exit 1
	    else
			for setupModule in $dependencies_missing
			do
				dependencies_missing=""
				check_dependencies $setupModule
				setup_module $setupModule
			done	    	
		fi			
	fi
}

check_child_dependecies () {

	prefix "Checking child dependencies for module $1..."
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
					echo "$dependency ${red}[INSTALLED]${reset}"
					dependencies_installed="true"
				fi
			done < "$dependenciesFile"
		fi
	done
	if [ $dependencies_installed == "true" ]
	then
		prefix "Please remove child dependencies first, abort..."
		exit 1
	fi
	
}

print_admin_credentials() {
	if [ -f store/auth/passwords.env ]
	then
		source store/auth/passwords.env
		prefix "habi*DAT admin credentials: username is ${bold}admin${reset}, password is ${bold}$HABIDAT_ADMIN_PASSWORD${reset}"
	fi
}

if [ "$1" == "install" ]
then
	if [ -z "$2" ]
	then
		usage
		exit 1
	fi

	if [ $2 == "all" ]
	then
		for setupModule in "nginx" "auth" "nextcloud" "discourse" "dokuwiki" "direktkredit" "mailtrain"
		do
			check_exists "$setupModule" "$3"
			if [ $? == "1" ] && [ "force" != "$3" ]
			then
				prefix "Module $setupModule already installed, skipping..."
			else
				check_dependencies $setupModule
				setup_module $setupModule 
			fi			
		done
		print_admin_credentials
	else
		check_exists "$2" "$3"
		if [ "$?" == "1" ] && [ "$2" != "mediawiki" ]
		then
			prefixr "Module $2 already installed, update module or remove module first"
			exit 1
		fi

		if [ "$2" == "nginx" ] || [ "$2" == "auth" ] || [ "$2" == "nextcloud" ] || [ "$2" == "discourse" ] || [ "$2" == "mediawiki" ] || [ "$2" == "dokuwiki" ] ||  [ "$2" == "direktkredit" ] ||  [ "$2" == "mailtrain" ]	
		then
			check_dependencies $2
			setup_module ${@:2}
			print_admin_credentials
		else 
			prefixr "Module $2 unknown, available modules are: nginx, auth, nextcloud, discourse, mediawiki, dokuwiki, direktkredit, mailtrain"
			exit 1
		fi
	fi

elif [ "$1" == "rm" ]
then

	if [ -z "$2" ]
	then
		usage
		exit 1
	fi

	if [ "$2" == "nginx" ] || [ "$2" == "auth" ] || [ "$2" == "nextcloud" ] || [ "$2" == "discourse" ] || [ "$2" == "mediawiki" ] || [ "$2" == "dokuwiki" ] ||  [ "$2" == "direktkredit" ] ||  [ "$2" == "mailtrain" ]	
	then
		read -p "Do you really want to remove module $2 (all data will be lost) [y/n] " -n 1 -r
		echo    
		if [[ ! $REPLY =~ ^[Yy]$ ]]
		then
		    exit 1
		fi		
		check_child_dependecies $2
		remove_module ${@:2}
	else 
		prefixr "Module $2 unknown, available modules are: nginx, auth, nextcloud, discourse, mediawiki, dokuwiki, direktkredit, mailtrain"
	fi
elif [ "$1" == "modules" ]
then
	for module in "nginx" "auth" "nextcloud" "discourse" "mediawiki" "dokuwiki" "direktkredit" "mailtrain"
	do
		if [ -d "store/$module" ]
		then
			prefix "$module ${green}[INSTALLED]${reset}"
		else
			prefix "$module ${yellow}[NOT INSTALLED]${reset}"
		fi	
	done
elif [ "$1" == "update" ]
then
	if [ -z "$2" ]
	then
		usage
		exit 1
	elif [ "$2" == "all" ]
	then
		for updateModule in "nginx" "auth" "nextcloud" "discourse" "mediawiki" "dokuwiki" "direktkredit" "mailtrain"
		do
			update_module $updateModule ${@:3}
		done
	else
		update_module ${@:2}
	fi
elif [ "$1" == "start" ]
then
	if [ -z "$2" ]
	then
		usage
		exit 1
	elif [ "$2" == "all" ]
	then
		for mod in "nginx" "auth" "nextcloud" "discourse" "mediawiki" "dokuwiki" "direktkredit" "mailtrain"
		do
			start_module $mod
		done
	else
		start_module $2
	fi
elif [ "$1" == "build" ]
then
	if [ -z "$2" ]
	then
		usage
		exit 1
	elif [ "$2" == "all" ]
	then
		for mod in "nginx" "auth" "nextcloud" "discourse" "mediawiki" "dokuwiki" "direktkredit" "mailtrain"
		do
			build_module $mod
		done
	else
		build_module $2
	fi	
elif [ "$1" == "restart" ]
then
	if [ -z "$2" ]
	then
		usage
		exit 1
	elif [ "$2" == "all" ]
	then
		for mod in "nginx" "auth" "nextcloud" "discourse" "mediawiki" "dokuwiki" "direktkredit" "mailtrain"
		do
			restart_module $mod
		done
	else
		restart_module $2
	fi
elif [ "$1" == "stop" ]
then
	if [ -z "$2" ]
	then
		usage
		exit 1
	elif [ "$2" == "all" ]
	then
		for mod in "nginx" "auth" "nextcloud" "discourse" "mediawiki" "dokuwiki" "direktkredit" "mailtrain"
		do
			stop_module $mod
		done
	else
		stop_module $2
	fi
elif [ "$1" == "down" ]
then
	if [ -z "$2" ]
	then
		usage
		exit 1
	elif [ "$2" == "all" ]
	then
		for mod in "nginx" "auth" "nextcloud" "discourse" "mediawiki" "dokuwiki" "direktkredit" "mailtrain"
		do
			down_module $mod
		done
	else
		down_module $2
	fi	
elif [ "$1" == "up" ]
then
	if [ -z "$2" ]
	then
		usage
		exit 1
	elif [ "$2" == "all" ]
	then
		for mod in "nginx" "auth" "nextcloud" "discourse" "mediawiki" "dokuwiki" "direktkredit" "mailtrain"
		do
			up_module $mod
		done
	else
		up_module $2
	fi		
elif [ "$1" == "pull" ]
then
	if [ -z "$2" ]
	then
		usage
		exit 1
	elif [ "$2" == "all" ]
	then
		for mod in "nginx" "auth" "nextcloud" "discourse" "mediawiki" "dokuwiki" "direktkredit" "mailtrain"
		do
			pull_module $mod
		done
	else
		pull_module $2
	fi		
elif [ "$1" == "export" ]
then
	if [ -z "$2" ]
	then
		usage
		exit 1
	elif [ "$2" == "all" ]
	then
		for exportModule in "nginx" "auth" "nextcloud" "discourse" "mediawiki" "dokuwiki" "direktkredit" "mailtrain"
		do
			export_module $exportModule $3
		done
	else
		export_module $2 $3
	fi	
elif [ "$1" == "import" ]
then
	if [ $# -ne 3 ]
	then
		usage
		exit 1
	elif [ "$2" == "all" ]
	then
		echo "Import can only be done per module"
		exit 1
	else
		import_module $2 $3
	fi	
elif [ "$1" == "help" ]
then
	usage
	exit 0
else
	usage
	exit 1	
fi

