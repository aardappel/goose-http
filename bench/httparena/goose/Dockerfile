# The Goose server as an HttpArena entry. bench/httparena.sh copies this
# directory into HttpArena's frameworks/goose/ with the package (*.goose,
# http.build, shim/), the server's server/, and scripts/build.sh and
# scripts/goose.sh beside it.
FROM ubuntu:26.04 AS build
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends ca-certificates curl git cmake ninja-build gcc g++ \
        liburing-dev libssl-dev && \
    rm -rf /var/lib/apt/lists/*

# The Goose pin in README.md, the release scripts/goose.sh names, or with
# GOOSE_COMMIT that commit built from source.
ARG GOOSE_COMMIT=
COPY scripts/goose.sh /server/scripts/goose.sh
RUN GOOSE_COMMIT="$GOOSE_COMMIT" /server/scripts/goose.sh >/goose-path

COPY *.goose http.build /server/
COPY shim /server/shim
COPY server /server/server
COPY scripts/build.sh /server/scripts/build.sh
# The io_uring loop: HttpArena starts every entry with seccomp=unconfined,
# which lets io_uring through Docker's default profile. Where io_uring_setup
# still fails, the loop runs on its emulation over epoll, and the server's
# first line says so. Two builds: without TLS, and with its TLS listener
# (server/server_tls.goose), which links OpenSSL and serves either loop as
# LOOP says at run time.
RUN GOOSE=$(cat /goose-path) LOOP=uring /server/scripts/build.sh && \
    cp /server/build/server /server/build/server-plain && \
    GOOSE=$(cat /goose-path) TLS=1 LOOP=epoll /server/scripts/build.sh

FROM ubuntu:26.04
# The package links liburing on Linux, whichever loop the server runs, and
# the TLS build links OpenSSL.
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends liburing2 libssl3t64 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /server/build/server-plain /server
COPY --from=build /server/build/server /server-tls
# The key exchange groups of HttpArena's Rust entries, whose rustls with the
# ring provider offers these, rather than OpenSSL's default with
# X25519MLKEM768 first, which costs each connection about 6 KB more.
ENV TLS_GROUPS=X25519:P-256:P-384
# HTTP/1.1 on 8080, h2c with prior knowledge on 8082, the port + 2, and h2 or
# HTTP/1.1 over TLS, as ALPN chooses, on 8081, the port + 1, and 8443, the
# port + 363.
EXPOSE 8080 8081 8082 8443
# One worker per CPU of the container's cpuset, which nproc reads. Waiting
# on, for the async profile's /delay: up to 16,384 timers a worker, as many
# as its connections. It left plaintext's instructions per request unchanged.
# TLS with the certificate HttpArena mounts at /certs, for the profiles that
# mount it, from the TLS build; without one, the build that doesn't map
# OpenSSL. Both on the io_uring loop. /static/ serves the files HttpArena
# mounts at /data/static.
CMD ["/bin/sh", "-c", "server=/server; if [ -r /certs/server.crt ] && [ -r /certs/server.key ]; then export TLS_CERT=/certs/server.crt TLS_KEY=/certs/server.key; server=/server-tls; fi; LOOP=uring WORKERS=${WORKERS:-$(nproc)} MAIL_SLOTS=256 MAX_WAITING=16384 FILES=/data/static exec $server http 8080"]
