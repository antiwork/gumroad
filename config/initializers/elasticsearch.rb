# frozen_string_literal: true

EsClient = Elasticsearch::Model.client = Elasticsearch::Client.new(
  host: ENV.fetch("ELASTICSEARCH_HOST"),
  retry_on_failure: 5,
  # The Elasticsearch cluster can pause for several seconds during garbage
  # collection. A 5 second timeout expired inside those pauses, and each retry
  # hit the same paused cluster and failed again. 15 seconds lets a request
  # ride out a pause instead of failing.
  transport_options: { request: { timeout: 15 } },
  log: true
)

USE_ES_ALIASES = Rails.env.production? || (Rails.env.staging? && ENV["BRANCH_DEPLOYMENT"] != "true")
