{ cluster, ... }:
{
  networking.firewall.allowedTCPPorts = [ 443 ];

  services.haproxy = {
    enable = true;
    config = ''
      global
        log /dev/log local0
        maxconn 2000

      defaults
        log global
        mode tcp
        option tcplog
        timeout connect 5s
        timeout client  30s
        timeout server  30s
        timeout tunnel  1h

      frontend https
        bind :443
        bind [::]:443 v6only

        stick-table type ipv6 size 100k expire 1m store conn_rate(10s)
        tcp-request connection track-sc0 src
        tcp-request connection reject if { sc_conn_rate(0) gt 50 }

        tcp-request inspect-delay 5s
        tcp-request content accept if { req_ssl_hello_type 1 }

        use_backend homelab if { req_ssl_sni -i -m end .${cluster.externalDomain} }
        default_backend drop

      backend homelab
        server traefik traefik-public.tail1b93f7.ts.net:8443 send-proxy-v2 check check-send-proxy inter 10s

      backend drop
        tcp-request content reject
    '';
  };

  systemd.services.haproxy = {
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
  };
}
