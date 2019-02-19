FROM docker:stable

RUN mkdir /habidat
WORKDIR /habidat

COPY setup.sh /habidat
RUN chmod +x setup.sh

ENTRYPOINT ["./setup.sh"]
