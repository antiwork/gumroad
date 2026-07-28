# frozen_string_literal: true

# Opt-in real Elasticsearch for the Minitest suite.
#
# The harness stubs Elasticsearch process-wide for stability (see test_helper.rb),
# which is right for the ~2,600 tests that only trip an indexing callback. A test
# whose subject is an actual query result — product search, page-view analytics,
# the purchase aggregations behind a product's earnings — can't work against
# canned responses, so it includes this module, swaps the real client in for the
# duration, and restores the fake in teardown. Indices are namespaced per
# test-database so parallel runs on a shared cluster don't collide.
#
# Include it in the test class and call install_real_elasticsearch! with every
# model whose index the test can touch; restore_fake_elasticsearch! in teardown
# (or an ensure block, when only one test in a large class needs it).
module RealElasticsearchBridge
  def self.real_client
    @real_client ||= Elasticsearch::Client.new(
      host: ENV.fetch("ELASTICSEARCH_HOST"),
      retry_on_failure: 5,
      transport_options: { request: { timeout: 15 } }
    )
  end

  # Point the stubbed client (installed everywhere) at real Elasticsearch for the
  # duration of the test via the thread-local flag test_helper honors, and give
  # the models isolated index names so runs on the shared cluster don't collide.
  # No client objects are swapped, so elasticsearch-model's per-class client
  # memoization is a non-issue and nothing leaks between test classes.
  #
  # Two limits worth knowing before extending this:
  #
  # 1. Only the models passed in get namespaced index names. While the thread-local is
  #    set, an incidental ES write from ANY other model — say an indexing callback firing
  #    inside a Sidekiq::Testing.inline! block — goes to the real cluster under that
  #    model's DEFAULT index name, and nothing cleans it up. Locally ELASTICSEARCH_HOST
  #    is the same localhost:9200 as .env.development, so that would quietly write test
  #    documents into your dev indices. Pass every model whose index the test can touch.
  # 2. The namespace assumes one process. It keeps concurrent local runs apart because
  #    each has its own TEST_DATABASE_NAME, but if Rails `parallelize` is ever turned on
  #    for this suite, in-job workers would share one namespace and each test's
  #    create_index!(force: true) would wipe indices out from under its siblings.
  #    Revisit the naming before enabling parallelize.
  def install_real_elasticsearch!(models)
    @es_models = models
    @prev_index_names = models.index_with { |model| model.index_name }
    Thread.current[:minitest_real_es] = RealElasticsearchBridge.real_client
    models.each do |model|
      model.index_name("minitest-#{ENV.fetch('TEST_DATABASE_NAME', 'test')}-#{model.name.parameterize}")
      model.__elasticsearch__.create_index!(force: true)
    end
  end

  def restore_fake_elasticsearch!
    return unless @es_models
    @es_models.each do |model|
      begin
        model.__elasticsearch__.delete_index!
      rescue StandardError
        # index may already be gone; ignore
      end
      model.index_name(@prev_index_names[model])
    end
    Thread.current[:minitest_real_es] = nil
    @es_models = nil
  end

  def recreate_model_index(model)
    model.__elasticsearch__.create_index!(force: true)
  end

  def index_model_records(model)
    model.import(refresh: true, force: true)
  rescue Elasticsearch::Transport::Transport::Errors::BadRequest => e
    raise unless e.message.include?("resource_already_exists_exception")
    model.import(refresh: true)
  end
end
