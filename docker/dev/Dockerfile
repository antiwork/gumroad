# Development Dockerfile
# Based on docker/base/Dockerfile but optimized for development

ARG WEB_BASE_DOCKERFILE_FROM
FROM ${WEB_BASE_DOCKERFILE_FROM}

ENV BUNDLE_PATH=/bundle_path \
  APP_DIR=/app

# Use unicode
ENV LANG=C.UTF-8

# Setup app user, directories
RUN useradd -ms /bin/bash app \
  && mkdir -p $APP_DIR \
  && mkdir -p $BUNDLE_PATH \
  && mkdir -p $APP_DIR/log \
  && mkdir -p $APP_DIR/tmp \
  && mkdir -p /docker/dev \
  && mkdir -p /certs

# Copy certificate generation script
COPY docker/dev/generate_certificates.sh /docker/dev/generate_certificates.sh
RUN chmod +x /docker/dev/generate_certificates.sh

# Install dependencies: netcat, git, gosu, imagemagick, Node.js, and build tools
ARG GOSU_VERSION=1.10
RUN apt-get update -y -qq \
  && apt-get install -yq --no-install-recommends \
  build-essential \
  netcat-openbsd \
  git \
  imagemagick \
  ca-certificates \
  curl \
  gnupg \
  ruby-dev \
  && curl -fsSL -o /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-amd64" \
  && chmod +x /usr/local/bin/gosu \
  && mkdir -p /etc/apt/keyrings \
  && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/nodesource.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list \
  && apt-get update \
  && apt-get install -y nodejs \
  && corepack enable \
  && apt-get clean autoclean \
  && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Copy Gemfile and install ALL gems (including dev/test)
COPY Gemfile* .ruby-version $APP_DIR/
ARG BUNDLE_GEMS__CONTRIBSYS__COM
RUN cd $APP_DIR \
  && gem install bundler:$(awk '/BUNDLED\ WITH/{getline; print}' Gemfile.lock | tr -d " ") \
  && BUNDLE_GEMS__CONTRIBSYS__COM=${BUNDLE_GEMS__CONTRIBSYS__COM} bundle install

# Set permissions
RUN chmod -R 755 $BUNDLE_PATH \
  && chmod -R 755 $APP_DIR \
  && chmod -R 770 $APP_DIR/tmp \
  && chmod -R 770 $APP_DIR/log \
  && chown -R app:app $APP_DIR \
  && chown -R root:app $BUNDLE_PATH

# Update ImageMagick configuration (same as production)
RUN sed -r 's/(name="memory" value=")[^"]+"/\11GiB"/' -i /etc/ImageMagick-6/policy.xml \
  && sed -r 's/(name="disk" value=")[^"]+"/\18GiB"/' -i /etc/ImageMagick-6/policy.xml \
  && sed -r 's/(name="width" value=")[^"]+"/\150KP"/' -i /etc/ImageMagick-6/policy.xml \
  && sed -r 's/(name="height" value=")[^"]+"/\150KP"/' -i /etc/ImageMagick-6/policy.xml

WORKDIR $APP_DIR

# Default entrypoint (can be overridden in docker-compose)
ENTRYPOINT ["/usr/local/bin/gosu", "app"]
