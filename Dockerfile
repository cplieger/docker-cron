# check=error=true

# renovate: datasource=docker depName=docker
FROM docker:29-cli@sha256:b40b3737eb3bf588d25bb856d3564dd3f9fdb32ac2fc19ebe85cc58d761692a5

COPY --chmod=644 lib/shell/validate.sh /usr/local/lib/validate.sh
COPY --chmod=755 entrypoint.sh /entrypoint.sh
COPY --chmod=755 run-job.sh /usr/local/bin/run-job

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD pidof crond >/dev/null 2>&1 || exit 1
ENTRYPOINT ["/entrypoint.sh"]
