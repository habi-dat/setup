#!/bin/bash
set +x

EXTERNAL_SITES_TEMPLATE='{"%s":{"icon":"%s","lang":"","type":"link","device":"","id":"%s","name":"%s","url":"%s"}}'
EXTERNAL_SITES_TEMPLATE_REDIRECT='{"%s":{"icon":"%s","lang":"","type":"link","device":"","id":"%s","name":"%s","url":"%s", "redirect":true}}'
EXTERNAL_SITES=$(php occ config:app:get external sites)
echo $EXTERNAL_SITES
NEW_EXTERNAL_SITE=""
if [ -z "$EXTERNAL_SITES" ]
then
	EXTERNAL_SITES='{}'
fi
INDEX=$(echo $EXTERNAL_SITES | jq 'keys | length + 1')

if [ "$1" == "discourse" ] && [ ! -z $HABIDAT_DISCOURSE_SUBDOMAIN ]
then
	NEW_EXTERNAL_SITE=$(printf "$EXTERNAL_SITES_TEMPLATE_REDIRECT" "$INDEX" "discourse.ico" "$INDEX" "Discourse" "$HABIDAT_PROTOCOL://$HABIDAT_DISCOURSE_SUBDOMAIN.$HABIDAT_DOMAIN")
elif [ "$1" == "mediawiki" ] && [ ! -z $HABIDAT_MEDIAWIKI_SUBDOMAIN ] 
then
	NEW_EXTERNAL_SITE+=$(printf "$EXTERNAL_SITES_TEMPLATE" "$INDEX" "wiki.png" "$INDEX" "Mediawiki" "$HABIDAT_PROTOCOL://$HABIDAT_MEDIAWIKI_SUBDOMAIN.$HABIDAT_DOMAIN")
elif [ "$1" == "dokuwiki" ] && [ ! -z $HABIDAT_DOKUWIKI_SUBDOMAIN ] 
then
	NEW_EXTERNAL_SITE+=$(printf "$EXTERNAL_SITES_TEMPLATE" "$INDEX" "wiki.png" "$INDEX" "Dokuwiki" "$HABIDAT_PROTOCOL://$HABIDAT_DOKUWIKI_SUBDOMAIN.$HABIDAT_DOMAIN")
elif [ "$1" == "user" ] && [ ! -z $HABIDAT_USER_SUBDOMAIN ] 
then
	NEW_EXTERNAL_SITE+=$(printf "$EXTERNAL_SITES_TEMPLATE" "$INDEX" "user.png" "$INDEX" "User*innen" "$HABIDAT_PROTOCOL://$HABIDAT_USER_SUBDOMAIN.$HABIDAT_DOMAIN")
elif [ "$1" == "direktkredit" ] && [ ! -z $HABIDAT_DIREKTKREDIT_SUBDOMAIN ] 
then
	NEW_EXTERNAL_SITE+=$(printf "$EXTERNAL_SITES_TEMPLATE" "$INDEX" "direktkredite.png" "$INDEX" "Direktkredite" "$HABIDAT_PROTOCOL://$HABIDAT_DIREKTKREDIT_SUBDOMAIN.$HABIDAT_DOMAIN")
elif [ "$1" == "mailtrain" ] && [ ! -z $HABIDAT_MAILTRAIN_SUBDOMAIN ] 
then
	NEW_EXTERNAL_SITE+=$(printf "$EXTERNAL_SITES_TEMPLATE" "$INDEX" "newsletter.png" "$INDEX" "Newsletter" "$HABIDAT_PROTOCOL://$HABIDAT_MAILTRAIN_SUBDOMAIN.$HABIDAT_DOMAIN")
fi

if [ ! -z "$NEW_EXTERNAL_SITE" ]
then
	EXTERNAL_SITES=$(echo $EXTERNAL_SITES | jq -c ". + $NEW_EXTERNAL_SITE")
	php occ config:app:set external sites --value "$EXTERNAL_SITES"
fi