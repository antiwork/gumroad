# frozen_string_literal: true

require "test_helper"

class ElasticsearchModelAsyncCallbacksTest < ActiveSupport::TestCase
  self.described_class = ElasticsearchModelAsyncCallbacks


  context_ ElasticsearchModelAsyncCallbacks do
    before do
      @model = create_mock_model
      @model.include(described_class)
      @model.const_set("ATTRIBUTE_TO_SEARCH_FIELDS", "title" => "title")
      @multiplier = 2 # we're queuing index and updates jobs twice to mitigate replica lag issues
    end

    after do
      destroy_mock_model(@model)
    end

  context_ "record creation" do
  test "enqueues sidekiq job" do
        @record = @model.create!(title: "original")

        expect(ElasticsearchIndexerWorker.jobs.size).to eq(1 * @multiplier)
        expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job("index", "record_id" => @record.id, "class_name" => @model.name)
      end

  test "enqueues sidekiq job even if no permitted value has changed" do
        @record = @model.create!

        expect(ElasticsearchIndexerWorker.jobs.size).to eq(1 * @multiplier)
        expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job("index", "record_id" => @record.id, "class_name" => @model.name)
      end
    end

  context_ "record update" do
      before do
        @record = @model.create!
        ElasticsearchIndexerWorker.jobs.clear
      end

  test "enqueues sidekiq job" do
        @record.update!(title: "new", subtitle: "new")

        expect(ElasticsearchIndexerWorker.jobs.size).to eq(1 * @multiplier)
        expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job("update", "record_id" => @record.id, "fields" => ["title"], "class_name" => @model.name)
      end

  test "enqueues single sidekiq job when multiple attributes are saved separately in the same transaction" do
        @model::ATTRIBUTE_TO_SEARCH_FIELDS.merge!({ "subtitle" => "subtitle" })

        ApplicationRecord.transaction do
          @record.update!(title: "new")
          @record.update!(subtitle: "new")
        end

        expect(ElasticsearchIndexerWorker.jobs.size).to eq(1 * @multiplier)
        expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job("update", "record_id" => @record.id, "fields" => ["title", "subtitle"], "class_name" => @model.name)
      end

  test "does not queue sidekiq jobs for ES indexing if no permitted column values have changed" do
        @record.update!(user_id: 1)
        expect(ElasticsearchIndexerWorker.jobs).to be_empty

        @record.update!(subtitle: "new")
        expect(ElasticsearchIndexerWorker.jobs.size).to eq(0)
      end
    end

  context_ "record deletion" do
      before do
        @record = @model.create!
        ElasticsearchIndexerWorker.jobs.clear
      end

  test "queues sidekiq job" do
        @record.destroy!

        expect(ElasticsearchIndexerWorker.jobs.size).to eq(1)
        expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job("delete", "record_id" => @record.id, "class_name" => @model.name)
      end
    end
  end
end
