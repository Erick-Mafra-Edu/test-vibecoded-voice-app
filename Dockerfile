FROM erlang:27-alpine@sha256:0fc9b04ad1509f839252423fc10dae20478f618df8f8d4bb805943c83d0124a1 AS build
WORKDIR /app
COPY rebar.config rebar.lock ./
COPY src ./src
COPY test ./test
RUN rebar3 eunit && rebar3 ct && rebar3 as prod release

FROM erlang:27-alpine@sha256:0fc9b04ad1509f839252423fc10dae20478f618df8f8d4bb805943c83d0124a1
RUN addgroup -S app && adduser -S -G app app
WORKDIR /app
COPY --from=build --chown=app:app /app/_build/prod/rel/beamvoice ./
USER app
ENV PORT=8080
EXPOSE 8080/tcp
CMD ["/app/bin/beamvoice", "foreground"]
