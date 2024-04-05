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

If you just want to have a local test installation add the following lines to your /etc/hosts files:

```
127.0.0.1       cloud.habidat.local
127.0.0.1       user.habidat.local
127.0.0.1       sso.habidat.local
127.0.0.1       discourse.habidat.local
127.0.0.1       direktkredit.habidat.local
127.0.0.1       mediawiki.habidat.local
127.0.0.1       dokuwiki.habidat.local
127.0.0.1       mailtrain.habidat.local
127.0.0.1       sandbox.mailtrain.habidat.local
127.0.0.1       lists.habidat.local
```

### Mail Server

In order for everything to function properly you need to have an SMTP server ready that accepts plain requests without username and password. For testing purposes you can try without.

## Usage

First you have to edit the file `setup.env` and fill in all necessary parameters. They should be pretty self-explainatory, except these three:

- HABIDAT_DOCKER_PREFIX: Is used as a prefix for all the docker names (containers, volumes, networks, ...). Set to anything that prevents collisions with other containers on your system.
- HABIDAT_CREATE_SELFSIGNED: If you want the setup to create a self-signed wildcard certificate, set this to "true" (only for testing/development purposes)
- HABIDAT_ADMIN_PASSWORD: You can choose the password for your admin account or set it to "generate" to have the setup generate a secure password for you
- HABIDAT_SSO: set to true if you want to add authenticaiton via SAML (Single-Sign-On) - experimental
- HABIDAT_LDAP_BASE: the ldap base needs to be based on HABIDAT_DOMAIN, e.g. "example.com" becomes "dc=example,dc=com"

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

## Docker in Docker

You can also run habidat-setup with docker-compose. Here is an example for a docker-compose.yml including an environment file. In this case you do not need to clone the repository.

The `setup-docker.env` file:

```
HABIDAT_TITLE=habi*DAT
HABIDAT_DESCRIPTION=habi*DAT Test Plattform fuer Hausprojekte
HABIDAT_LOGO=habidat.png
HABIDAT_ADMIN_EMAIL=admin@example.com
HABIDAT_ADMIN_PASSWORD=generate
HABIDAT_PROTOCOL=https
HABIDAT_DOMAIN=habidat.local
HABIDAT_NEXTCLOUD_SUBDOMAIN=cloud
HABIDAT_DISCOURSE_SUBDOMAIN=discourse
HABIDAT_DIREKTKREDIT_SUBDOMAIN=direktkredit
HABIDAT_USER_SUBDOMAIN=user
HABIDAT_MEDIAWIKI_SUBDOMAIN=wiki
HABIDAT_MAILTRAIN_PUBLIC_SUBDOMAIN=lists
HABIDAT_MAILTRAIN_SUBDOMAIN=mailtrain
HABIDAT_MAILTRAIN_SANDBOX_SUBDOMAIN=sandbox.mailtrain
HABIDAT_LDAP_BASE=dc=habidat,dc=local
HABIDAT_SMTP_HOST=mail.xaok.org
HABIDAT_SMTP_PORT=25
HABIDAT_DOCKER_PREFIX=habidat
HABIDAT_CREATE_SELFSIGNED=true
HABIDAT_SSO=false
```

The `docker-compose.yml`:

```yaml
version: "3"

services:
  habidat:
    image: habidat/setup
    volumes:
      - ./habidat:/habidat/store
      - /var/run/docker.sock:/var/run/docker.sock
    env_file:
      - ./setup-docker.env
```

Running commands in this case looks like this:

`docker compose run habidat install nextcloud`

## Disclaimer

This project is in an early development stage, please only use for testing purposes.

## Known Issues

- Mediawiki shows and error message after login, even though it actually logs in
- Dokuwiki module does not support SAML SSO yet
