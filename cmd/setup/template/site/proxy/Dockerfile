FROM caddy:2.10.0-builder AS builder
RUN xcaddy build

FROM caddy:2.10.0
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
