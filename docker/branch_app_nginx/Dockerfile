FROM openresty/openresty:jessie

RUN luarocks install luasocket
RUN luarocks install lua_json
RUN luarocks install lbase64

COPY docker/branch_app_nginx/conf/default.conf /etc/nginx/conf.d/default.conf

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
