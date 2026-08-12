# syntax=docker/dockerfile:1
# check=error=true

# Production image. Build and run by hand:
# docker build -t counta .
# docker run -d -p 3000:3000 -e RAILS_MASTER_KEY=<value from config/master.key> -e DATABASE_URL=<postgres url> --name counta counta
#
# Runtime ENV contract:
#   Required — the app fails fast at boot without these, by design (AGENTS.md
#   §8 "Configuration": no fallback defaults for required config):
#     DATABASE_URL       postgresql://… — config/database.yml production block
#     RAILS_MASTER_KEY   decrypts config/credentials.yml.enc
#   Optional tuning knobs (safe defaults; override only if needed):
#     PORT               puma listen port — defaulted to 3000 below, NOT
#                        config/puma.rb's 25425 (the dev host's haproxy
#                        mapping, meaningless in a container)
#     WEB_CONCURRENCY    puma worker processes (puma default: 1)
#     RAILS_MAX_THREADS  puma threads + AR pool size (default: 3)
#     RAILS_LOG_LEVEL    (default: info)
#     WEBAUTHN_ORIGIN, WEBAUTHN_RP_ID, RAILS_HOSTS
#                        override the production WebAuthn origin/RP ID and the
#                        Host allowlist (default: counta.click) — see
#                        lib/webauthn_env_config.rb for why these are allowed
#                        defaults under the fail-fast rule.
#
# The entrypoint (bin/docker-entrypoint) runs db:prepare for the server and a
# pending-migration preflight for everything else — see that file.

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.5
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips postgresql-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage to reduce size of final image
FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libvips libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

COPY . .

# Precompile bootsnap code for faster boot times.
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompile assets. database.yml fetches DATABASE_URL with no default in
# production (fail-fast by design), and precompile boots the environment —
# the dummy is scoped to this RUN only; a runtime container without the real
# var must still crash on boot.
RUN SECRET_KEY_BASE_DUMMY=1 DATABASE_URL=postgres://dummy/dummy ./bin/rails assets:precompile




# Final stage for app image
FROM base

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash

COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# The dirs puma and Rails write to at runtime. .dockerignore strips log/ and
# tmp/ contents from the build context, so without this a non-root container
# can hit a missing (or root-owned) tmp/pids on boot. Done as root after the
# COPYs — a pre-COPY mkdir would leave them root-owned, and post-USER we
# couldn't chown.
RUN mkdir -p log tmp/pids tmp/cache && chown -R rails:rails log tmp

USER 1000:1000

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# config/puma.rb defaults PORT to 25425 (the pre-cutover dev host's HAProxy
# mapping) — pin the container default to the conventional 3000.
ENV PORT=3000
EXPOSE 3000
CMD ["./bin/rails", "server", "-b", "0.0.0.0"]
