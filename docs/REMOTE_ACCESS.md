# Remote Dashboard Access

Hermes Dashboard and OpenClaw Control UI can expose agent configuration, API keys, approvals, and session state. Keep the default local tunnel unless you need remote access.

## Recommended: Tailscale Serve

Use Tailscale Serve when the dashboard only needs to be reachable by your own devices. It gives a valid HTTPS URL inside your tailnet and keeps Tailscale ACLs in front of the dashboard.

```bash
make agent-start
make dashboard-remote-start
make dashboard-remote-status
```

Stop serving it with:

```bash
make dashboard-remote-stop
```

This is the safest default remote mode because it is not public internet exposure.

Tailscale is optional and disabled by default:

```bash
TAILSCALE_ENABLED=1
TAILSCALE_SERVE_MODE=serve
```

For automated VM registration, set a pre-approved auth key locally:

```bash
TAILSCALE_AUTH_KEY=tskey-auth-...
TAILSCALE_HOSTNAME=omlx-openclaw-ubuntu
TAILSCALE_EXTRA_ARGS=--advertise-tags=tag:local-agent
```

OpenClaw Control UI uses `OPENCLAW_GATEWAY_TOKEN` by default. `make agent-open-dashboard` prints a URL with the token fragment:

```text
http://127.0.0.1:18789/#token=<OPENCLAW_GATEWAY_TOKEN>
```

If you want OpenClaw to trust Tailscale identity headers instead of pasting the shared token, enable it and add the exact Tailscale HTTPS origin:

```bash
OPENCLAW_ALLOW_TAILSCALE_AUTH=1
TAILSCALE_DASHBOARD_ORIGIN=https://your-mac.your-tailnet.ts.net
```

## Public HTTPS: Cloudflare Tunnel + Access

Use this when you need a public HTTPS hostname. Create a Cloudflare Tunnel, add a public hostname, and protect it with Cloudflare Access before starting the connector.

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

Use Caddy or Traefik only for a stable host on a network you control. For this project, Tailscale Serve and Cloudflare Tunnel are simpler and safer.

## References

- Tailscale Serve/Funnel CLI: https://tailscale.com/docs/reference/tailscale-cli/funnel
- Cloudflare Tunnel: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
- Cloudflare tunnel tokens: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/remote-tunnel-permissions/
- Caddy reverse proxy quick-start: https://caddyserver.com/docs/quick-starts/reverse-proxy
