# Build arguments with defaults (can be overridden via --build-arg)
ARG RUBY_VERSION=3.4.3
ARG NODE_VERSION=20.17.0
ARG NPM_VERSION=10.8.2

FROM ruby:${RUBY_VERSION}-slim-bullseye

ENV APP_DIR=/workspace

# Re-declare ARGs after FROM (Docker scoping rules require this)
# They inherit values from the pre-FROM ARGs or from --build-arg
ARG DEBIAN_FRONTEND=noninteractive
ARG NODE_VERSION
ARG NPM_VERSION

RUN apt-get update -y -qq \
    && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      ffmpeg \
      fonts-dejavu \
      fonts-takao \
      fonts-wqy-microhei \
      fonts-wqy-zenhei \
      gnupg \
      imagemagick \
      jq \
      less \
      libcurl4-openssl-dev \
      liblzma-dev \
      default-libmysqlclient-dev \
      libssl-dev \
      libtag1-dev \
      libvips-dev \
      libxml2-dev \
      libxslt1-dev \
      libyaml-dev \
      default-mysql-client \
      pdftk \
      percona-toolkit \
      pkg-config \
      python3 \
      sudo \
      unzip \
      vim \
      wget \
      zlib1g-dev \
      git \
    \
    && curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION%%.*}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && corepack enable \
    && npm install -g npm@${NPM_VERSION} \
    \
    # Install mkcert for SSL certificate generation
    && export MKCERT_VERSION=1.4.4 \
    && wget -qO /usr/local/bin/mkcert "https://github.com/FiloSottile/mkcert/releases/download/v${MKCERT_VERSION}/mkcert-v${MKCERT_VERSION}-linux-amd64" \
    && chmod +x /usr/local/bin/mkcert \
    \
    # Cleanup
    && apt-get clean autoclean \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

WORKDIR ${APP_DIR}

COPY Gemfile Gemfile.lock .ruby-version ${APP_DIR}/
RUN gem install bundler:$(awk '/BUNDLED WITH/{getline; print}' Gemfile.lock | tr -d " ") \
    && bundle install --retry 3 --without production staging deployer

COPY package*.json ${APP_DIR}/
RUN npm install

COPY docker/app/entrypoint.sh /usr/local/bin/docker-entrypoint
RUN chmod +x /usr/local/bin/docker-entrypoint

ENTRYPOINT ["/usr/local/bin/docker-entrypoint"]
