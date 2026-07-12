# BASE
ARG WEB_DOCKERFILE_FROM
FROM ${WEB_DOCKERFILE_FROM}


ENV BUNDLE_PATH=/bundle_path
ENV APP_DIR=/app

# Use unicode
ENV LANG=C.UTF-8

# setup app user, directories
RUN useradd -ms /bin/bash app \
  && mkdir -p $APP_DIR \
  && mkdir -p $BUNDLE_PATH \
  && mkdir -p $APP_DIR/log \
  && mkdir -p $APP_DIR/tmp

# Update ImageMagick configuration
# Set memory limit to 1GiB
RUN sed -r 's/(name="memory" value=")[^"]+"/\11GiB"/' -i /etc/ImageMagick-6/policy.xml \
  # Set disk limit to 8GiB
  && sed -r 's/(name="disk" value=")[^"]+"/\18GiB"/' -i /etc/ImageMagick-6/policy.xml \
  # Change width limit from 10KP to 50KP
  && sed -r 's/(name="width" value=")[^"]+"/\150KP"/' -i /etc/ImageMagick-6/policy.xml \
  # Change height limit from 10KP to 50KP
  && sed -r 's/(name="height" value=")[^"]+"/\150KP"/' -i /etc/ImageMagick-6/policy.xml

# Dowload latest GeoIP DB
# Staged outside $APP_DIR so this layer stays cached across source changes;
# moved into place after the full-tree COPY below.
RUN cd /tmp \
  && curl -J -L -o GeoIP2-City.tar.gz https://download.maxmind.com/app/geoip_download\?edition_id\=GeoIP2-City\&license_key\=fxN7iBPUYfTS76V5\&suffix\=tar.gz \
  && tar xzf GeoIP2-City.tar.gz \
  && mv GeoIP2-City_* GeoIP2-City \
  && mkdir -p /usr/local/share/geoip \
  && mv GeoIP2-City/GeoIP2-City.mmdb /usr/local/share/geoip/GeoIP2-City.mmdb \
  && rm -rf /tmp/*

# Install gems using only the dependency manifests so this (slow) layer is
# cached unless the Gemfile/lockfile changes.
ARG BUNDLE_GEMS__CONTRIBSYS__COM
COPY Gemfile Gemfile.lock .ruby-version $APP_DIR/
RUN cd $APP_DIR \
  && bundle config set without 'development test' \
  && BUNDLE_GEMS__CONTRIBSYS__COM=$BUNDLE_GEMS__CONTRIBSYS__COM bundle install

# Full source tree last: changes here only invalidate the layers below.
COPY . $APP_DIR/

RUN mv /usr/local/share/geoip/GeoIP2-City.mmdb $APP_DIR/lib/GeoIP2-City.mmdb \
  && rmdir /usr/local/share/geoip

# TODO: look into solutions that prevent image bloating and/or avoids --squash
RUN chmod -R 755 $BUNDLE_PATH \
  && chmod -R 755 $APP_DIR \
  && chmod -R 770 $APP_DIR/tmp \
  && chmod -R 770 $APP_DIR/log \
  && chown -R app:app $APP_DIR \
  && chown -R root:app $BUNDLE_PATH

ENV DATABASE_HOST="db" \
  DATABASE_NAME="gumroad_development" \
  DATABASE_PORT=3306 \
  DATABASE_USERNAME="gumroad_development" \
  DATABASE_PASSWORD="gumroad_development" \
  PUMA_WORKING_DIRECTORY=$APP_DIR \
  REDIS_HOST="redis:6379/0" \
  SIDEKIQ_REDIS_HOST="redis:6379/1" \
  RPUSH_REDIS_HOST="redis:6379/2" \
  RACK_ATTACK_REDIS_HOST="redis:6379/3" \
  RAILS_ENV="development" \
  RACK_ENV="development" \
  MONGO_DATABASE_URL="mongo:27017" \
  MONGO_SECONDARY_DATABASE_URL="mongo:27017" \
  MONGO_DATABASE_NAME="gumroad_log_development" \
  MONGO_DATABASE_USERNAME="username" \
  MONGO_DATABASE_PASSWORD="password" \
  MONGO_REPLICA_SET="empty_replica_set" \
  ELASTICSEARCH_HOST=http://elasticsearch:9200 \
  MEMCACHE_SERVERS=memcached \
  IN_DOCKER="true"

WORKDIR $APP_DIR

CMD ["/usr/local/bin/gosu app docker/web/server.sh"]
