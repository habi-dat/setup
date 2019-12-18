#/bin/bash
set +x
cd /opt/bitnami/discourse 
RAILS_ENV=production bundle exec rake plugin:install repo=https://github.com/jonmbake/discourse-ldap-auth.git
RAILS_ENV=production bundle exec rake plugin:install repo=https://github.com/soudis/discourse-allow-same-origin.git 
RAILS_ENV=production bundle exec rake plugin:install repo=https://github.com/gdpelican/retort.git
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
