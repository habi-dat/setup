#!/bin/bash
set +x

echo "[HABIDAT] Installing Nextcloud..."
php occ maintenance:install -n --database "mysql" --database-host "$HABIDAT_DOCKER_PREFIX-nextcloud-db" --database-name "nextcloud"  --database-user "nextcloud" --database-pass "$HABIDAT_MYSQL_PASSWORD" --admin-user "$HABIDAT_ADMIN_USER" --admin-pass "$HABIDAT_ADMIN_PASSWORD"

sed -i "/);/i \
'overwriteprotocol' => 'https'," /var/www/html/config/config.php

#install and configure nextcloud
echo "[HABIDAT] Configuring Nextcloud..."
php occ config:system:set -n trusted_domains 2 --value="$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN"
php occ config:system:set -n trusted_domains 3 --value="$HABIDAT_DOCKER_PREFIX-nextcloud"
php occ config:system:set -n default_language --value=de
php occ config:system:set -n force_language --value=de
php occ config:system:set -n lost_password_link --value="$HABIDAT_PROTOCOL://$HABIDAT_USER_SUBDOMAIN.$HABIDAT_DOMAIN/lostpasswd"

#install calendar
echo "[HABIDAT] Installing Calendar..."
php occ app:install -n calendar
php occ app:enable -n calendar

#add discourse icon and external site
echo "[HABIDAT] Installing External Sites..."
php occ app:install -n external
php occ app:enable -n external

APPDATA_DIR=$(find /var/www/html/data/ -type d -regex "/var/www/html/data/appdata[^/]*" | tr -d "\r" | head -n1)

