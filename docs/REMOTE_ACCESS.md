# Remote Dashboard Access

Hermes Dashboard and OpenClaw Control UI can expose agent configuration, API keys, approvals, and session state. Keep the default local tunnel unless you need remote access.

## Public HTTPS: Cloudflare Tunnel + Access

Use this when you need a remote HTTPS hostname. Create a Cloudflare Tunnel, add a public hostname, and protect it with Cloudflare Access before starting the connector.

In Cloudflare Zero Trust:

1. Create an Access self-hosted application for the dashboard hostname.
2. Add an allow policy for your identity.
3. Create a Tunnel public hostname whose service points to the local dashboard origin.

For a host-installed connector, point the service to:

```text
http://127.0.0.1:9119
```

For the optional Docker Compose connector, set the service/origin to:

```text
http://host.docker.internal:9119
```

Then put only the tunnel token in local `.env`:

```bash
CLOUDFLARE_TUNNEL_TOKEN=...
```

Run:

```bash
./scripts/dashboard-remote.sh cloudflare-start
```

Stop:

```bash
./scripts/dashboard-remote.sh cloudflare-stop
```

Do not run a Cloudflare public hostname without Access. The dashboard is an internal control surface, not a public app.

## Public HTTPS With Caddy or Traefik

Caddy and Traefik can issue valid Let's Encrypt certificates from Docker Compose, but they require a real domain, DNS pointing at the Mac or router, and inbound 80/443 reachability. That is awkward on a laptop, fragile behind NAT, and easier to misconfigure.

Use Caddy or Traefik only for a stable host on a network you control. For this project, Cloudflare Tunnel is simpler and safer.

## References

- Cloudflare Tunnel: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
- Cloudflare tunnel tokens: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/remote-tunnel-permissions/
- Caddy reverse proxy quick-start: https://caddyserver.com/docs/quick-starts/reverse-proxy
