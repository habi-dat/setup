FROM docker/compose:1.23.2

ENV BUILD_DEPS="gettext" 

RUN set -x && \
    apk add --update gettext && \
    apk add --virtual build_deps gettext &&  \
    apk add --no-cache curl bash gawk sed grep bc coreutils ncurses && \
    cp /usr/bin/envsubst /usr/local/bin/envsubst && \
    apk del build_deps

ADD . /habidat

WORKDIR /habidat

RUN rm setup.env && chmod +x habidat.sh

COPY habidat.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
RUN ln -s usr/local/bin/docker-entrypoint.sh / # backwards compat
ENTRYPOINT ["docker-entrypoint.sh"]

