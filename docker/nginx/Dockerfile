# consul-template is one static binary, so fetch it in a throwaway stage rather
# than installing curl in the runtime image. Debian stops re-signing a release's
# security metadata at EOL and `apt-get update` on a pinned image then fails
# outright, which is what bullseye did on 2026-09-07: it blocked every build.
FROM nginx:1.30.4-trixie AS consul-template

ARG CONSUL_TEMPLATE_VERSION=0.19.4

RUN curl -fsSL https://releases.hashicorp.com/consul-template/${CONSUL_TEMPLATE_VERSION}/consul-template_${CONSUL_TEMPLATE_VERSION}_linux_amd64.tgz \
  | tar -xz -C /usr/bin consul-template

FROM nginx:1.30.4-trixie

COPY --from=consul-template /usr/bin/consul-template /usr/bin/consul-template
COPY public /public
COPY docker/nginx/main.conf /etc/nginx/nginx.conf
COPY docker/nginx/nginx.conf /nginx.conf
COPY docker/nginx/run_nginx.sh /run_nginx.sh

# The base image ships curl and nothing here needs one. Keeping a downloader out
# of an internet-facing container is also what the old build ended up doing.
RUN apt-get remove -y --purge curl \
  && apt-get autoremove -y

CMD ["/run_nginx.sh"]
