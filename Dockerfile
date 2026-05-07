FROM docker.io/library/alpine:3.21

RUN apk add --no-cache \
    aerc \
    isync \
    notmuch \
    w3m \
    urlscan \
    chafa \
    poppler-utils \
    bash \
    less \
    vim \
    tzdata \
    ca-certificates \
    py3-pip \
    ttyd \
    screen \
    && pip install --break-system-packages --no-cache-dir getmail6

# Set timezone
ENV TZ=America/New_York

# Create user matching host UID
ARG UID=1000
ARG GID=1000
RUN addgroup -g ${GID} aerc && \
    adduser -u ${UID} -G aerc -h /home/aerc -s /bin/bash -D aerc

USER aerc
WORKDIR /home/aerc

ENTRYPOINT []
CMD ["/bin/bash"]
