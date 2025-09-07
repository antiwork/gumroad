.PHONY: build_base build_base_test build build_nginx build_branch_app_nginx build_test build_staging build_production clean clean_local pull stop

NEW_BASE_REPO ?= $(ECR_REGISTRY)/gumroad/web_base
NEW_WEB_REPO ?= $(ECR_REGISTRY)/gumroad/web
NEW_WEB_BASE_TEST_REPO ?= $(ECR_REGISTRY)/gumroad/web_base_test
NGINX_REPO ?= $(ECR_REGISTRY)/gumroad/web_nginx
NGINX_TAG ?= latest
BRANCH_APP_NGINX_REPO ?= $(ECR_REGISTRY)/gumroad/branch_app_nginx
BRANCH_APP_NGINX_TAG ?= latest
WEB_COMMAND ?= "/usr/local/bin/gosu app docker/web/server.sh"
NEW_WEB_TAG ?= $(shell git rev-parse --short=12 HEAD)
COMPOSE_PROJECT_NAME ?= web
RUBY_VERSION := $(shell cat .ruby-version)
WEB_BASE_DOCKERFILE_FROM ?= ruby:$(RUBY_VERSION)-slim-bullseye
DOCKER_CMD ?= docker
DOCKER_COMPOSE_CMD ?= docker compose
AWS_CLI_DOCKER_IMAGE ?= garland/aws-cli-docker
PUSH_ASSETS ?= false
LOCAL_DETACHED ?= false
LOCAL_DOCKER_COMPOSE_CONFIG = docker-compose-local.yml

build_base:
	: $${BUNDLE_GEMS__CONTRIBSYS__COM?"Need to set BUNDLE_GEMS__CONTRIBSYS__COM for sidekiq-pro"}
	rm -f docker/base/Gemfile* docker/base/.ruby-version
	cp Gemfile* .ruby-version docker/base
	cd docker/base \
		&& $(DOCKER_CMD) build -t $(NEW_BASE_REPO):latest \
			--build-arg BUNDLE_GEMS__CONTRIBSYS__COM \
			--build-arg WEB_BASE_DOCKERFILE_FROM=$(WEB_BASE_DOCKERFILE_FROM) \
			--cache-from $(NEW_BASE_REPO):latest \
			--compress . \
		&& ./generate_tag_for_web_base.sh | xargs -I{} $(DOCKER_CMD) tag $(NEW_BASE_REPO):latest $(NEW_BASE_REPO):{} \
		&& rm -f Gemfile* .ruby-version Dockerfile

build_base_test:
	rm -f docker/base/Gemfile* docker/base/.ruby-version
	cp Gemfile* .ruby-version docker/base
	cd docker/base \
		&& WEB_BASE_DOCKERFILE_FROM=$(NEW_BASE_REPO):$(shell ./docker/base/generate_tag_for_web_base.sh) \
		$(DOCKER_CMD) build -t $(NEW_BASE_REPO)_test:latest \
			--cache-from $(NEW_WEB_BASE_TEST_REPO):latest \
			--build-arg WEB_BASE_DOCKERFILE_FROM \
			--file Dockerfile.test \
			--compress . \
		&& ./generate_tag_for_web_base_test.sh | xargs -I{} $(DOCKER_CMD) tag $(NEW_BASE_REPO)_test:latest $(NEW_WEB_BASE_TEST_REPO):{}

build:
	: $${BUNDLE_GEMS__CONTRIBSYS__COM?"Need to set BUNDLE_GEMS__CONTRIBSYS__COM for sidekiq-pro"}
	echo $(NEW_WEB_TAG) > revision
	WEB_DOCKERFILE_FROM=$(NEW_BASE_REPO):$(shell ./docker/base/generate_tag_for_web_base.sh) \
	$(DOCKER_CMD) build -t $(NEW_WEB_REPO):latest \
		--build-arg BUNDLE_GEMS__CONTRIBSYS__COM \
		--cache-from $(NEW_BASE_REPO):$(shell ./docker/base/generate_tag_for_web_base.sh) \
		--cache-from $(NEW_WEB_REPO):web-$(NEW_WEB_TAG) \
		--build-arg WEB_DOCKERFILE_FROM \
		--file docker/web/Dockerfile \
		--compress .
	$(DOCKER_CMD) tag $(NEW_WEB_REPO):latest $(NEW_WEB_REPO):web-$(NEW_WEB_TAG)

build_nginx:
	$(DOCKER_CMD) build -t $(NGINX_REPO):$(NGINX_TAG) \
		--file docker/nginx/Dockerfile \
		--compress .

build_branch_app_nginx:
	$(DOCKER_CMD) build -t $(BRANCH_APP_NGINX_REPO):$(BRANCH_APP_NGINX_TAG) \
		--file docker/branch_app_nginx/Dockerfile \
		--compress .

