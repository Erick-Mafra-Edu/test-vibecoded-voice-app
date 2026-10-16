FROM erlang:27-alpine AS build
RUN apk add --no-cache git curl ca-certificates
WORKDIR /app
RUN curl -fsSL https://s3.amazonaws.com/rebar3/rebar3 -o /usr/local/bin/rebar3 && chmod +x /usr/local/bin/rebar3
COPY rebar.config ./
COPY src ./src
RUN rebar3 as prod release

FROM erlang:27-alpine
RUN addgroup -S app && adduser -S -G app app
WORKDIR /app
COPY --from=build --chown=app:app /app/_build/prod/rel/beamvoice ./
USER app
ENV PORT=8080
EXPOSE 8080/tcp
CMD ["/app/bin/beamvoice", "foreground"]
