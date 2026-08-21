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

ldap_config_id_from_show() {
  php occ ldap:show-config -n 2>/dev/null | awk -F'|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /Configuration/ && n == 0 {
      for (i = 1; i <= NF; i++) {
        v = trim($i)
        if (v ~ /^s[0-9]+$/) { cols[++n] = i; ids[n] = v }
      }
      next
    }
    /ldapConfigurationActive/ {
      for (j = 1; j <= n; j++) {
        v = trim($cols[j])
        if (v == "1") { print ids[j]; found = 1; exit }
      }
    }
    END { if (!found && n >= 1) print ids[1] }
  '
}

LDAP_ID=$(ldap_config_id_from_show)
if [ -z "$LDAP_ID" ]; then
  echo "[HABIDAT] No LDAP config found, creating one..."
  php occ ldap:create-empty-config -n
  LDAP_ID=$(ldap_config_id_from_show)
fi
if [ -z "$LDAP_ID" ]; then
  echo "[HABIDAT] ERROR: Could not determine LDAP config ID" >&2
  exit 1
fi
echo "[HABIDAT] Using LDAP config ID: $LDAP_ID"

php occ ldap:set-config -n "$LDAP_ID" ldapHost "$HABIDAT_DOCKER_PREFIX-ldap"
php occ ldap:set-config -n "$LDAP_ID" ldapPort 389
php occ ldap:set-config -n "$LDAP_ID" ldapLoginFilter "(&(objectclass=inetOrgPerson)(|(uid=%uid)(|(cn=%uid)(mail=%uid))))"
php occ ldap:set-config -n "$LDAP_ID" ldapAttributesForUserSearch "uid;cn"
php occ ldap:set-config -n "$LDAP_ID" hasMemberOfFilterSupport 1
php occ ldap:set-config -n "$LDAP_ID" lastJpegPhotoLookup 0
php occ ldap:set-config -n "$LDAP_ID" ldapAgentName "cn=admin,$HABIDAT_LDAP_BASE"
php occ ldap:set-config -n "$LDAP_ID" ldapAgentPassword "$HABIDAT_LDAP_ADMIN_PASSWORD"
php occ ldap:set-config -n "$LDAP_ID" ldapBase "$HABIDAT_LDAP_BASE"
php occ ldap:set-config -n "$LDAP_ID" ldapBaseGroups "ou=groups,$HABIDAT_LDAP_BASE"
php occ ldap:set-config -n "$LDAP_ID" ldapBaseUsers "ou=users,$HABIDAT_LDAP_BASE"
php occ ldap:set-config -n "$LDAP_ID" ldapCacheTTL 120
php occ ldap:set-config -n "$LDAP_ID" ldapConfigurationActive 1
php occ ldap:set-config -n "$LDAP_ID" ldapEmailAttribute mail
php occ ldap:set-config -n "$LDAP_ID" ldapQuotaAttribute description
php occ ldap:set-config -n "$LDAP_ID" ldapExperiencedAdmin 0
php occ ldap:set-config -n "$LDAP_ID" ldapExpertUsernameAttr uid
php occ ldap:set-config -n "$LDAP_ID" ldapExpertUUIDGroupAttr cn
php occ ldap:set-config -n "$LDAP_ID" ldapExpertUUIDUserAttr uid
php occ ldap:set-config -n "$LDAP_ID" ldapGidNumber gidNumber
php occ ldap:set-config -n "$LDAP_ID" ldapGroupDisplayName cn
php occ ldap:set-config -n "$LDAP_ID" ldapGroupFilter "(&(|(objectclass=groupOfNames)))"
php occ ldap:set-config -n "$LDAP_ID" ldapGroupFilterMode 0
php occ ldap:set-config -n "$LDAP_ID" ldapGroupFilterObjectclass "groupOfNames"
php occ ldap:set-config -n "$LDAP_ID" ldapGroupMemberAssocAttr member
php occ ldap:set-config -n "$LDAP_ID" ldapLoginFilterAttributes cn
php occ ldap:set-config -n "$LDAP_ID" ldapLoginFilterEmail 1
php occ ldap:set-config -n "$LDAP_ID" ldapLoginFilterMode 0
php occ ldap:set-config -n "$LDAP_ID" ldapLoginFilterUsername 1
php occ ldap:set-config -n "$LDAP_ID" ldapNestedGroups 1
php occ ldap:set-config -n "$LDAP_ID" ldapPagingSize 1000
php occ ldap:set-config -n "$LDAP_ID" ldapQuotaDefault 10GB
php occ ldap:set-config -n "$LDAP_ID" ldapTLS 0
php occ ldap:set-config -n "$LDAP_ID" ldapUserDisplayName cn
php occ ldap:set-config -n "$LDAP_ID" ldapUserDisplayName2 title
php occ ldap:set-config -n "$LDAP_ID" ldapUserFilter "(objectclass=inetOrgPerson)"
php occ ldap:set-config -n "$LDAP_ID" ldapUserFilterMode 0
php occ ldap:set-config -n "$LDAP_ID" ldapUserFilterObjectclass inetOrgPerson
php occ ldap:set-config -n "$LDAP_ID" ldapUuidGroupAttribute auto
php occ ldap:set-config -n "$LDAP_ID" ldapUuidUserAttribute auto
php occ ldap:set-config -n "$LDAP_ID" turnOffCertCheck 0
php occ ldap:set-config -n "$LDAP_ID" turnOnPasswordChange 0
php occ ldap:set-config -n "$LDAP_ID" useMemberOfToDetectMembership 0

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
