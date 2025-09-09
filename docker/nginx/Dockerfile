FROM nginx:1.23.4

# Expire Docker images after 1 week in Quay
LABEL quay.expires-after=1w

COPY public /public
COPY docker/nginx/nginx.conf /nginx.conf
COPY docker/nginx/run_nginx.sh /run_nginx.sh

ENV CONSUL_TEMPLATE_VERSION=0.19.4

RUN apt-get update -y -qq \
  && apt-get install -yq --no-install-recommends \
    curl \
    ca-certificates \
  && curl -L https://releases.hashicorp.com/consul-template/${CONSUL_TEMPLATE_VERSION}/consul-template_${CONSUL_TEMPLATE_VERSION}_linux_amd64.tgz \
    | tar -xz \
    && mv /consul-template /usr/bin \
  && apt-get remove -y \
    curl \
    ca-certificates \
  && apt-get clean autoclean \
  && apt-get autoremove -y \
  && rm -rf \
    /var/lib/apt/lists/ \
    /tmp/* \
    /var/tmp/*

CMD ["/run_nginx.sh"]
