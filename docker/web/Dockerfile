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
  && mkdir -p $APP_DIR/tmp \
  && chmod 770 $APP_DIR/tmp $APP_DIR/log \
  && chown app:app $APP_DIR $APP_DIR/tmp $APP_DIR/log

# Update ImageMagick configuration
# Set memory limit to 1GiB
RUN sed -r 's/(name="memory" value=")[^"]+"/\11GiB"/' -i /etc/ImageMagick-6/policy.xml \
  # Set disk limit to 8GiB
  && sed -r 's/(name="disk" value=")[^"]+"/\18GiB"/' -i /etc/ImageMagick-6/policy.xml \
  # Change width limit from 10KP to 50KP
  && sed -r 's/(name="width" value=")[^"]+"/\150KP"/' -i /etc/ImageMagick-6/policy.xml \
  # Change height limit from 10KP to 50KP
  && sed -r 's/(name="height" value=")[^"]+"/\150KP"/' -i /etc/ImageMagick-6/policy.xml \
  # Restrict the coders to the formats the app handles (see FILE_REGEX, web_image_content_types).
  # Every alias needs listing: IM6 matches on the alias, so dropping JPG blocks `.jpg` writes
  # while `identify` still works. The grep fails the build if the splice ever stops matching.
  && sed -i 's@</policymap>@  <policy domain="coder" rights="none" pattern="*" />\n  <policy domain="coder" rights="read|write" pattern="{GIF,JPEG,JPG,PNG,PNG8,PNG24,PNG32,WEBP,TIFF,TIF,BMP,BMP2,BMP3,PSD}" />\n</policymap>@' /etc/ImageMagick-6/policy.xml \
  && grep -q '<policy domain="coder" rights="read|write"' /etc/ImageMagick-6/policy.xml

# Install gems using only the dependency manifests so this (slow) layer is
# cached unless the Gemfile/lockfile changes.
ARG BUNDLE_GEMS__CONTRIBSYS__COM
COPY Gemfile Gemfile.lock .ruby-version $APP_DIR/
RUN cd $APP_DIR \
  && bundle config set without 'development test' \
  && BUNDLE_GEMS__CONTRIBSYS__COM=$BUNDLE_GEMS__CONTRIBSYS__COM bundle install

# Full source tree last: changes here only invalidate the layers below.
# --chown/--chmod set ownership and modes in this layer; a chmod -R/chown -R
# afterwards would store every file (and the gems) a second time. Some
# entrypoints Nomad runs directly, like docker/web/sidekiq_worker.sh, are not
# executable in git, so the 755 matters. lib/GeoIP2-City.mmdb arrives with the
# context: copy_secrets.sh puts the credentials repo's copy there.
COPY --chown=app:app --chmod=755 . $APP_DIR/

# Only a build that ran copy_secrets.sh has this file. Missing: GEOIP is nil and
# every GeoIp.lookup returns nothing. Empty: the initializer still opens it and
# boot fails. Warn, not fail: builds with no credentials repo must still succeed.
RUN f="$APP_DIR/lib/GeoIP2-City.mmdb"; \
  if [ ! -e "$f" ]; then echo "WARNING: lib/GeoIP2-City.mmdb missing from the build context; GEOIP will be nil in this image"; \
  elif [ ! -s "$f" ]; then echo "WARNING: lib/GeoIP2-City.mmdb is empty; the geoip initializer will fail to open it at boot"; fi

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
  ELASTICSEARCH_HOST=http://elasticsearch:9200 \
  MEMCACHE_SERVERS=memcached \
  IN_DOCKER="true"

WORKDIR $APP_DIR

CMD ["/usr/local/bin/gosu app docker/web/server.sh"]
