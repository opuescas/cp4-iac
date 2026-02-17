worker_processes  1;
daemon off;
pid /var/run/nginx/nginx.pid;
lock_file /var/run/nginx/nginx.lock;

error_log stderr warn;

events {
  worker_connections  1024;
}

http {
  lua_package_path '/usr/local/openresty/lualib/?.lua;;';
  init_by_lua_block {
    -- warm require cache
    local _ = require "resty.random"
  }

  gzip on;
  gzip_vary on;
  gzip_proxied any;
  gzip_comp_level 6;
  gzip_buffers 16 8k;
  gzip_http_version 1.0;
  gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

  include /usr/local/openresty/nginx/conf/mime.types;
  include /usr/local/openresty/nginx/conf/nginx_resolvers.conf;
  
  default_type  application/octet-stream;
  log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
    '$status $body_bytes_sent "$http_referer" '
    '"$http_user_agent" "$http_x_forwarded_for"';

  access_log  /dev/stdout  main;

  # Don't show server version in respose
  server_tokens   off;

  large_client_header_buffers 4 18k;

  fastcgi_buffers         16  16k;
  fastcgi_buffer_size         32k;
  proxy_buffer_size          128k;
  proxy_buffers            4 256k;
  proxy_busy_buffers_size    256k;

  sendfile        on;
  keepalive_timeout 300;
  proxy_connect_timeout       300;
  proxy_send_timeout          300;
  proxy_read_timeout          300;
  send_timeout                600;
  proxy_hide_header X-Powered-By;

  server {
    # nginx-security-headers.conf does not require nonce at the moment
    set_by_lua_block $csp_nonce {
      local random = require "resty.random"
      local strong = random.bytes(16, true)
      return ngx.encode_base64(strong)
    }

    listen 8404 default_server ssl;
    port_in_redirect off;
    server_tokens   off;
    ssl_certificate     /etc/nginx/certs/tls.crt;
    ssl_certificate_key /etc/nginx/certs/tls.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!eNULL:!EXPORT:!CAMELLIA:!DES:!MD5:!PSK:!RC4:!SHA:!SHA1:!SSLv2:@STRENGTH;

    error_page 404 /404.html;

    location / {
      return 404;
    }

    location = /404.html {
      root /usr/local/openresty/nginx/html;
      sub_filter '__CSP_NONCE__' $csp_nonce;
      sub_filter_once off;
    }
  }

  map "" $api_connect_cfg {
    default $API_CONNECT_CONFIG_OBJECT;
  }

  server {
    set_by_lua_block $csp_nonce {
      local random = require "resty.random"
      local strong = random.bytes(16, true)
      return ngx.encode_base64(strong)
    }

    listen 8443 default_server ssl;
    port_in_redirect off;
    ssl_certificate     /etc/nginx/certs/tls.crt;
    ssl_certificate_key /etc/nginx/certs/tls.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!eNULL:!EXPORT:!CAMELLIA:!DES:!MD5:!PSK:!RC4:!SHA:!SHA1:!SSLv2:@STRENGTH;

    # auth_basic           "apim";
    # auth_basic_user_file /usr/local/openresty/nginx/basic-auth/htpasswd;

    root /usr/local/openresty/nginx/html;

    index index.html index.htm;

    server_name _;

    error_page 404 /404.html;

    $IF_CIP  location ~* /cip/.*(.*|js|css)$  {
    $IF_CIP    # the use of a variable here forces nginx to resolve DNS per-request instead of at startup only
    $IF_CIP    set $cip_service $CIP_SERVICE_ADDRESS;
    $IF_CIP    # nginx seems to require a resolver be set when doing per-request DNS resolutions
    $IF_CIP    resolver local=on valid=30s;
    $IF_CIP    rewrite ^/cip/(.*)$ $1 break;
    $IF_CIP    rewrite_log on;
    $IF_CIP    proxy_pass https://$cip_service/v1/$uri?$args;
    $IF_CIP    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    $IF_CIP  }

    # Cache files that are served on refresh and first load
    location ~* \.(js|png|css|ico|flv|txt|woff|woff2|svg)$ {
      expires 30d;
      add_header Cache-Control "public";
    }

    location = / {
      try_files $uri /auth/index.html;
      include nginx-security-headers.conf;
      sub_filter '__CSP_NONCE__' $csp_nonce;
      sub_filter_once off;
    }

    $IF_UIA  location /manager/uia/ {
    $IF_UIA    # the use of a variable here forces nginx to resolve DNS per-request instead of at startup only
    $IF_UIA    set $uia_service $SERVER_UIA_HOST;
    $IF_UIA    # nginx seems to require a resolver be set when doing per-request DNS resolutions
    $IF_UIA    resolver local=on valid=30s;
    $IF_UIA    proxy_pass $uia_service;
    $IF_UIA    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    $IF_UIA  }

    $IF_UIA  location /admin/uia/ {
    $IF_UIA    # the use of a variable here forces nginx to resolve DNS per-request instead of at startup only
    $IF_UIA    set $uia_service $SERVER_UIA_HOST;
    $IF_UIA    # nginx seems to require a resolver be set when doing per-request DNS resolutions
    $IF_UIA    resolver local=on valid=30s;
    $IF_UIA    proxy_pass $uia_service;
    $IF_UIA    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    $IF_UIA  }

    location /admin {
      try_files $uri /admin/index.html;
      include nginx-security-headers.conf;
      $IF_CIP sub_filter '<head>' '<head><script nonce="$csp_nonce">window.apiConnectCfg = $api_connect_cfg</script>'
      $IF_NOT_CIP sub_filter '<head>' '<head><script nonce="$csp_nonce">if (!window.apiConnectCfg) window.apiConnectCfg = $api_connect_cfg</script>';
      sub_filter '__CSP_NONCE__' $csp_nonce;
      sub_filter_once off;
    }

    location /manager {
      try_files $uri /manager/index.html;
      include nginx-security-headers.conf;
      $IF_CIP sub_filter '<head>' '<head> <script nonce="$csp_nonce">window.apiConnectCfg = $api_connect_cfg</script>';
      $IF_EAAS sub_filter '<head>' '<head><script nonce="$csp_nonce" src="$UI_SERVICE_URL/index.js"></script>';
      $IF_NOT_CIP sub_filter '</head>' '<script nonce="$csp_nonce">if (!window.apiConnectCfg) {window.apiConnectCfg = $api_connect_cfg;} else if (window.apiConnectCfg.formFactor === "ibm-cloud") {window.apiConnectCfg.apicConsumerCatalogEndpoint = $api_connect_cfg.apicConsumerCatalogEndpoint; window.apiConnectCfg.enableUIA =  $api_connect_cfg.enableUIA; window.apiConnectCfg.apicUiFeatureFlags = $api_connect_cfg.apicUiFeatureFlags; window.apiConnectCfg.atmInstalled = $api_connect_cfg.atmInstalled; window.apiConnectCfg.aiGatewayEnabled = $api_connect_cfg.aiGatewayEnabled;}</script></head>';
      sub_filter '__CSP_NONCE__' $csp_nonce;
      sub_filter_once off;
    }

    location /cloud-admin {
      try_files $uri /cloud-admin/index.html;
      include nginx-security-headers.conf;
      $IF_CIP sub_filter '</head>' '<script nonce="$csp_nonce">window.apiConnectCfg = {debugMode: JS_SAFE($UI_DEBUG_MODE), formFactor: "ibm-cloud"}</script></head>';
      sub_filter '__CSP_NONCE__' $csp_nonce;
      sub_filter_once off;
      $IF_CIP sub_filter_once on;
    }

    location /auth {
      gzip off;
      try_files $uri /auth/index.html;
      include nginx-security-headers.conf;
      sub_filter '__CSP_NONCE__' $csp_nonce;
      $IF_CIP sub_filter '<head>' '<head> <script nonce="$csp_nonce">window.apiConnectCfg = $api_connect_cfg</script>';
      $IF_NOT_CIP sub_filter '<head>' '<head><script nonce="$csp_nonce">if (!window.apiConnectCfg) window.apiConnectCfg = $api_connect_cfg</script>';
      sub_filter '__CSP_NONCE__' $csp_nonce;
      sub_filter_once off;
    }

    location = /WalkMe/settings.txt {
      types {}
      default_type application/javascript;
    }
    location /WalkMe {
      try_files $uri =404;
    }
    location = /status {
      stub_status;
      allow 127.0.0.1;
      deny all;
    }
    location = /assembly.html {
      include nginx-security-headers.conf;
      $IF_CIP sub_filter '<head>' '<head> <script nonce="$csp_nonce">window.apiConnectCfg = $api_connect_cfg</script>';
      sub_filter '__CSP_NONCE__' $csp_nonce;
    }
    location = /cloud-assembly.html {
      include nginx-security-headers.conf;
      sub_filter '__CSP_NONCE__' $csp_nonce;
    }



    location ~ ^/eventendpoint {
        if ($request_method = 'POST') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Credentials' 'true';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,X-CustomHeader,Keep-Alive,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type';
        }
        if ($request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Credentials' 'true';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,X-CustomHeader,Keep-Alive,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain charset=UTF-8';
            add_header 'Content-Length' 0;
            return 204;
        }

        if ($request_method = 'GET') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Credentials' 'true';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,X-CustomHeader,Keep-Alive,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain charset=UTF-8';
        }
      # return 200 $http_eem_mgmt_endpoint;
      proxy_pass $scheme://$http_eem_mgmt_endpoint;
      proxy_ssl_server_name   on;
      proxy_ssl_name $http_eem_host;
    }

    location ~ ^/oauthgateway {
      if ($request_method = 'POST') {
          add_header 'Access-Control-Allow-Origin' '*';
          add_header 'Access-Control-Allow-Credentials' 'true';
          add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
          add_header 'Access-Control-Allow-Headers' 'DNT,X-CustomHeader,Keep-Alive,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type';
      }
      if ($request_method = 'OPTIONS') {
        add_header 'Access-Control-Allow-Origin' '*';
        add_header 'Access-Control-Allow-Credentials' 'true';
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
        add_header 'Access-Control-Allow-Headers' 'DNT,X-CustomHeader,Keep-Alive,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type';
        add_header 'Access-Control-Max-Age' 1728000;
        add_header 'Content-Type' 'text/plain charset=UTF-8';
        add_header 'Content-Length' 0;
        return 204;
      }
      if ($request_method = 'GET') {
        add_header 'Access-Control-Allow-Origin' '*';
        add_header 'Access-Control-Allow-Credentials' 'true';
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
        add_header 'Access-Control-Allow-Headers' 'DNT,X-CustomHeader,Keep-Alive,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type';
        add_header 'Access-Control-Max-Age' 1728000;
        add_header 'Content-Type' 'text/plain charset=UTF-8';
      }

      # return 200 $http_gateway_url?$args;
      # resolver 10.96.0.10;
      proxy_pass $http_gateway_url?$args;
      # proxy_ssl_verify off;
      proxy_intercept_errors on;
      error_page 301 302 307 = @handle_redirect;
    }
    location = /index.html {
      return 404;
    }

    location @handle_redirect {
      set $saved_redirect_location '$upstream_http_location';
      add_header 'Redir-Location' $saved_redirect_location ;
      return 200 $saved_redirect_location;
    }
  }
}
