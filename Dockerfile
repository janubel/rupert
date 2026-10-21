FROM ruby:4.0.6-alpine

RUN apk add --no-cache build-base sqlite-dev git openssl-dev bash sqlite

ENV RAILS_ENV=production \
    RAILS_LOG_TO_STDOUT=1 \
    RAILS_SERVE_STATIC_FILES=1

WORKDIR /app

COPY web/Gemfile web/Gemfile.lock ./
RUN bundle install --jobs 4 --retry 3

COPY web .

# Git-free images retain an explicit immutable build identity.
ARG RUPERT_BUILD_SHA
ARG RUPERT_BUILT_AT
RUN ruby -rjson -e 'sha = ENV.fetch("RUPERT_BUILD_SHA", ""); abort "Pass --build-arg RUPERT_BUILD_SHA=<full commit SHA>" unless sha.match?(/\A[0-9a-f]{40,64}\z/i); File.write("config/build.json", JSON.generate(revision: sha.downcase, built_at: ENV["RUPERT_BUILT_AT"]))'

# Precompile with Rails' build-time marker: SECRET_KEY_BASE_DUMMY makes the
# database and encryption-key checks stand down for this step only. The real
# SECRET_KEY_BASE / RAILS_ENCRYPTION_* come from the runtime .env; nothing is
# baked into the image.
RUN SECRET_KEY_BASE_DUMMY=1 bin/rails tailwindcss:build \
    && SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile

COPY entrypoint.sh /usr/bin/
RUN chmod +x /usr/bin/entrypoint.sh

# Run as a non-root user so a compromise of the app can't root the container
# or the mounted storage volume.
RUN addgroup -S app && adduser -S app -G app \
    && chown -R app:app /app /usr/bin/entrypoint.sh

USER app

EXPOSE 3000

ENTRYPOINT ["entrypoint.sh"]

CMD ["bin/rails", "server", "-b", "0.0.0.0"]
