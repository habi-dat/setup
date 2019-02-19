{
   "CAS_proxiedServices":{

   },
   "persistentStorageOptions":{
      "LockDirectory":"/var/lib/lemonldap-ng/psessions/lock",
      "Directory":"/var/lib/lemonldap-ng/psessions"
   },
   "grantSessionRules":{

   },
   "samlStorageOptions":{

   },
   "ldapGroupRecursive":0,
   "portalDisplayRegister":"0",
   "userDB":"LDAP",
   "sessionDataToRemember":{

   },
   "ldapGroupAttributeName":"member",
   "facebookExportedVars":{

   },
   "captchaStorageOptions":{

   },
   "oidcRPMetaDataExportedVars":null,
   "ldapExportedVars":{

   },
   "managerPassword":"",
   "exportedHeaders":{
      "manager.$HABIDAT_DOMAIN":{

      }
   },
   "logoutServices":{

   },
   "ldapTimeout":120,
   "samlSPMetaDataExportedAttributes":null,
   "ldapPasswordResetAttributeValue":"TRUE",
   "ldapSearchDeref":"find",
   "oidcOPMetaDataJSON":null,
   "locationRules":{
      "manager.$HABIDAT_DOMAIN":{
         "(?#Configuration)^/(manager\\.html|conf/)":"$uid eq \"dwho\"",
         "default":"$uid eq \"dwho\"",
         "(?#Notifications)/notifications":"$uid eq \"dwho\" or $uid eq \"rtyler\"",
         "(?#Sessions)/sessions":"$uid eq \"dwho\" or $uid eq \"rtyler\""
      }
   },
   "ldapPasswordResetAttribute":"pwdReset",
   "domain":"$HABIDAT_DOMAIN",
   "remoteGlobalStorageOptions":{

   },
   "dbiExportedVars":{

   },
   "ldapGroupAttributeNameSearch":"cn",
   "notificationStorageOptions":{
      "dirName":"/var/lib/lemonldap-ng/notifications"
   },
   "ldapPwdEnc":"utf-8",
   "cfgDate":1545141496,
   "managerDn":"",
   "loginHistoryEnabled":1,
   "ldapChangePasswordAsUser":0,
   "portalSkinBackground":"Aletschgletscher_mit_Pinus_cembra1.jpg",
   "demoExportedVars":{
      "uid":"uid",
      "mail":"mail",
      "cn":"cn"
   },
   "oidcOPMetaDataOptions":null,
   "passwordDB":"LDAP",
   "authChoiceModules":{

   },
   "slaveExportedVars":{

   },
   "cookieName":"lemonldap",
   "samlIDPMetaDataXML":null,
   "timeout":72000,
   "cfgAuthor":"dwho",
   "cfgNum":5,
   "portalDisplayResetPassword":1,
   "openIdExportedVars":{

   },
   "macros":{
      "_whatToTrace":"$_auth eq 'SAML' ? \"$_user\\@$_idpConfKey\" : \"$_user\""
   },
   "googleExportedVars":{

   },
   "globalStorageOptions":{
      "Directory":"/var/lib/lemonldap-ng/sessions",
      "generateModule":"Lemonldap::NG::Common::Apache::Session::Generate::SHA256",
      "LockDirectory":"/var/lib/lemonldap-ng/sessions/lock"
   },
   "ldapGroupObjectClass":"groupOfNames",
   "key":"ve9\\cQrj::T4n\\]9",
   "ldapServer":"ldap://localhost",
   "persistentStorage":"Apache::Session::File",
   "mailUrl":"http://auth.$HABIDAT_DOMAIN/mail.pl",
   "oidcStorageOptions":{

   },
   "whatToTrace":"_whatToTrace",
   "webIDExportedVars":{

   },
   "applicationList":{
      "1sample":{
         "type":"category",
         "catname":"Sample applications",
      },
      "3documentation":{
         "catname":"Documentation",
         "type":"category",
         "officialwebsite":{
            "type":"application",
            "options":{
               "name":"Offical Website",
               "uri":"http://lemonldap-ng.org/",
               "logo":"network.png",
               "description":"Official LemonLDAP::NG Website",
               "display":"on"
            }
         },
         "localdoc":{
            "type":"application",
            "options":{
               "display":"on",
               "description":"Documentation supplied with LemonLDAP::NG",
               "uri":"http://manager.$HABIDAT_DOMAIN/doc/",
               "name":"Local documentation",
               "logo":"help.png"
            }
         }
      },
      "2administration":{
         "manager":{
            "options":{
               "description":"Configure LemonLDAP::NG WebSSO",
               "display":"auto",
               "uri":"http://manager.$HABIDAT_DOMAIN/manager.html",
               "name":"WebSSO Manager",
               "logo":"configure.png"
            },
            "type":"application"
         },
         "sessions":{
            "options":{
               "uri":"http://manager.$HABIDAT_DOMAIN/sessions.html",
               "logo":"database.png",
               "name":"Sessions explorer",
               "description":"Explore WebSSO sessions",
               "display":"auto"
            },
            "type":"application"
         },
         "notifications":{
            "type":"application",
            "options":{
               "display":"auto",
               "description":"Explore WebSSO notifications",
               "logo":"database.png",
               "name":"Notifications explorer",
               "uri":"http://manager.$HABIDAT_DOMAIN/notifications.html"
            }
         },
         "catname":"Administration",
         "type":"category"
      }
   },
   "vhostOptions":{
      "manager.$HABIDAT_DOMAIN":{

      }
   },
   "cfgAuthorIP":"172.30.0.1",
   "samlSPMetaDataXML":null,
   "notificationStorage":"File",
   "registerDB":"Demo",
   "ldapPort":389,
   "portal":"http://auth.$HABIDAT_DOMAIN/",
   "post":{
      "manager.$HABIDAT_DOMAIN":{

      }
   },
   "groups":{

   },
   "oidcRPMetaDataOptions":null,
   "ldapGroupAttributeNameGroup":"dn",
   "ldapAuthnLevel":2,
   "notification":1,
   "localSessionStorageOptions":{
      "directory_umask":"007",
      "namespace":"lemonldap-ng-sessions",
      "cache_depth":3,
      "default_expires_in":600,
      "cache_root":"/tmp"
   },
   "reloadUrls":{
      "reload.$HABIDAT_DOMAIN":"http://reload.$HABIDAT_DOMAIN/reload"
   },
   "ldapSetPassword":0,
   "oidcServiceMetaDataAuthnContext":{

   },
   "cfgLog":"",
   "authentication":"LDAP",
   "ldapVersion":3,
   "portalCheckLogins":1,
   "exportedVars":{
      "UA":"HTTP_USER_AGENT"
   },
   "ldapBase":"dc=example,dc=com",
   "securedCookie":0,
   "globalStorage":"Apache::Session::File",
   "ldapPpolicyControl":0,
   "oidcOPMetaDataJWKS":null,
   "nginxCustomHandlers":{

   },
   "lwpSslOpts":{

   },
   "portalSkin":"bootstrap",
   "oidcOPMetaDataExportedVars":null,
   "ldapGroupAttributeNameUser":"dn",
   "samlSPMetaDataOptions":null,
   "casAttributes":{

   },
   "issuerDBGetParameters":{

   },
   "portalSkinRules":{

   },
   "ldapAllowResetExpiredPassword":0,
   "samlIDPMetaDataExportedAttributes":null,
   "registerUrl":"http://auth.$HABIDAT_DOMAIN/register.pl",
   "ldapUsePasswordResetAttribute":1,
   "oidcRPMetaDataOptionsExtraClaims":null,
   "samlIDPMetaDataOptions":null,
   "localSessionStorage":"Cache::FileCache",
   "casStorageOptions":{

   }
}