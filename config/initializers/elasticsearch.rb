# frozen_string_literal: true

EsClient = Elasticsearch::Model.client = Elasticsearch::Client.new(
  host: ENV.fetch("ELASTICSEARCH_HOST"),
  retry_on_failure: 5,
  # The Elasticsearch cluster can pause for several seconds during garbage
  # collection. A 5 second timeout expired inside those pauses, and each retry
  # hit the same paused cluster and failed again. 15 seconds lets a request
  # ride out a pause instead of failing.
  transport_options: { request: { timeout: 15 } },
  # Responses only: elasticsearch-transport 7.11 doesn't gzip request bodies (newer clients do).
  compression: true,
  log: true
)
# Debug adds every request and response body after the one-line summary.
EsClient.transport.logger.level = Logger::INFO if Rails.env.production? || Rails.env.staging?

USE_ES_ALIASES = Rails.env.production? || (Rails.env.staging? && ENV["BRANCH_DEPLOYMENT"] != "true")
