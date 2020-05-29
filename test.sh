#!/bin/bash
source setup.env
source store/auth/passwords.env


echo "Creating admin user..."

echo "$HABIDAT_ADMIN_EMAIL" > create_admin_user
echo "$HABIDAT_ADMIN_PASSWORD" >> create_admin_user
echo "$HABIDAT_ADMIN_PASSWORD" >> create_admin_user
echo "Y" >> create_admin_user

