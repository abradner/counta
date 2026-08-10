# Production image for the Athena cluster (Talos k8s, Argo CD gitops,
# ghcr.io/abradner/counta, built by .github/workflows/docker.yml). Built for
# both linux/amd64 and linux/arm64 (cluster workers are Raspberry Pi arm64) —
# nothing here is arch-specific; multi-arch comes from buildx in CI, not
# from anything in this file.
#
# RUBY_VERSION below must track .ruby-version (currently "ruby-4.0.5") —
# there's no templating here, so bump both together.
#
# Runtime ENV contract:
#   Required (the app fails fast at boot without these — AGENTS.md
#   "Configuration": no fallback defaults for required config):
#     DATABASE_URL       postgresql://... — config/database.yml production
#     RAILS_MASTER_KEY   decrypts config/credentials.yml.enc
#   Optional tuning knobs (safe defaults, override only if needed):
#     PORT                 puma listen port (default 3000 here — NOT
#                           config/puma.rb's own 25425 default, which is the
#                           dev host's haproxy-mapped port, not meant for a
#                           container)
#     WEB_CONCURRENCY      puma worker processes (puma default: 1)
#     RAILS_MAX_THREADS    puma threads + AR pool size (default: 3)
#     RAILS_LOG_LEVEL       (default: info)
#     WEBAUTHN_ORIGIN, WEBAUTHN_RP_ID, RAILS_HOSTS
#                           override the production WebAuthn origin/RP ID and
#                           Host-header allowlist (default: counta.click) —
#                           see lib/webauthn_env_config.rb for why this one
#                           is allowed a default under the fail-fast rule.
#
# Entrypoint (bin/docker-entrypoint) runs `bin/rails db:prepare` before
# exec'ing CMD — migrations apply on rollout, the established pattern on
# this cluster.

ARG RUBY_VERSION=4.0.5
FROM docker.io/library/ruby:${RUBY_VERSION}-slim AS base

WORKDIR /rails

# Runtime-only packages for the final image: libpq5 for the pg gem,
# curl for anyone shelling in to poke /up.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y libpq5 curl && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test

# ---- build stage: compiles gems with native extensions (bootsnap, msgpack
# don't ship precompiled binaries for every platform) and precompiles assets
# ----
FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

COPY . .

# No RAILS_MASTER_KEY or DATABASE_URL at build time. SECRET_KEY_BASE_DUMMY
# lets assets:precompile boot far enough to run without decrypting
# credentials; DATABASE_URL is required config (config/database.yml,
# production-only ERB fetch) that boot needs present to parse the file even
# though asset precompilation never opens a connection — a placeholder,
# scoped to this one RUN step only (never ENV'd image-wide, which would
# defeat the fail-fast rule for every other command). Propshaft + importmap:
# no node/yarn step needed.
RUN SECRET_KEY_BASE_DUMMY=1 DATABASE_URL=postgresql://build:build@127.0.0.1/build_dummy \
    ./bin/rails assets:precompile

# ---- final stage: runtime image, no compiler toolchain ----
FROM base

COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p log tmp/pids tmp/cache && \
    chown -R rails:rails db log tmp public/assets

USER 1000:1000

ENV PORT=3000
EXPOSE 3000

ENTRYPOINT ["/rails/bin/docker-entrypoint"]
CMD ["./bin/rails", "server"]
