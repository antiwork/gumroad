# Pinned, not a floating tag: the image is tagged with the last commit touching this
# directory and CI skips the build when that tag exists, so a floating tag never refreshes.
FROM openresty/openresty:1.31.8.1-alpine-fat


RUN luarocks install luasocket
RUN luarocks install lua_json
RUN luarocks install lbase64

COPY docker/branch_app_nginx/conf/default.conf /etc/nginx/conf.d/default.conf

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
