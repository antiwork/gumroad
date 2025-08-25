FROM mcr.microsoft.com/devcontainers/base:ubuntu-22.04

ARG RUBY_VERSION=3.4.3
ARG NODE_VERSION=20.17.0

# Install dependencies
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential git curl ca-certificates make \
    libssl-dev libreadline-dev zlib1g-dev libyaml-dev libxml2-dev libxslt1-dev \
    libvips libvips-dev imagemagick ffmpeg \
    mysql-client \
    && rm -rf /var/lib/apt/lists/*

# Install rbenv + Ruby
RUN git clone https://github.com/rbenv/rbenv.git ~/.rbenv \
  && echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc \
  && echo 'eval "$(rbenv init - bash)"' >> ~/.bashrc \
  && git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build \
  && ~/.rbenv/bin/rbenv install -s ${RUBY_VERSION} \
  && ~/.rbenv/bin/rbenv global ${RUBY_VERSION}

# Install Node via n
RUN curl -fsSL https://raw.githubusercontent.com/tj/n/master/bin/n -o /usr/local/bin/n \
  && chmod +x /usr/local/bin/n \
  && n ${NODE_VERSION}

# Yarn via corepack
RUN corepack enable

WORKDIR /workspaces/gumroad