build_test:
	WEB_DOCKERFILE_FROM=$(NEW_BASE_REPO):$(shell ./docker/base/generate_tag_for_web_base.sh) \
		WEB_BASE_TEST_DOCKERFILE_FROM=$(NEW_BASE_REPO)_test:$(shell ./docker/base/generate_tag_for_web_base_test.sh) \
	$(DOCKER_CMD) build -t $(NEW_WEB_REPO):test-$(NEW_WEB_TAG) \
		--cache-from $(NEW_BASE_REPO):$(shell ./docker/base/generate_tag_for_web_base.sh) \
		--cache-from $(NEW_WEB_BASE_TEST_REPO):$(shell ./docker/base/generate_tag_for_web_base_test.sh) \
		--cache-from $(NEW_WEB_REPO):test-$(NEW_WEB_TAG) \
		--build-arg WEB_DOCKERFILE_FROM \
		--build-arg WEB_BASE_TEST_DOCKERFILE_FROM \
		--file docker/web/Dockerfile.test \
		--compress .
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) \
		$(DOCKER_COMPOSE_CMD) -f docker/docker-compose-test-and-ci.yml up -d db_test redis mongo elasticsearch
	$(DOCKER_CMD) run --network $(COMPOSE_PROJECT_NAME)_default \
		--entrypoint="" \
		$(NEW_WEB_REPO):test-$(NEW_WEB_TAG) \
		docker/ci/wait_on_connection.sh db_test 3306
	$(DOCKER_CMD) run --network $(COMPOSE_PROJECT_NAME)_default \
		--entrypoint="" \
		--shm-size="2g" \
		--memory-swappiness="0" \
		-e RAILS_ENV="test" \
		-e RAILS_MASTER_KEY=$(RAILS_MASTER_KEY) \
		-e BRANCH_CACHE_UPLOAD_ENABLED=$(BRANCH_CACHE_UPLOAD_ENABLED) \
		-e BRANCH_CACHE_RESTORE_ENABLED=$(BRANCH_CACHE_RESTORE_ENABLED) \
		-e CACHE_TAR_FILE=$(CACHE_TAR_FILE) \
		--label routes_compiled=true \
		--name worker_$(COMPOSE_PROJECT_NAME) \
		-v $${PWD}:/mnt/host \
		$(NEW_WEB_REPO):test-$(NEW_WEB_TAG) \
		bash -c "su -c \"[[ -e /mnt/host/$$CACHE_TAR_FILE ]] && tar -xf /mnt/host/$$CACHE_TAR_FILE -C . || true; npm ci && npm run setup && bundle exec rake db:setup assets:precompile --trace\" app; exit_status=$$?; [[ $$BRANCH_CACHE_UPLOAD_ENABLED == 'true' ]] && tar -cf /mnt/host/$$CACHE_TAR_FILE node_modules public/assets public/packs-test tmp/cache/assets tmp/shakapacker || true; [[ $$BRANCH_CACHE_RESTORE_ENABLED == 'true' ]] && rm -rf node_modules public/{assets,packs-test} tmp/cache/assets tmp/shakapacker || true; exit $$exit_status"
	$(DOCKER_CMD) ps -lq --filter='label=routes_compiled=true' --filter='exited=0' --filter='name=worker_$(COMPOSE_PROJECT_NAME)' | xargs -I{} $(DOCKER_CMD) commit {} $(NEW_WEB_REPO):test-$(NEW_WEB_TAG)
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) \
		$(DOCKER_COMPOSE_CMD) -f docker/docker-compose-test-and-ci.yml down

define remove_spec_folder
	rm -rf spec/
endef

build_staging:
	: $${GUM_AWS_ACCESS_KEY_ID?"Need to set GUM_AWS_ACCESS_KEY_ID"}
	: $${GUM_AWS_SECRET_ACCESS_KEY?"Need to set GUM_AWS_SECRET_ACCESS_KEY"}
	: $${RAILS_STAGING_MASTER_KEY?"Need to set RAILS_STAGING_MASTER_KEY"}
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) \
		$(DOCKER_COMPOSE_CMD) -f docker/docker-compose-test-and-ci.yml up -d db_test mongo memcached redis
	$(DOCKER_CMD) run \
		--name $(COMPOSE_PROJECT_NAME)_staging-assets \
		--network $(COMPOSE_PROJECT_NAME)_default \
		--entrypoint="" \
		--shm-size="2g" \
		--memory-swappiness="0" \
		-e RAILS_ENV="staging" \
		-e RACK_ENV="staging" \
		-e DATABASE_HOST="db_test" \
		-e DATABASE_NAME="gumroad_test" \
		-e DATABASE_USERNAME="root" \
		-e DATABASE_PASSWORD="password" \
		-e DEVISE_SECRET_KEY="sample_secret_key" \
		-e RAILS_MASTER_KEY=$(RAILS_STAGING_MASTER_KEY) \
		-e BUILDKITE_BRANCH=$(BUILDKITE_BRANCH) \
		-e REVISION=$(NEW_WEB_TAG) \
		--label assets_compiled=true \
		$(NEW_WEB_REPO):web-$(NEW_WEB_TAG) \
		gosu app bash -c "docker/web/compile_assets.sh && $(call remove_spec_folder)"
	$(DOCKER_CMD) ps -lq --filter='name=$(COMPOSE_PROJECT_NAME)_staging-assets' --filter='label=assets_compiled=true' --filter='exited=0' | xargs -I{} $(DOCKER_CMD) commit {} $(NEW_WEB_REPO):staging-$(NEW_WEB_TAG)
