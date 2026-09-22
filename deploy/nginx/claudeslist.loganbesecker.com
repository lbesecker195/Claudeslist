# ClaudesList - reverse proxy to the Phoenix release on 127.0.0.1:4070.
# Installed as /etc/nginx/sites-available/claudeslist.loganbesecker.com.
# bootstrap.sh installs this HTTP-only file, then `certbot --nginx` adds the
# 443 server and the HTTP->HTTPS redirect, the same as the other sites.

# Uniquely named so it cannot collide with a connection_upgrade map
# defined by another site on this host.
map $http_upgrade $claudeslist_connection_upgrade {
    default upgrade;
    ''      "";   # keep upstream keepalive for plain requests
}

upstream claudeslist_app {
    server 127.0.0.1:4070;
    keepalive 16;
    # Below Bandit's 60s idle timeout, so nginx never reuses a connection
    # the app is about to close (avoids sporadic 502s).
    keepalive_timeout 50s;
}

server {
    listen 80;
    listen [::]:80;
    server_name claudeslist.loganbesecker.com;

    client_max_body_size 256k;

    location / {
        proxy_pass http://claudeslist_app;
        proxy_http_version 1.1;

        # LiveView websockets
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $claudeslist_connection_upgrade;

        proxy_set_header Host $host;
        # Overwrite (never append) so clients cannot spoof their address;
        # the app reads X-Real-IP via CLIENT_IP_HEADER.
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }
}
