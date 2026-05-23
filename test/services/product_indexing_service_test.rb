# frozen_string_literal: true

require "test_helper"

class ProductIndexingServiceTest < ActiveSupport::TestCase
  self.described_class = ProductIndexingService



  context_ ProductIndexingService do
    before do
      @product = create(:product)
    end

  context_ "#perform" do
  test "can index documents" do
        # Empty the index for the purpose of this test
        recreate_model_indices(Link)

        described_class.perform(product: @product, action: "index")

        Link.__elasticsearch__.refresh_index!
        # This would have raised Elasticsearch::Transport::Transport::Errors::NotFound if the document wasn't found
        expect { EsClient.get(index: Link.index_name, id: @product.id) }.not_to raise_error
      end

  test "can update documents" do
        Link.__elasticsearch__.refresh_index!
        # Change the name without triggering callbacks for the purpose of this test
        @product.update_column(:name, "updated name")

        described_class.perform(product: @product, action: "update", attributes_to_update: ["name"])

        Link.__elasticsearch__.refresh_index!
        expect(EsClient.get(index: Link.index_name, id: @product.id).dig("_source", "name")).to eq("updated name")
      end

  test "raises error on failure" do
        # Empty the index for the purpose of this test
        recreate_model_indices(Link)

        expect do
          described_class.perform(product: @product, action: "update", attributes_to_update: ["name"])
        end.to raise_error(Elasticsearch::Transport::Transport::Errors::NotFound)
      end

  context_ "when on_failure = :async" do
  test "queues a sidekiq job and does not raise an error" do
          # Empty the index for the purpose of this test
          recreate_model_indices(Link)

          expect do
            described_class.perform(product: @product, action: "update", attributes_to_update: ["name"], on_failure: :async)
          end.not_to raise_error

          expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(@product.id, "update", ["name"])
        end
      end
    end
  end
end