ifeq ($(PUSH_ASSETS),true)
	$(DOCKER_CMD) run -d \
		--entrypoint="bash" \
		--volume /app \
		$(NEW_WEB_REPO):staging-$(NEW_WEB_TAG) | xargs -I{} docker run \
			-e AWS_ACCESS_KEY_ID=$$GUM_AWS_ACCESS_KEY_ID \
			-e AWS_SECRET_ACCESS_KEY=$$GUM_AWS_SECRET_ACCESS_KEY \
			-e ASSETS_S3_BUCKET=gumroad-staging-assets \
			--volumes-from {} \
			$(AWS_CLI_DOCKER_IMAGE) \
			sh /app/docker/web/push_assets_to_s3.sh
endif
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) \
		$(DOCKER_COMPOSE_CMD) -f docker/docker-compose-test-and-ci.yml down

build_production:
	: $${GUM_AWS_ACCESS_KEY_ID?"Need to set GUM_AWS_ACCESS_KEY_ID"}
	: $${GUM_AWS_SECRET_ACCESS_KEY?"Need to set GUM_AWS_SECRET_ACCESS_KEY"}
	: $${RAILS_PRODUCTION_MASTER_KEY?"Need to set RAILS_PRODUCTION_MASTER_KEY"}
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) \
		$(DOCKER_COMPOSE_CMD) -f docker/docker-compose-test-and-ci.yml up -d db_test mongo memcached redis
	$(DOCKER_CMD) run \
		--name $(COMPOSE_PROJECT_NAME)_production-assets \
		--network $(COMPOSE_PROJECT_NAME)_default \
		--entrypoint="" \
		--shm-size="2g" \
		--memory-swappiness="0" \
		-e RAILS_ENV="production" \
		-e RACK_ENV="production" \
		-e DATABASE_HOST="db_test" \
		-e DATABASE_NAME="gumroad_test" \
		-e DATABASE_USERNAME="root" \
		-e DATABASE_PASSWORD="password" \
		-e RAILS_MASTER_KEY=$$RAILS_PRODUCTION_MASTER_KEY \
		-e DEVISE_SECRET_KEY="sample_secret_key" \
		-e REVISION=$(NEW_WEB_TAG) \
		--label assets_compiled=true \
		$(NEW_WEB_REPO):web-$(NEW_WEB_TAG) \
		gosu app bash -c "docker/web/compile_assets.sh && $(call remove_spec_folder)"
	$(DOCKER_CMD) ps -lq --filter='name=$(COMPOSE_PROJECT_NAME)_production-assets' --filter='label=assets_compiled=true' --filter='exited=0' | xargs -I{} $(DOCKER_CMD) commit {} $(NEW_WEB_REPO):production-$(NEW_WEB_TAG)
ifeq ($(PUSH_ASSETS),true)
	$(DOCKER_CMD) run -d \
		--entrypoint="bash" \
		--volume /app \
		$(NEW_WEB_REPO):production-$(NEW_WEB_TAG) | xargs -I{} docker run \
			-e AWS_ACCESS_KEY_ID=$$GUM_AWS_ACCESS_KEY_ID \
			-e AWS_SECRET_ACCESS_KEY=$$GUM_AWS_SECRET_ACCESS_KEY \
			-e ASSETS_S3_BUCKET=gumroad-production-assets \
			--volumes-from {} \
			$(AWS_CLI_DOCKER_IMAGE) \
			sh /app/docker/web/push_assets_to_s3.sh
endif
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) \
		$(DOCKER_COMPOSE_CMD) -f docker/docker-compose-test-and-ci.yml down

clean:
	rm -rf docker/tmp/

clean_local:
	rm -f revision web_base_sha

pull:
	$(DOCKER_COMPOSE_CMD) -f docker/docker-compose-test-and-ci.yml pull db_test mongo elasticsearch

local:
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) \
		$(DOCKER_COMPOSE_CMD) -f docker/$(LOCAL_DOCKER_COMPOSE_CONFIG) up $(if $(filter true,$(LOCAL_DETACHED)),-d)

stop_local:
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) \
		$(DOCKER_COMPOSE_CMD) -f docker/$(LOCAL_DOCKER_COMPOSE_CONFIG) down



stop:
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) \
		$(DOCKER_COMPOSE_CMD) -f docker/docker-compose-test-and-ci.yml down

.PHONY: shortest
shortest:
	@./scripts/shortest.sh || true
