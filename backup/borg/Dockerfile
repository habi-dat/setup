# borg 1.4 with an SSH client. The repository host runs borg-1.4 as well
# (ADR 0008); both ends must stay on 1.4.
FROM alpine:3.22

RUN apk add --no-cache 'borgbackup~1.4' openssh-client tzdata \
 && borg --version | grep -q '^borg 1\.4\.'
