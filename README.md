<p align="center">
  <img width=100% src="habidatwide.png">
</p>

# habi\*DAT setup

habi\*DAT is a collaboration platform comprised of an ldap user backend, a nextcloud server and a discourse forum. The goal is to integrate all these tools as seamlessly as possible. This setup script should make it easier to deploy and maintain the platform

## Prerequisites

### Software

Make sure you have linux machine ready, are logged in as root and have the following software installed:

* envsubst (debian package gettext-base)
* curl
* docker
* docker-compose

### DNS

Also you need to have a domain and subdomains for the different apps:

* User app (e.g. user.example.com)
* Nextcloud app (e.g. cloud.example.com)
* Discourse app (e.g. discourse.example.com)
* Direct Loan app (e.g. direktkredit.example.com)

If you just want to have a local test installation add the following lines to your /etc/hosts files:

```
127.0.0.1       cloud.habidat.local
127.0.0.1       user.habidat.local
127.0.0.1       discourse.habidat.local
127.0.0.1       direktkredit.habidat.local
```

### Mail Server

In order for everything to function properly you need to have an SMTP server ready that accepts plain requests without username and password. For testing purposes you can try without.

## Usage

First you have to edit the file `setup.env` and fill in all necessary parameters. They should be pretty self-explainatory, except these two:

* HABIDAT_DOCKER_PREFIX: Is used as a prefix for all the docker names (containers, volumes, networks, ...). Set to anything that prevents collisions with other containers on your system.
* HABIDAT_CREATE_SELFSIGNED: If you want the setup to create a self-signed wildcard certificate, set this to "true" (only for testing/development purposes)

Now you can use the script "habidat.sh" to install the platform.

### Install module

To install a module run

`./habidat.sh setup <module>`

Modules can only be installed after their dependencies. This makes the following installation order:

1. nginx
2. auth
3. nextcloud

then

* direktkredit
* discourse

You can also install all modules at once:

`./habidat.sh setup all`

### Uninstall module

To remove a module run

`./habidat.sh rm <module>`

IMPORTANT: Please note that all data will be lost, as this also removes all mounted volumes and named volumes of the docker containers. 

### List modules

You can also list all available modules and their installation status with

`./habidat.sh modules`

### Admin account

After installation you can logon to all the services with username `admin`. The password is printed on installation of the auth module and can be looked up in `store/auth/passwords.env`

## Disclaimer

This is in an early development stage, please only use for testing purposes. 
