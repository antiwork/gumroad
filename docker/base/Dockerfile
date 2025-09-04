# BASE
#
# Exportable items:
# /bundle_path
# /usr/local/bin

ARG WEB_BASE_DOCKERFILE_FROM
FROM ${WEB_BASE_DOCKERFILE_FROM}

# Expire Docker images after 6 months in Quay
LABEL quay.expires-after=6M

ENV BUNDLE_PATH=/bundle_path \
  APP_DIR=/app

COPY Gemfile* .ruby-version $APP_DIR/
COPY ./irbrc.rb /root/.irbrc

ARG DEBIAN_FRONTEND="noninteractive"

ARG DUMB_INIT_VERSION=1.2.0
ARG GOSU_VERSION=1.10
ARG S6_OVERLAY_VERSION=v1.19.1.1
ARG BUNDLE_GEMS__CONTRIBSYS__COM

# Workaround weird jdk bug
# https://github.com/geerlingguy/ansible-role-java/issues/64
RUN mkdir -p /usr/share/man/man1

# PACKAGES
RUN cd /tmp \
  && sed -i "s/bullseye main/bullseye main contrib non-free/" /etc/apt/sources.list \
  && apt-get update -y -qq \
  && apt-get install -yq --no-install-recommends \
  build-essential \
  ca-certificates \
  curl \
  ffmpeg \
  fonts-takao \
  gnupg \
  imagemagick \
  jq \
  less \
  libcurl4-openssl-dev \
  liblzma-dev \
  default-libmysqlclient-dev \
  libssl-dev \
  libtag1-dev \
  libxrender1 \
  libgcrypt20 \
  libvips-dev \
  libxml2-dev \
  libyaml-dev \
  percona-toolkit \
  pdftk \
  ruby-dev \
  screen \
  sudo \
  unzip \
  vim \
  wget \
  zlib1g-dev \
  fonts-dejavu \
  fonts-wqy-zenhei \
  fonts-wqy-microhei \
  ttf-wqy-microhei \
  ttf-wqy-zenhei \
  # update font cache to load installed fonts
  && fc-cache -f -v \
  # wkhtmltopdf
  && wget --quiet https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.4/wkhtmltox-0.12.4_linux-generic-amd64.tar.xz -O mktemp.tar.xz \
  && tar xf mktemp.tar.xz \
  && cp wkhtmltox/bin/wkhtmltopdf /usr/local/bin/wkhtmltopdf \
  && chmod +x /usr/local/bin/wkhtmltopdf \
  && rm -rf mktemp.tar.xz wkhtmltox \
  # dumb-init
  && wget --quiet -O /usr/local/bin/dumb-init "https://github.com/Yelp/dumb-init/releases/download/v${DUMB_INIT_VERSION}/dumb-init_${DUMB_INIT_VERSION}_amd64" \
  && chmod +x /usr/local/bin/dumb-init \
  # gosu
  && wget --quiet -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-amd64" \
  && chmod +x /usr/local/bin/gosu \
  # s6_overlay
  # TODO: would this have effects on the test container?
  && curl -J -L -o /tmp/s6-overlay-amd64.tar.gz https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-amd64.tar.gz \
  && tar xzf /tmp/s6-overlay-amd64.tar.gz -C / \
  # node 20.x
  && mkdir -p /etc/apt/keyrings \
  && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/nodesource.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list \
  && apt-get update \
  && apt-get install -y nodejs \
  && corepack enable \
  # git
  && apt-get install -y git \
  # jemalloc
  && apt-get install -y  libjemalloc-dev libjemalloc2 \
  # install gems
  && cd $APP_DIR \
  && gem install bundler:$(awk '/BUNDLED\ WITH/{getline; print}' Gemfile.lock | tr -d " ") \
  && BUNDLE_GEMS__CONTRIBSYS__COM=${BUNDLE_GEMS__CONTRIBSYS__COM} bundle install \
  # cleanup
  && apt-get remove -y \
  build-essential \
  ruby-dev \
  wget \
  && apt-get clean autoclean \
  && apt-get autoremove -y \
  && rm -rf \
  /var/lib/apt/lists/ \
  /tmp/* \
  /var/tmp/*

# chrome (for screenshotting in production)
ARG CHROME_VERSION=125.0.6422.76-1
RUN curl --retry 10 --connect-timeout 5 --retry-max-time 60 --output /tmp/google-chrome-stable_${CHROME_VERSION}_amd64.deb "https://public-files.gumroad.com/google-chrome-stable_${CHROME_VERSION}_amd64.deb" \
  && curl -s https://dl-ssl.google.com/linux/linux_signing_key.pub | sudo apt-key add - \
  && apt-get update \
  && apt-get install -y /tmp/google-chrome-stable_${CHROME_VERSION}_amd64.deb \
  && google-chrome --version \
  && apt-get clean autoclean \
  && apt-get autoremove -y \
  && rm -rf \
  /var/lib/apt/lists/ \
  /tmp/* \
  /var/tmp/*

RUN CHROME_VERSION="$(google-chrome --version)" \
  && export CHROMEDRIVER_RELEASE="$(echo $CHROME_VERSION | sed 's/^Google Chrome //')" \
  && curl --silent --show-error --location --fail --retry 4 --retry-delay 5 --output /tmp/chromedriver_linux64.zip "https://storage.googleapis.com/chrome-for-testing-public/$CHROMEDRIVER_RELEASE/linux64/chromedriver-linux64.zip" \
  && cd /tmp \
  && unzip chromedriver_linux64.zip \
  && rm -rf chromedriver_linux64.zip \
  && sudo mv chromedriver-linux64/chromedriver /usr/local/bin/chromedriver \
  && sudo chmod +x /usr/local/bin/chromedriver \
  && chromedriver --version

ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
