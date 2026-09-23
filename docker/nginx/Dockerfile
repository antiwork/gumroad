# consul-template is one static binary, so fetch it in a throwaway stage rather
# than keeping a downloader in the runtime image.
FROM nginx:1.30.4-alpine AS consul-template

ARG CONSUL_TEMPLATE_VERSION=0.19.4

RUN curl -fsSL https://releases.hashicorp.com/consul-template/${CONSUL_TEMPLATE_VERSION}/consul-template_${CONSUL_TEMPLATE_VERSION}_linux_amd64.tgz \
  | tar -xz -C /usr/bin consul-template

# Alpine rather than Debian: same nginx build and modules, less than half the size.
FROM nginx:1.30.4-alpine

COPY --from=consul-template /usr/bin/consul-template /usr/bin/consul-template
COPY public /public
COPY docker/nginx/main.conf /etc/nginx/nginx.conf
COPY docker/nginx/nginx.conf /nginx.conf
COPY docker/nginx/run_nginx.sh /run_nginx.sh

# The base image ships curl and nothing here needs one. Keeping a downloader out
# of an internet-facing container is also what the old build ended up doing.
RUN apk del --no-cache curl

CMD ["/run_nginx.sh"]
