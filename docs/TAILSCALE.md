# Home LAN over Tailscale

`cluster/infra/configs/tailscale/connector.yaml` adds a cluster-scoped
`Connector` named `home-lan`, using the existing operator. It registers one
device named `home-lan` with `tag:k8s-subnet-router` and advertises only
`192.168.178.0/24`. It is not an exit node. No new credentials or dependencies
are needed.

The operator chart is already pinned to `1.102.4` in
`cluster/infra/controllers/tailscale/release.yaml`. The running HelmRelease
and operator image matched that pin during read-only inspection on
2026-10-16; the installed `connectors.tailscale.com` CRD supports `hostname`,
`replicas`, `tags`, `exitNode` and `subnetRouter.advertiseRoutes`.
The archive listed in the [official Helm index](https://pkgs.tailscale.com/helmcharts/index.yaml)
also reports that version and matched its published SHA-256 digest.
See the [operator subnet-router documentation](https://tailscale.com/docs/kubernetes-operator/connector/deploy-subnet-router).

Traffic follows these paths:

- LAN device: laptop/phone → Tailscale → `home-lan` → `192.168.178.x`.
- Internal URL: split DNS → AdGuard `192.168.178.102` → ingress
  `192.168.178.240:443` → existing Traefik service.
- Public HTTPS: VPS → existing ingress ProxyGroup / `traefik-public:8443` →
  Traefik `public` entrypoint, as before.

The public relay, ingress ProxyGroup, service annotations, entrypoints,
certificates and public DNS records are unchanged. Internal services need
no Tailscale annotations or new ingress resources. Default subnet-router
SNAT is retained, so LAN devices do not need a return route to the tailnet.
See [subnet routing](https://tailscale.com/docs/features/subnet-routers).

## Admin-console setup

These settings live outside Git and were **not inspected**: the tailnet
policy (including tag ownership, grants/ACLs and auto-approvers), OAuth
client permissions/tags, device approval/key expiry and DNS settings.
Read-only checks found no existing Connector, a ready operator and ingress
ProxyGroup, and AdGuard answering `lab.schweigert.io` with `192.168.178.240`.
The Mac reported Tailscale `Running`; no client settings were changed.

1. Before deployment, open [Access controls](https://login.tailscale.com/admin/acls).
   Add `tag:k8s-subnet-router` with `tag:k8s-operator` as an owner. The chart
   uses `tag:k8s-operator` by default, matching the running operator's
   `OPERATOR_INITIAL_TAGS`; confirm the device's tag in
   [Machines](https://login.tailscale.com/admin/machines). Keep existing tag
   ownership and OAuth permissions used by ingress. The existing operator
   OAuth client must be allowed to mint auth keys carrying the new tag via
   that ownership relationship; do not put OAuth credentials in this repo.

   Merge this entry into the existing policy's `tagOwners`:

   ```json
   "tag:k8s-subnet-router": ["tag:k8s-operator"]
   ```

2. Grant your signed-in user's devices access to the **LAN CIDR**, not just
   to the router's tag. Merge the example below into the existing policy,
   replacing `you@example.com` with your actual Tailscale login. This grants
   that user's devices all IP traffic to the home LAN, including DNS over
   UDP and TCP port 53 and HTTPS port 443. For a narrower policy, allow
   those ports to `192.168.178.102` and `192.168.178.240` plus the specific
   device ports you need. Existing broader allow rules still apply: grants
   and ACLs are additive. Preserve the VPS-to-public-ingress rules.

   ```json
   {
     "groups": {
       "group:home-lan": ["you@example.com"]
     },
     "grants": [
       {
         "src": ["group:home-lan"],
         "dst": ["192.168.178.0/24"],
         "ip": ["*"]
       }
     ]
   }
   ```

   This is a merge example, not a replacement for the whole policy.
   Device tags replace user ownership: a tagged laptop/phone needs an
   explicit matching source identity. Use the console policy validator
   and tests to confirm your user can reach the LAN and the VPS retains
   its current public-ingress access. See [grants](https://tailscale.com/docs/features/access-control/grants).

3. After the Connector is deployed, find `home-lan` in Machines. Approve
   the device if device approval is enabled, then use **Edit route settings**
   to approve exactly `192.168.178.0/24`. Advertising a route does not
   approve it or grant access. Check key expiry so the route will not
   unexpectedly stop working. This change uses manual route approval;
   no `autoApprovers` policy change is required.

4. In [DNS](https://login.tailscale.com/admin/dns), add a **custom nameserver**
   `192.168.178.102`, enable **Restrict to domain**, and enter `schweigert.io`
   (without `*.` or a URL scheme). This forwards queries for the domain
   and its subdomains to AdGuard over the approved subnet route. Use a
   restricted nameserver, leaving global resolvers and the global override
   setting unchanged. MagicDNS alone does not resolve these custom names.
   See [split DNS](https://tailscale.com/docs/reference/dns-in-tailscale).

   Clients must use Tailscale DNS settings. For initial verification, use
   no exit node; exit-node DNS can take precedence over split DNS. If an
   exit node is needed later, enable **Use with exit node** for this
   nameserver and verify it can reach AdGuard. Browser secure DNS / DoH
   can bypass the OS resolver; disable a custom resolver while testing.

## Local validation and deployment

Follow [the local workflow](LOCAL.md) on the feature branch:

```sh
local/cluster.sh check
local/cluster.sh sync master
local/cluster.sh sync
local/cluster.sh diff
local/cluster.sh release
```

The local patches remove the operator and its OAuth Secret, ingress
ProxyGroup, `traefik-public`, and the new Connector. The targeted Connector
deletion also works against a baseline without that resource. No local
device should register with the production tailnet. Local sync checks
rendering/reconciliation and this exclusion; it cannot prove live routing.
The Connector must additionally be validated against the deployed CRD
because CI's kubeconform allows missing schemas.

Only the user deploys: complete tag ownership/access setup, review the diff,
then push/open a PR and merge to `master` when ready. **Merging deploys via
Flux.** No host rebuild, operator upgrade or direct production apply is
needed. Observe with read-only commands:

```sh
kubectl --context lab -n flux-system get kustomization infra-configs
kubectl --context lab get connector home-lan -o yaml
kubectl --context lab -n tailscale get pods,statefulsets
```

Wait for the Connector's `ConnectorReady=True` condition and its device
hostname/IP status, then approve the route and configure split DNS as
above. Kubernetes readiness alone does not prove approval or connectivity.
This single replica can interrupt remote access during a restart/reschedule;
AdGuard on `192.168.178.102` is also a single point of failure.

## Verify away from home

Use cellular data or a laptop tethered to the phone, with home Wi-Fi off.
Avoid another network using `192.168.178.0/24`, which can conflict with the
advertised route. Connect Tailscale on both devices, signed into the
intended tailnet, and enable **Use Tailscale DNS settings**. macOS, iOS and
Android accept subnet routes automatically; Linux clients additionally
need `sudo tailscale set --accept-routes=true`.

On the Mac, use `/Applications/Tailscale.app/Contents/MacOS/Tailscale` for
the CLI if `tailscale` is not on PATH. Test in this order:

```sh
# Raw LAN access and direct DNS, independently of split DNS:
nc -vz -w 5 192.168.178.240 443
dig +time=3 +tries=1 @192.168.178.102 lab.schweigert.io A
dig +tcp +time=3 +tries=1 @192.168.178.102 lab.schweigert.io A

# HTTPS over the subnet route, retaining hostname/SNI and certificate checks:
curl --connect-timeout 5 --resolve lab.schweigert.io:443:192.168.178.240 \
  -I https://lab.schweigert.io

# macOS system resolver (dig without @ does not test macOS split DNS):
dscacheutil -q host -a name lab.schweigert.io
curl --connect-timeout 5 -I https://lab.schweigert.io
```

DNS must return `192.168.178.240`; HTTPS must present the existing valid
certificate and Homepage response. Open `https://lab.schweigert.io` and
another internal service on both laptop and phone. Also test a known LAN
device's actual listening port by IP; ping alone is not sufficient because
some devices block ICMP. If raw IP works but names fail, check AdGuard
UDP/TCP 53 access, split DNS and client DNS settings. If names resolve to
the public VPS, check for a resolver bypass. If IP access fails, check
device/route approval, access rules and subnet overlap first.

Finally disconnect Tailscale on the remote client and check an existing
public service, such as `https://jellyfin.schweigert.io`, still works through
the VPS. Internal Homepage should remain unavailable from the public
internet. Roll back through a revert PR/merge, then remove only the added
split-DNS entry and policy entries as appropriate; preserve existing
ingress/VPS rules. Do not patch production resources directly.
