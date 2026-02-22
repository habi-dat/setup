#!/bin/bash
set +x

php occ upgrade

#install and configure nextcloud
echo "[HABIDAT] Configuring Nextcloud..."
php occ config:system:set -n trusted_domains 2 --value="$HABIDAT_NEXTCLOUD_SUBDOMAIN.$HABIDAT_DOMAIN"
php occ config:system:set -n trusted_domains 3 --value="$HABIDAT_DOCKER_PREFIX-nextcloud"
php occ config:system:set -n lost_password_link --value="$HABIDAT_PROTOCOL://$HABIDAT_USER_SUBDOMAIN.$HABIDAT_DOMAIN/lostpasswd"


php occ config:app:set -n discoursesso clientsecret --value="$HABIDAT_DISCOURSE_SSO_SECRET"
php occ config:app:set -n discoursesso clienturl --value="$HABIDAT_PROTOCOL://$HABIDAT_DISCOURSE_SUBDOMAIN.$HABIDAT_DOMAIN"

#setup ldap
echo "[HABIDAT] Setting up LDAP..."
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
