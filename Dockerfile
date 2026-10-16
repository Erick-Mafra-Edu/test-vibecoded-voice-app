FROM elixir:1.18-otp-27@sha256:2c3babc5e569d8ee1c289dc7907c076d1e26253e6b9ecdb9bcc78f593508b013 AS build
WORKDIR /app
COPY rebar.config rebar.lock ./
COPY src ./src
COPY test ./test
RUN rebar3 eunit && rebar3 ct
COPY media/mix.exs media/mix.lock ./media/
COPY media/lib ./media/lib
COPY media/config ./media/config
COPY media/test ./media/test
WORKDIR /app/media
RUN mix deps.get && BEAMVOICE_ALLOW_INSECURE=true mix test
ENV MIX_ENV=prod
RUN mix deps.get && mix release beamvoice

FROM elixir:1.18-otp-27@sha256:2c3babc5e569d8ee1c289dc7907c076d1e26253e6b9ecdb9bcc78f593508b013
RUN groupadd --system app && useradd --system --gid app --home-dir /app app
WORKDIR /app
COPY --from=build --chown=app:app /app/media/_build/prod/rel/beamvoice ./
USER app
ENV PORT=8080
EXPOSE 8080/tcp
CMD ["/app/bin/beamvoice", "start"]
