# syntax=docker/dockerfile:1

# Build cyanaudit from source. The source is a vendored, pinned copy of the
# upstream archive (see vendor/README.md), checked against its SHA-256 so the
# build fails rather than silently using different code.
FROM postgres:15 AS build
ARG CYANAUDIT=cyanaudit-2.2.3-806f6c5
RUN apt-get update && apt-get install -y build-essential libarchive-tools make postgresql-server-dev-15
COPY vendor/${CYANAUDIT}.zip vendor/${CYANAUDIT}.zip.sha256 /tmp/
RUN cd /tmp && sha256sum -c ${CYANAUDIT}.zip.sha256
RUN mkdir /tmp/cyanaudit && bsdtar -xvf /tmp/${CYANAUDIT}.zip --strip-components=1 -C /tmp/cyanaudit
RUN rm -rf /tmp/cyanaudit/dist
RUN mkdir -p /tmp/build/cyanaudit && cp -a /tmp/cyanaudit /tmp/build/
RUN cd /tmp/build/cyanaudit && make && make install DESTDIR=/build

# Production image (compose selects this via build.target)
FROM postgres:15 AS production
RUN apt-get update && \
    apt-get install -y postgresql-plpython3-15 python3-pip libdbi-perl libdbd-pg-perl && \
    pip3 install --break-system-packages asyncio guardpost[jwt] && \
    cpan Parse::CSV Date::Parse
COPY --from=build /build /
COPY --from=build /tmp/cyanaudit /opt/cyanaudit

# Test image: production plus pgTAP and pg_prove for the database test suite.
# Selected by the dev compose override (and therefore CI); never deployed.
FROM production AS test
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        postgresql-15-pgtap libtap-parser-sourcehandler-pgtap-perl && \
    rm -rf /var/lib/apt/lists/*
