# Homepage

Homepage is served at `https://homepage.schweigert.io` on the LAN and tailnet.
The ingress uses the existing DNS and cert-manager setup and has no `public`
entrypoint. There is no application login; access follows the lab's private
ingress convention.

Each application's Ingress defines its dashboard entry using
`gethomepage.dev/` annotations. For Helm apps, these live in the chart's
ingress annotations (Grafana uses `values.grafana.ingress.annotations`).
Homepage discovers the URL from the Ingress host, TLS and path; there is no
separate application list to maintain.

```yaml
gethomepage.dev/enabled: "true"
gethomepage.dev/name: Jellyfin
gethomepage.dev/group: Media
gethomepage.dev/icon: jellyfin.svg
gethomepage.dev/description: Watch and listen
gethomepage.dev/weight: "10"
gethomepage.dev/external: "true"
```

`weight` orders entries within each group. `external: "true"` keeps these as
links without pod status or metrics queries. Do not put API credentials in
Ingress annotations.

Shared configuration lives in `cluster/apps/homepage/`:
`settings.yaml` controls the group order and layout, and
`widgets.yaml` defines the title and search widget. `custom.css` supplies
the warm charcoal palette, typography, responsive cards and keyboard focus styles.
The native application link covers each card, including its padding and empty
space; keyboard focus highlights the entire card.
The page uses system fonts, static colors and native links. There are no custom
animation loops, pointer handlers, DOM observers or clock timers. Homepage's
own React/Next.js client and search widget remain; this is not a zero-JavaScript
dashboard.

`custom.js` only registers `/sw.js` after page load. The service worker caches
the self-contained `offline.html` page (HTML/CSS, no JavaScript or external
assets). If the lab is unreachable, returns an HTTP error, or takes longer
than 1.5 seconds to respond, the browser displays "Not connected to the lab"
with a retry link and a normal web-search form. It does not cache dashboard
HTML, service data, API responses or credentials. The private route's 404
through Traefik's public entrypoint also shows the disconnected page.
Homepage's immutable
JavaScript/CSS assets continue using the browser's normal HTTP cache.

Offline support needs one completed online visit to the exact start-page URL
over HTTPS, in a normal browser profile. `http://localhost:3000` also works for
testing because browsers treat localhost as a secure origin. Browser cache
clearing/eviction removes the saved page; it cannot work on a first-ever offline
visit. After reconnecting, "Try again" loads the current dashboard. When editing
`offline.html`, update the cache suffix in `sw.js` to the first 12 characters
of its SHA256 (`shasum -a 256 cluster/apps/homepage/offline.html`). Old offline
caches are removed when the updated worker activates.
Flux substitutes `${EXTERNAL_DOMAIN}` in Ingress hosts and the allowed Host
header. Kustomize generates
a ConfigMap with a content hash so configuration changes roll the Deployment.
The startup hook regenerates Homepage's bundled demo page from this config
before the pod becomes ready. Empty integration config files are provided even
for unused integrations because Homepage otherwise tries to create them on the
read-only mount when serving the dashboard.

`kubernetes.yaml` enables in-cluster Ingress discovery. The dedicated service
account can only list Ingresses across namespaces; it cannot read Secrets,
pods or metrics, or modify cluster resources. `services.yaml` is generated as
an empty list so Homepage has the file it expects without a duplicate inventory.

The dashboard needs no API keys, database or PVC.
Logs use ephemeral storage. Service links open each application's own login;
the dashboard does not query their APIs.

The container is pinned to upstream `ghcr.io/gethomepage/homepage:v2.5.0`
([release](https://github.com/gethomepage/homepage/releases/tag/v2.5.0));
Renovate's existing Kubernetes manager tracks the image.

For local testing, use the workflow in [LOCAL.md](LOCAL.md). The dashboard is
available through the local ingress as `https://homepage.lab.test`, with the
local self-signed certificate. No Homepage-specific overrides are needed.

For a browser preview at `http://localhost:3000`, run the reconnecting forward
in a detached tmux session, independent of the agent or terminal lifetime:

```sh
tmux new-session -d -s lab-homepage-preview -c "$PWD" 'bash local/homepage-preview.sh'
```

It forwards the Service and reconnects after a pod replacement. Inspect it with
`tmux attach -t lab-homepage-preview`; stop it with
`tmux kill-session -t lab-homepage-preview`.