mkdir -p "$APPDATA_DIR/external/icons/"
cp /habidat/icons/* "$APPDATA_DIR/external/icons/"

#theming
echo "[HABIDAT] Theming..."
mkdir -p "$APPDATA_DIR/theming/images"
cp /habidat/images/logo "$APPDATA_DIR/theming/images"
cp /habidat/images/background "$APPDATA_DIR/theming/images"
php occ config:app:set -n theming color --value="#A40023"
php occ config:app:set -n theming name --value="$HABIDAT_TITLE"
php occ config:app:set -n theming url --value="$HABIDAT_PROTOCOL://$HABIDAT_DOMAIN"
php occ config:app:set -n theming slogan --value="$HABIDAT_DESCRIPTION"
php occ config:app:set -n theming backgroudMime --value="image/jpeg"
php occ config:app:set -n theming logoMime --value="image/png"
php occ maintenance:theme:update -n

#install and configre antivirus
echo "[HABIDAT] Setting up antivirus..."
php occ app:install -n files_antivirus
php occ app:enable -n files_antivirus
php occ config:app:set -n files_antivirus av_mode --value="daemon"
php occ config:app:set -n files_antivirus av_host --value="$HABIDAT_DOCKER_PREFIX-nextcloud-antivirus"
php occ config:app:set -n files_antivirus av_infected_action --value="only_log"
php occ config:app:set -n files_antivirus av_port --value="3310"


php occ app:install -n discoursesso
php occ app:enable -n discoursesso
php occ config:app:set -n discoursesso clientsecret --value="$HABIDAT_DISCOURSE_SSO_SECRET"
php occ config:app:set -n discoursesso clienturl --value="$HABIDAT_PROTOCOL://$HABIDAT_DISCOURSE_SUBDOMAIN.$HABIDAT_DOMAIN"


#setup ldap
echo "[HABIDAT] Setting up LDAP..."
php occ app:enable -n user_ldap
php occ ldap:create-empty-config -n
php occ ldap:set-config -n s01 ldapHost "$HABIDAT_DOCKER_PREFIX-ldap"
php occ ldap:set-config -n s01 ldapPort 389
php occ ldap:set-config -n s01 ldapLoginFilter "(&(objectclass=inetOrgPerson)(|(uid=%uid)(|(cn=%uid)(mail=%uid))))"
php occ ldap:set-config -n s01 ldapAttributesForUserSearch "uid;cn"
php occ ldap:set-config -n s01 hasMemberOfFilterSupport 1
php occ ldap:set-config -n s01 lastJpegPhotoLookup 0
php occ ldap:set-config -n s01 ldapAgentName "cn=admin,$HABIDAT_LDAP_BASE"
php occ ldap:set-config -n s01 ldapAgentPassword "$HABIDAT_LDAP_ADMIN_PASSWORD"
php occ ldap:set-config -n s01 ldapBase "$HABIDAT_LDAP_BASE"
php occ ldap:set-config -n s01 ldapBaseGroups "ou=groups,$HABIDAT_LDAP_BASE"
php occ ldap:set-config -n s01 ldapBaseUsers "ou=users,$HABIDAT_LDAP_BASE"
php occ ldap:set-config -n s01 ldapCacheTTL 120
php occ ldap:set-config -n s01 ldapConfigurationActive 1
php occ ldap:set-config -n s01 ldapEmailAttribute mail
php occ ldap:set-config -n s01 ldapQuotaAttribute description
php occ ldap:set-config -n s01 ldapExperiencedAdmin 0
php occ ldap:set-config -n s01 ldapExpertUsernameAttr uid
php occ ldap:set-config -n s01 ldapExpertUUIDGroupAttr cn
php occ ldap:set-config -n s01 ldapExpertUUIDUserAttr uid
php occ ldap:set-config -n s01 ldapGidNumber gidNumber
php occ ldap:set-config -n s01 ldapGroupDisplayName cn
php occ ldap:set-config -n s01 ldapGroupFilter "(&(|(objectclass=groupOfNames)))"
php occ ldap:set-config -n s01 ldapGroupFilterMode 0
php occ ldap:set-config -n s01 ldapGroupFilterObjectclass "groupOfNames"
php occ ldap:set-config -n s01 ldapGroupMemberAssocAttr member
php occ ldap:set-config -n s01 ldapLoginFilterAttributes cn
php occ ldap:set-config -n s01 ldapLoginFilterEmail 1
php occ ldap:set-config -n s01 ldapLoginFilterMode 0
php occ ldap:set-config -n s01 ldapLoginFilterUsername 1
php occ ldap:set-config -n s01 ldapNestedGroups 1
php occ ldap:set-config -n s01 ldapPagingSize 1000
php occ ldap:set-config -n s01 ldapQuotaDefault 10GB
php occ ldap:set-config -n s01 ldapTLS 0
php occ ldap:set-config -n s01 ldapUserDisplayName cn
php occ ldap:set-config -n s01 ldapUserDisplayName2 title
php occ ldap:set-config -n s01 ldapUserFilter "(objectclass=inetOrgPerson)"
php occ ldap:set-config -n s01 ldapUserFilterMode 0
php occ ldap:set-config -n s01 ldapUserFilterObjectclass inetOrgPerson
php occ ldap:set-config -n s01 ldapUuidGroupAttribute auto
php occ ldap:set-config -n s01 ldapUuidUserAttribute auto
php occ ldap:set-config -n s01 turnOffCertCheck 0
php occ ldap:set-config -n s01 turnOnPasswordChange 0
php occ ldap:set-config -n s01 useMemberOfToDetectMembership 0

if [ $HABIDAT_SSO == "true" ]
then

	php occ app:install -n user_saml
	php occ app:enable -n user_saml
  php occ config:app:set -n user_saml general-allow_multiple_user_back_ends --value=0
  php occ config:app:set -n user_saml general-require_provisioned_account --value=1
  php occ config:app:set -n user_saml type --value=saml
  php occ config:app:set -n user_saml types --value=authentication

  php occ saml:config:create
  php occ saml:config:set -n 1 --general-idp0_display_name="$HABIDAT_TITLE"
  php occ saml:config:set -n 1 --general-uid_mapping=uid
  php occ saml:config:set -n 1 --idp-entityId="https://user.$HABIDAT_DOMAIN"
  php occ saml:config:set -n 1 --idp-singleLogoutService.url="https://user.$HABIDAT_DOMAIN/sso/logout/nextcloud"
  php occ saml:config:set -n 1 --idp-singleSignOnService.url="https://user.$HABIDAT_DOMAIN/sso/login/nextcloud"
  php occ saml:config:set -n 1 --idp-x509cert="$(echo $HABIDAT_SSO_CERTIFICATE | sed --expression='s/\\n/\n/g')"
  php occ saml:config:set -n 1 --saml-attribute-mapping-displayName_mapping=cn
  php occ saml:config:set -n 1 --saml-attribute-mapping-email_mapping=mail
  php occ saml:config:set -n 1 --saml-attribute-mapping-quota_mapping=description
fi

php occ maintenance:mode -n --on
php occ db:convert-filecache-bigint --no-interaction
php occ maintenance:mode -n --off
