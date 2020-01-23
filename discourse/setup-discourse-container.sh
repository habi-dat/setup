#/bin/bash
set +x
cd /opt/bitnami/discourse 
RAILS_ENV=production bundle exec rake plugin:install repo=https://github.com/jonmbake/discourse-ldap-auth.git
RAILS_ENV=production bundle exec rake plugin:install repo=https://github.com/gdpelican/retort.git
RAILS_ENV=production bundle exec rake plugin:install repo=https://github.com/soudis/discourse-allow-same-origin.git 

HABIDAT_DISCOURSE_API_KEY=$(RAILS_ENV=production bundle exec rake -s api_key:get  | tr -d "\r" | awk '{print $NF}')

curl -k --header "Content-Type: application/json" \
        --request POST --data '{"color_scheme": { "base_scheme_id": "Light", "colors": [ { "hex": "212121", "name": "primary" }, { "hex": "fafafa", "name": "secondary" }, { "hex": "448aff", "name": "tertiary" }, { "hex": "e92e4e", "name": "quaternary" }, { "hex": "a40023", "name": "header_background" }, { "hex": "ffffff", "name": "header_primary" }, { "hex": "ffff8d", "name": "highlight" }, { "hex": "ff6d00", "name": "danger" }, { "hex": "4caf50", "name": "success" }, { "hex": "fa6c8d", "name": "love" } ], "name": "habidat"}}' \
        "http://localhost:3000/admin/color_schemes.json?api_username=admin&api_key=$HABIDAT_DISCOURSE_API_KEY"

curl -k --header "Content-Type: application/json" \
        --request PUT --data '{"theme":{"color_scheme_id": "2", "theme_fields":[{"name":"scss","target":"common","value":"@import url(\"https://'$HABIDAT_USER_SUBDOMAIN'.'$HABIDAT_DOMAIN'/public/stylesheets/appmenu.css\");","type_id":1},{"name":"header","target":"common","value":"<script> $(document).ready(function(){ $.get(\"https://'$HABIDAT_USER_DOMAIN'.'$HABIDAT_DOMAIN'/appmenu/'$HABIDAT_DISCOURSE_SUBDOMAIN'.'$HABIDAT_DOMAIN'\", function( data ) { $(\"#site-logo\").parent().parent().prepend( data );});})</script>","type_id":0}]}}' \
        "http://localhost:3000/admin/themes/2?api_username=admin&api_key=$HABIDAT_DISCOURSE_API_KEY"

RAILS_ENV=production bundle exec rake db:migrate
RAILS_ENV=production bundle exec rake assets:precompile
if [ -f /discourse-settings.yml ]
then
	RAILS_ENV=production bundle exec rake site_settings:import < /discourse-settings.yml
fi

#apt update && apt install -y postgresql-client
#docker-compose exec -e RAILS_ENV=production -e BUNDLE_GEMFILE=/opt/bitnami/discourse/Gemfile discourse bundle exec rake -s -f /opt/bitnami/discourse/Rakefile  plugin:install repo=https://github.com/jonmbake/discourse-ldap-auth.git
#docker-compose exec -e RAILS_ENV=production -e BUNDLE_GEMFILE=/opt/bitnami/discourse/Gemfile discourse bundle exec rake -s -f /opt/bitnami/discourse/Rakefile  plugin:install repo=https://github.com/soudis/discourse-allow-same-origin.git 
#docker-compose exec -e RAILS_ENV=production -e BUNDLE_GEMFILE=/opt/bitnami/discourse/Gemfile discourse bundle exec rake -s -f /opt/bitnami/discourse/Rakefile  plugin:install repo=https://github.com/gdpelican/retort.git
#docker-compose exec discourse bundle exec bash -c "cd /opt/bitnami/discourse && RAILS_ENV=production bundle exec rake assets:precompile"
