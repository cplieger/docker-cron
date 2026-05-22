# check=error=true

# renovate: datasource=docker depName=docker
FROM docker:29-cli@sha256:9ba8e32bfc35a2c7ae2feb1e3241b2778ae21dee80f4dcd31d04e1cfdea86ea2

COPY --chmod=644 lib/shell/validate.sh /usr/local/lib/validate.sh
COPY --chmod=755 entrypoint.sh /entrypoint.sh
COPY --chmod=755 run-job.sh /usr/local/bin/run-job

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD pidof crond >/dev/null 2>&1 || exit 1
ENTRYPOINT ["/entrypoint.sh"]
