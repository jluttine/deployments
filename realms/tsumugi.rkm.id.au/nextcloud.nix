{ config, lib, pkgs, ... }:
let

nextcloudPath = "/var/lib/nextcloud";
hostname = "cloud.rkm.id.au";
commonAcmeConfig = (import ./common-acme-config.nix).commonAcmeConfig;

in {
  services.nginx.virtualHosts."${hostname}" = {
    enableSSL = true;
    forceSSL = true;
    sslCertificate = "/var/lib/acme/${hostname}/fullchain.pem";
    sslCertificateKey = "/var/lib/acme/${hostname}/key.pem";
    extraConfig = ''
      # Path to the root of your installation
      root ${pkgs.nextcloud};
      # set max upload size
      client_max_body_size 10G;
      fastcgi_buffers 64 4K;

      # Disable gzip to avoid the removal of the ETag header
      gzip off;

      # Uncomment if your server is build with the ngx_pagespeed module
      # This module is currently not supported.
      #pagespeed off;

      index index.php;
      error_page 403 /core/templates/403.php;
      error_page 404 /core/templates/404.php;
      add_header Strict-Transport-Security "max-age=15768000; includeSubDomains; preload;";
      add_header X-Content-Type-Options nosniff;
      add_header X-Frame-Options "SAMEORIGIN";
      add_header X-XSS-Protection "1; mode=block";
      add_header X-Robots-Tag none;
      add_header X-Download-Options noopen;
      add_header X-Permitted-Cross-Domain-Policies none;

      location /.well-known/acme-challenge {
        root /var/www/challenges;
      }

      location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
      }

      location ~ ^/(?:\.htaccess|data|config|db_structure\.xml|README) {
        deny all;
      }

      location = /.well-known/carddav {
        return 301 $scheme://$host/remote.php/dav;
      }

      location = /.well-known/caldav {
        return 301 $scheme://$host/remote.php/dav;
      }

      location / {
        rewrite ^(/core/doc/[^\/]+/)$ $1/index.html;
        try_files $uri $uri/ /index.php;
      }

      location ~ \.php(?:$|/) {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        include ${pkgs.nginx}/conf/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        fastcgi_param HTTPS on;
        fastcgi_pass unix:/run/phpfpm/nextcloud;
        fastcgi_intercept_errors on;
      }

      # Adding the cache control header for js and css files
      # Make sure it is BELOW the location ~ \.php(?:$|/) { block
      location ~* \.(?:css|js)$ {
        add_header Cache-Control "public, max-age=7200";
        # Add headers to serve security related headers
        add_header Strict-Transport-Security "max-age=15768000; includeSubDomains; preload;";
        add_header X-Content-Type-Options nosniff;
        add_header X-Frame-Options "SAMEORIGIN";
        add_header X-XSS-Protection "1; mode=block";
        add_header X-Robots-Tag none;
        # Optional: Don't log access to assets
        access_log off;
      }

      # Optional: Don't log access to other assets
      location ~* \.(?:jpg|jpeg|gif|bmp|ico|png|swf)$ {
        access_log off;
      }

      location ^~ /apps {
        alias /var/lib/nextcloud/apps;
      }
    '';
  };

  services.postgresql.enable = true;

  systemd.services.nextcloud-startup = {
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = pkgs.writeScript "nextcloud-startup" ''
        #! ${pkgs.bash}/bin/bash
        NEXTCLOUD_PATH="${nextcloudPath}"
        if (! test -e "''${NEXTCLOUD_PATH}"); then
          mkdir -p "''${NEXTCLOUD_PATH}/"{,config,data}
          cp -r "${pkgs.nextcloud}/apps" "''${NEXTCLOUD_PATH}"
          chmod 755 "''${NEXTCLOUD_PATH}"
          chown -R www-data:www-data "''${NEXTCLOUD_PATH}"
        fi
    '';
    };
    enable = true;
  };

  systemd.services.nextcloud-cron = {
    after = [ "network.target" ];
    script = ''
      ${pkgs.php}/bin/php ${pkgs.nextcloud}/cron.php
      ${pkgs.nextcloud-news-updater}/bin/nextcloud-news-updater -i 15 --mode singlerun ${pkgs.nextcloud}
    '';
    environment = { NEXTCLOUD_CONFIG_DIR = "${nextcloudPath}/config"; };
    serviceConfig.User = "www-data";
  };

  systemd.timers.nextcloud-cron = {
    enable = true;
    wantedBy = [ "timers.target" ];
    partOf = [ "nextcloud-cron.service" ];
    timerConfig = {
      OnCalendar = "*-*-* *:00,15,30,45:00";
      Persistent = true;
    };
  };

  services.phpfpm.poolConfigs.nextcloud = ''
    user = www-data
    group = www-data
    listen = /run/phpfpm/nextcloud
    listen.owner = www-data
    listen.group = www-data
    pm = dynamic
    pm.max_children = 5
    pm.start_servers = 2
    pm.min_spare_servers = 1
    pm.max_spare_servers = 3
    pm.max_requests = 500
    env[NEXTCLOUD_CONFIG_DIR] = "${nextcloudPath}/config"
    php_flag[display_errors] = off
    php_admin_value[error_log] = /run/phpfpm/php-fpm.log
    php_admin_flag[log_errors] = on
    php_value[date.timezone] = "UTC"
    php_value[upload_max_filesize] = 10G
    php_value[cgi.fix_pathinfo] = 1
  '';

  security.acme.certs."${hostname}" = commonAcmeConfig // {
    postRun = "systemctl reload-or-restart nginx";
  };
}
