<p align="center">
  <img width=100% src="habidatwide.png">
</p>

# habi\*DAT setup

habi\*DAT is a collaboration platform comprised of an ldap user backend, a nextcloud server and a discourse forum. The goal is to integrate all these tools as seamlessly as possible. It is meant to server the needs of small collective projects. This setup script is meant to allow for easys installation and maintenance.

## Prerequisites

### Software

Make sure you have linux machine ready, are logged in as root and have the following software installed:

- envsubst (debian package gettext-base, redhat/centos package gettext)
- curl
- mkcert
- docker
- docker compose plugin

Also make sure a user with the name www-data in a user group called www-data exists.

If you use the docker version, you only need to have docker and docker compose installed.

### DNS

Also you need to have a domain and subdomains for the different apps:

- User app (e.g. user.example.com)
- Single Sign On (sso.example.com)
- Nextcloud app (e.g. cloud.example.com)
- Discourse app (e.g. discourse.example.com)
- Direct Loan app (e.g. direktkredit.example.com)
- Semantic Mediawiki (e.g. mediawiki.example.com)
- Dokuwiki (e.g. dokuwiki.example.com)
- Mailtrain including public and sandbox subdomains (e.g. mailtrain.example.com, lists.example.com, sandbox.mailtrain.example.com)

## Usage

First you have to edit the file `setup.env` and fill in all necessary parameters. They should be pretty self-explainatory, except these three:

- HABIDAT_DOCKER_PREFIX: Is used as a prefix for all the docker names (containers, volumes, networks, ...). Set to anything that prevents collisions with other containers on your system.
- HABIDAT_CREATE_SELFSIGNED: If you want the setup to create a self-signed wildcard certificate with mkcert, set this to "true" (only for testing/development purposes)
- HABIDAT_ADMIN_EMAIL: E-Mail address of admin account
- HABIDAT_ADMIN_PASSWORD: You can choose the password for your admin account or set it to "generate" to have the setup generate a secure password for you
- HABIDAT_LDAP_DOMAIN: usually the same as HABIDAT_DOMAIN, except if you want to import ldap data from a production system, then use the one from the production system
- HABIDAT_LDAP_BASE: the ldap base needs to be based on HABIDAT_DOMAIN, e.g. "example.com" becomes "dc=example,dc=com". If you want to import from a production system, use the one from the production system

Make sure to have correct SMTP_* info setup or use a local mailhog instance for testing purposes. 

Now you can use the script "habidat.sh" to install the platform.

### Install module

To install a module run

`./habidat.sh install <module>`

Modules can only be installed after their dependencies. This makes the following installation order:

1. nginx
2. auth
3. nextcloud

then

- direktkredit
- discourse
- mediawiki
- dokuwiki
- mailtrain

You can also install all modules at once:

`./habidat.sh install all`

### Uninstall module

To remove a module run

`./habidat.sh rm <module>`

IMPORTANT: Please note that all data will be lost, as this also removes all mounted volumes and named volumes of the docker containers.

### List modules

You can also list all available modules and their installation status with

`./habidat.sh modules`

### Start, stop, restart, down modules

By

`./habidat.sh start|stop|restart|down <module>|[all]`

you can start, stop, restart and down a modules or all modules at once.

### Admin account

After installation you can logon to all the services with username `admin`. The password is printed at the end of the installation process and can be looked up in `store/auth/passwords.env`

## Disclaimer

This project is in an early development stage, please only use for testing purposes.

## Known Issues

- Mediawiki shows and error message after login, even though it actually logs in
- Dokuwiki module does not support SAML SSO yet
