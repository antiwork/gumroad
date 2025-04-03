# frozen_string_literal: true

require "spec_helper"

describe ElasticsearchIndexerWorker, :elasticsearch_wait_for_refresh do
  describe "#perform without ActiveRecord objects" do
    before do
      class TravelEvent
        include Elasticsearch::Model
        index_name "test_travel_events"
      end
      EsClient.indices.delete(index: TravelEvent.index_name, ignore: [404])
      class FinancialEvent
        include Elasticsearch::Model
        index_name "test_financial_events"
        def self.index_name_from_body(body)
          "#{index_name}-#{body["timestamp"].first(7)}"
        end
      end
      EsClient.indices.delete(index: "#{FinancialEvent.index_name}*", ignore: [404])
    end

    context "when indexing" do
      it "creates a document with the specified body" do
        id = SecureRandom.uuid
        described_class.new.perform(
          "index",
          "class_name" => "TravelEvent",
          "id" => id,
          "body" => {
            "destination" => "Paris",
            "timestamp" => "2021-07-20T01:02:03Z"
          }
        )
        expect(EsClient.get(index: TravelEvent.index_name, id:).fetch("_source")).to eq(
          "destination" => "Paris",
          "timestamp" => "2021-07-20T01:02:03Z"
        )
      end

      it "creates a document in an index which name is specified dynamically" do
        id = SecureRandom.uuid
        described_class.new.perform(
          "index",
          "class_name" => "FinancialEvent",
          "id" => id,
          "body" => {
            "stock" => "TSLA",
            "timestamp" => "2021-12-01T01:02:03Z"
          }
        )
        expect(EsClient.get(index: "#{FinancialEvent.index_name}-2021-12", id:).fetch("_source")).to eq(
          "stock" => "TSLA",
          "timestamp" => "2021-12-01T01:02:03Z"
        )
      end
    end
  end

  describe "#perform with ActiveRecord objects" do
    before do
      @client = EsClient.dup
      @model = create_mock_model do |t|
        t.string :name
        t.string :country
        t.string :ip_country
      end
      @model.class_eval <<-RUBY, __FILE__, __LINE__ + 1
        include Elasticsearch::Model
        include SearchIndexModelCommon
        index_name "test_products"
        mapping do
          indexes :name, type: :keyword
          indexes :country, type: :keyword
          indexes :has_long_title, type: :boolean
        end
        def search_field_value(field_name)
          case field_name
          when "name", "country" then attributes[field_name]
          when "has_long_title" then true
          end
        end
      RUBY
      EsClient.indices.delete(index: @model.index_name, ignore: [404])
    end

    after do
      destroy_mock_model(@model)
    end

    context "when indexing" do
      before do
        @record = @model.create!(name: "Drawing")
      end

      it "creates a document" do
        described_class.new.perform(
          "index",
          "class_name" => @model.name,
          "record_id" => @record.id
        )
        expect(get_document_attributes).to eq(
          "country" => nil,
          "name" => "Drawing",
          "has_long_title" => true,
        )
      end
    end

    context "when updating" do
      before do
        @record = @model.create!(name: "Drawing", country: "France")
      end

      context "an existing document" do
        before do
          @client.index(
            index: @model.index_name,
            id: @record.id,
            body: {
              "name" => "Drawing",
              "country" => "Japan"
            }
          )
        end

        it "updates the document" do
          described_class.new.perform(
            "update",
            "class_name" => @model.name,
            "record_id" => @record.id,
            "fields" => ["name", "has_long_title", "country"]
          )
          expect(get_document_attributes).to eq(
            "name" => "Drawing",
            "has_long_title" => true,
            "country" => "France"
          )
        end
      end

      context "a non-existing document" do
        subject(:perform) do
          described_class.new.perform(
            "update",
            "class_name" => @model.name,
            "record_id" => @record.id,
            "fields" => ["name", "has_long_title"]
          )
        end

        it "raises an error" do
          expect { perform }.to raise_error(/document_missing_exception/)
        end

        context "while ignoring 404 errors from index" do
          before do
            $redis.sadd(RedisKey.elasticsearch_indexer_worker_ignore_404_errors_on_indices, @model.index_name)
          end

          it "does not raise an error and ignores the request" do
            expect { perform }.not_to raise_error
            expect(get_document_attributes).to eq(nil)
          end
        end
      end
    end

    context "when updating by query" do
      before do
        @model.mapping do
          indexes :country, type: :keyword
          indexes :some_array_field, type: :long
          indexes :some_string_field, type: :keyword
          indexes :some_boolean_field, type: :boolean
          indexes :some_integer_field, type: :long
          indexes :null_field, type: :keyword
        end
        @model.__elasticsearch__.create_index!
        @source_record = @model.create!(country: "United States")
        @source_record.define_singleton_method(:search_field_value) do |field_name|
          case field_name
          when "some_array_field" then [1, 2, 3]
          when "some_string_field" then "foobar"
          when "some_boolean_field" then true
          when "some_integer_field" then 456
          when "some_unsupported_type_field" then {}
          when "null_field" then nil
          end
        end
        allow(@model).to receive(:find).with(@source_record.id).and_return(@source_record)

        @record_2 = @model.create!(country: "United States")
        @record_3 = @model.create!(country: "France")
        @record_4 = @model.create!(country: "United States")

        [@source_record, @record_2, @record_3, @record_4].each do |record|
          record.__elasticsearch__.index_document
        end

        # To be able to test that a `null` value can be actually set for a field, we need to first set a value to it.
        [@record_2, @record_3].each do |record|
          @client.update(
            index: @model.index_name,
            id: record.id,
            body: { doc: { null_field: "some string" } }
          )
        end
      end

      it "updates values matching the query" do
        expect(EsClient).not_to receive(:search)
        expect(EsClient).not_to receive(:scroll)
        expect(EsClient).not_to receive(:clear_scroll)

        described_class.new.perform(
          "update_by_query",
          "class_name" => @model.name,
          "source_record_id" => @source_record.id,
          "query" => { "term" => { "country" => "United States" } },
          "fields" => %w[some_array_field some_string_field some_boolean_field some_integer_field null_field]
        )

        [get_document_attributes(@record_2), get_document_attributes(@record_4)].each do |attrs|
          expect(attrs["some_array_field"]).to eq([1, 2, 3])
          expect(attrs["some_string_field"]).to eq("foobar")
          expect(attrs["some_boolean_field"]).to eq(true)
          expect(attrs["some_integer_field"]).to eq(456)
          expect(attrs["null_field"]).to eq(nil)
        end

        attrs = get_document_attributes(@record_3)
        expect(attrs["some_array_field"]).to eq(nil)
        expect(attrs["some_string_field"]).to eq(nil)
        expect(attrs["some_boolean_field"]).to eq(nil)
        expect(attrs["some_integer_field"]).to eq(nil)
        expect(attrs["null_field"]).to eq("some string")
      end

      it "scrolls through results if the first query fails" do
        stub_const("#{described_class}::UPDATE_BY_QUERY_SCROLL_SIZE", 1)
        expect(EsClient).to receive(:update_by_query).once.and_raise(Elasticsearch::Transport::Transport::Errors::Conflict.new)
        expect(EsClient).to receive(:search).and_call_original
        expect(EsClient).to receive(:scroll).twice.and_call_original
        expect(EsClient).to receive(:update_by_query).twice.and_call_original
        expect(EsClient).to receive(:clear_scroll).and_call_original

        described_class.new.perform(
          "update_by_query",
          "class_name" => @model.name,
          "source_record_id" => @source_record.id,
          "query" => { "term" => { "country" => "United States" } },
          "fields" => %w[some_array_field some_string_field some_boolean_field some_integer_field null_field]
        )

        [get_document_attributes(@record_2), get_document_attributes(@record_4)].each do |attrs|
          expect(attrs["some_string_field"]).to eq("foobar")
        end
      end

      it "handles conflicts when updating scrolled results" do
        stub_const("#{described_class}::UPDATE_BY_QUERY_SCROLL_SIZE", 1)
        expect(EsClient).to receive(:update_by_query).twice.and_raise(Elasticsearch::Transport::Transport::Errors::Conflict.new)
        expect(EsClient).to receive(:search).and_call_original
        expect(EsClient).to receive(:scroll).twice.and_call_original
        expect(EsClient).to receive(:update_by_query).twice.times.and_call_original
        expect(EsClient).to receive(:clear_scroll).and_call_original

        instance = described_class.new
        expect(instance).to receive(:update_by_query_ids).twice.and_call_original
        instance.perform(
          "update_by_query",
          "class_name" => @model.name,
          "source_record_id" => @source_record.id,
          "query" => { "term" => { "country" => "United States" } },
          "fields" => %w[some_array_field some_string_field some_boolean_field some_integer_field null_field]
        )

        [get_document_attributes(@record_2), get_document_attributes(@record_4)].each do |attrs|
          expect(attrs["some_string_field"]).to eq("foobar")
        end
      end

      it "does not support nested fields", elasticsearch_wait_for_refresh: false do
        expect do
          described_class.new.perform(
            "update_by_query",
            "class_name" => @model.name,
            "source_record_id" => @source_record.id,
            "query" => { "term" => { "country" => "United States" } },
            "fields" => %w[user.flags]
          )
        end.to raise_error(/nested fields.*not supported/)
      end
    end

    context "when deleting" do
      before do
        @record = @model.create!(name: "Drawing")
      end

      context "an existing document" do
        before do
          @client.index(
            index: @model.index_name,
            id: @record.id,
            body: {
              "name" => "Drawing"
            }
          )
        end

        it "deletes the document" do
          described_class.new.perform(
            "delete",
            "class_name" => @model.name,
            "record_id" => @record.id
          )
          expect(get_document_attributes).to eq(nil)
        end
      end

      context "a non-existing document" do
        subject(:perform) do
          described_class.new.perform(
            "delete",
            "class_name" => @model.name,
            "record_id" => @record.id
          )
        end

        it "does not raise an error" do
          expect { perform }.not_to raise_error
        end
      end
    end
  end

  describe ".columns_to_fields" do
    it "returns matching fields" do
      mapping = { "a" => ["a", "a_and_b"], "b" => "a_and_b", "d" => "d" }
      expect(described_class.columns_to_fields(["a", "c"], mapping:)).to eq(["a", "a_and_b"])
      expect(described_class.columns_to_fields(["c"], mapping:)).to eq([])
      expect(described_class.columns_to_fields(["b", "d"], mapping:)).to eq(["a_and_b", "d"])
      expect(described_class.columns_to_fields(["a", "b"], mapping:)).to eq(["a", "a_and_b"])
    end
  end

  def get_document_attributes(record = @record)
    @client.get(index: @model.index_name, id: record.id).fetch("_source")
  rescue Elasticsearch::Transport::Transport::Errors::NotFound => _
  end
end
