# Homepage

Homepage is served at `https://lab.schweigert.io` on the LAN and tailnet.
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
gethomepage.dev/group: Services
gethomepage.dev/icon: jellyfin.svg
gethomepage.dev/description: Watch and listen
gethomepage.dev/weight: "10"
```

`weight` orders entries in the single headerless `Services` grid. Native
Kubernetes stats show pod phase, CPU usage and memory. CPU is a percentage of
the configured limit when one exists, otherwise it is cores. The qBittorrent
tile includes both containers in its shared gluetun pod. Status describes pod
phase, not a successful application health probe.

Homepage defaults to selecting `app.kubernetes.io/name=<ingress name>`.
Set `gethomepage.dev/pod-selector` on an Ingress when its pods use different
labels (Seerr, Grafana, Mokuro Bunko and gluetun do). Do not put API credentials
in Ingress annotations. Native service widgets also show:

- Sonarr: series, missing episodes and queue count.
- Radarr: movies, wanted items and queue count.
- Bazarr: missing episode/movie subtitles.
- Prowlarr: query and grab counts.
- qBittorrent: incomplete/completed counts and download/upload rates.

Widget type, ingress URL and displayed fields live on each application's
Ingress. Only environment placeholders appear there. The six approved
credentials are copied from the existing arr Secret into the SOPS-encrypted
`homepage/secret.yaml`, and injected as `HOMEPAGE_VAR_*` environment variables.
Keep that encrypted copy in sync when rotating the app keys or qBittorrent
login, then restart Homepage to load the new values. No database passwords
are copied. The other tiles retain pod/resource stats because their app API
credentials are not provisioned here. Detailed queues and media titles are
not displayed.

Shared configuration lives in `cluster/apps/homepage/`. `settings.yaml`
controls the compact grid and permanently visible stats; `widgets.yaml` is
empty, with no heading or search bar. `custom.css` provides dark glass cards,
responsive spacing and keyboard focus. `background.asset` contains the supplied
photo, served locally as `/background.jpeg` from the ConfigMap. The source
uses `.asset` because Flux excludes JPEG filenames from source artifacts. The
background and cards use static CSS blur; no external image host is needed.
The native application link covers each card, including its padding, stats
and empty space. The health dot remains a native stats button.

The page uses system fonts and has no custom animation loops, pointer
handlers, DOM observers or clock timers. Homepage's own React/Next.js client
remains. Native Kubernetes stats fetch on load and revalidate on focus or
reconnection, without a custom polling loop.

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
account can list Ingresses, pods and pod metrics across namespaces; it cannot
read Secrets or logs, execute commands, or modify cluster resources. `services.yaml` is generated as
an empty list so Homepage has the file it expects without a duplicate inventory.

The dashboard needs no database or PVC. Logs use ephemeral storage. Service
links open each application's own login; the configured widgets query app
APIs from the Homepage server using the encrypted credentials. Credentials
are stripped from browser service configuration and are never cached by the
offline worker.

The container is pinned to upstream `ghcr.io/gethomepage/homepage:v2.5.0`
([release](https://github.com/gethomepage/homepage/releases/tag/v2.5.0));
Renovate's existing Kubernetes manager tracks the image.

For local testing, use the workflow in [LOCAL.md](LOCAL.md). The dashboard is
available through the local ingress as `https://lab.lab.test`, with the
local self-signed certificate. No Homepage-specific overrides are needed.

For a browser preview at `http://localhost:3000`, run the reconnecting forward
in a detached tmux session, independent of the agent or terminal lifetime:

```sh
tmux new-session -d -s lab-homepage-preview -c "$PWD" 'bash local/homepage-preview.sh'
```

It forwards the Service and reconnects after a pod replacement. Inspect it with
`tmux attach -t lab-homepage-preview`; stop it with
`tmux kill-session -t lab-homepage-preview`.
