# syntax=docker/dockerfile:1
ARG RUBY_VERSION=3.4.3
FROM ruby:${RUBY_VERSION}-slim-bullseye

ENV APP_DIR=/workspace \
    BUNDLE_PATH=/bundle_path \
    GEM_HOME=/bundle_path \
    BUNDLE_BIN=/bundle_path/bin \
    PATH=/bundle_path/bin:/usr/local/bundle/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ARG DEBIAN_FRONTEND=noninteractive

# Packages
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
      libnss3-tools \
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
    # Mkcert
    && export MKCERT_VERSION=1.4.4 \
    && wget -qO /usr/local/bin/mkcert "https://github.com/FiloSottile/mkcert/releases/download/v${MKCERT_VERSION}/mkcert-v${MKCERT_VERSION}-linux-amd64" \
    && chmod +x /usr/local/bin/mkcert \
    \
    # Node v20
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && corepack enable \
    && npm install -g npm@10.8.2 \
    \
    # Update ImageMagick configuration
    && sed -r 's/(name="memory" value=")[^"]+"/\11GiB"/' -i /etc/ImageMagick-6/policy.xml \
    && sed -r 's/(name="disk" value=")[^"]+"/\18GiB"/' -i /etc/ImageMagick-6/policy.xml \
    && sed -r 's/(name="width" value=")[^"]+"/\150KP"/' -i /etc/ImageMagick-6/policy.xml \
    && sed -r 's/(name="height" value=")[^"]+"/\150KP"/' -i /etc/ImageMagick-6/policy.xml \
    \
    # Cleanup
    && apt-get clean autoclean \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

WORKDIR ${APP_DIR}

# Bundler
COPY Gemfile Gemfile.lock .ruby-version ${APP_DIR}/
RUN gem install bundler:$(awk '/BUNDLED WITH/{getline; print}' Gemfile.lock | tr -d " ") \
    && bundle config set path "${BUNDLE_PATH}" \
    && bundle install --retry 3 --without production test \
    && gem install foreman \
    && rm -rf /usr/local/bundle/cache/*.gem \
    && rm -rf ~/.bundle/cache

# Node dependencies
COPY package*.json ${APP_DIR}/
RUN npm install

COPY docker/app/entrypoint.sh /usr/local/bin/docker-entrypoint
RUN chmod +x /usr/local/bin/docker-entrypoint

ENTRYPOINT ["/usr/local/bin/docker-entrypoint"]
