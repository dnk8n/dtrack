# syntax=docker/dockerfile:1

# Build cyanaudit from source
FROM postgres:18 AS build
RUN apt-get update && apt-get install -y wget build-essential libarchive-tools make postgresql-server-dev-18
RUN wget https://bitbucket.org/neadwerx/cyanaudit/get/master.zip -O /tmp/cyanaudit.zip
RUN mkdir /tmp/cyanaudit && bsdtar -xvf /tmp/cyanaudit.zip --strip-components=1 -C /tmp/cyanaudit
RUN rm -rf /tmp/cyanaudit/dist
RUN mkdir -p /tmp/build/cyanaudit && cp -a /tmp/cyanaudit /tmp/build/
RUN cd /tmp/build/cyanaudit && make && make install DESTDIR=/build

# Production image (compose selects this via build.target)
FROM postgres:18 AS production
RUN apt-get update && \
    apt-get install -y postgresql-plpython3-18 python3-pip libdbi-perl libdbd-pg-perl && \
    pip3 install --break-system-packages asyncio guardpost[jwt] && \
    cpan Parse::CSV Date::Parse
COPY --from=build /build /
COPY --from=build /tmp/cyanaudit /opt/cyanaudit

# Test image: production plus pgTAP and pg_prove for the database test suite.
# Selected by the dev compose override (and therefore CI); never deployed.
FROM production AS test
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        postgresql-18-pgtap libtap-parser-sourcehandler-pgtap-perl && \
    rm -rf /var/lib/apt/lists/*
