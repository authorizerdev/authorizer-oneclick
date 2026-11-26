# syntax=docker/dockerfile:1
# One-click-deploy image for Authorizer v2: maps environment variables to the
# CLI flags the binary requires (v2 reads no env vars). See README.md.
ARG AUTHORIZER_VERSION=2.4.9
FROM quay.io/authorizer/authorizer:${AUTHORIZER_VERSION}
ARG AUTHORIZER_VERSION

LABEL org.opencontainers.image.source="https://github.com/authorizerdev/authorizer-oneclick" \
      org.opencontainers.image.description="Authorizer ${AUTHORIZER_VERSION} for one-click deploy buttons (env vars -> CLI flags)" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="${AUTHORIZER_VERSION}"

# Base images up to 2.4.8 do not ship /authorizer/data. Create it owned by the
# non-root runtime user (uid 1000) so SQLite and the generated-secrets file can
# be written, and so a fresh named volume mounted there inherits that owner.
USER root
RUN mkdir -p /authorizer/data && \
    chown 1000:1000 /authorizer/data && \
    chmod 700 /authorizer/data
COPY --chmod=755 entrypoint.sh /usr/local/bin/authorizer-oneclick
USER authorizer
WORKDIR /authorizer

ENV PORT=8080
EXPOSE 8080

# Follow PORT rather than the base image's hard-coded 8080.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT:-8080}/healthz" >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/authorizer-oneclick"]
CMD []
