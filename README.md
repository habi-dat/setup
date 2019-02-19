# habi\*DAT setup

habi\*DAT is a collaboration platform comprised of an ldap user backend, a nextcloud server and a discourse forum. The goal is to integrate all these tools as seamlessly as possible. This setup script should make it easier to deploy and maintain the platform

## Prerequisites

Make sure you have linux machine ready, are logged in as root and have the following software installed:

* envsubst (debian package gettext-base)
* curl
* docker
* docker-compose

## Usage

First you have to edit the file `setup.env` and fill in all necessary parameters.
Then you can use the script "setup.sh" to install the platform.

### Install module

To install a module run

`./setup.sh setup <module>`

Modules can only be installed after their dependencies. Right now this makes only 1 possible installation order:

1. nginx
2. auth
3. nextcloud
4. discourse

You can also install all modules at once:

`./setup.sh setup all`

### Uninstall module

To remove a module run

`./setup.sh rm <module>`

IMPORTANT: Please note that all data will be lost, as this also removes all mounted volumes and named volumes of the docker containers. 

### List modules

You can also list all available modules and their installation status with

`./setup.sh modules`

## Disclaimer

This is in an early development stage, please only use for testing purposes. 