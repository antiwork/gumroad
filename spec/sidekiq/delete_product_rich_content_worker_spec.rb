# frozen_string_literal: true

require "spec_helper"

describe DeleteProductRichContentWorker do
  describe "#perform", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    context "without versions" do
      before do
        @product_rich_content = create(:product_rich_content, entity: product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])
      end

      context "when product is deleted" do
        let(:product) { create(:product, deleted_at: 1.minute.ago) }

        it "deletes the product's rich content" do
          expect do
            described_class.new.perform(product.id)
          end.to change { product.alive_rich_contents.count }.by(-1)
        end
      end

      context "when product is alive" do
        let(:product) { create(:product) }

        it "does not delete any rich content objects" do
          expect do
            described_class.new.perform(product.id)
          end.to_not change { product.alive_rich_contents.count }
        end
      end
    end

    context "with versions" do
      let(:product) { create(:product) }
      let(:variant_category) { create(:variant_category, link: product) }

      context "when versions are deleted" do
        before do
          @version_1 = create(:variant, variant_category:, name: "Version 1", deleted_at: 1.minute.ago)
          @version_2 = create(:variant, variant_category:, name: "Version 2", deleted_at: 1.minute.ago)
          @version_3 = create(:variant, variant_category:, name: "Version 3")
          create(:rich_content, entity: @version_1, description: [{ "type" => "paragraph", "content" => [{ "text" => "This is Version 1 content", "type" => "text" }] }])
          create(:rich_content, entity: @version_2, description: [{ "type" => "paragraph", "content" => [{ "text" => "This is Version 2 content", "type" => "text" }] }])
          create(:rich_content, entity: @version_3, description: [{ "type" => "paragraph", "content" => [{ "text" => "This is Version 3 content", "type" => "text" }] }])
          create(:purchase, link: product, variant_attributes: [@version_1])
        end

        it "soft-deletes rich content from variants" do
          freeze_time do
            expect do
              described_class.new.perform(product.id)
            end.to change { RichContent.count }.by(0)
                .and change { RichContent.alive.count }.by(-2)

            expect(@version_1.rich_contents.count).to eq(1)
            expect(@version_1.alive_rich_contents.count).to eq(0)
            expect(@version_2.rich_contents.count).to eq(1)
            expect(@version_2.alive_rich_contents.count).to eq(0)
            expect(@version_3.rich_contents.count).to eq(1)
            expect(@version_3.alive_rich_contents.count).to eq(1)
          end
        end
      end

      context "when versions are alive" do
        before do
          @version = create(:variant, variant_category:, name: "Version")
          create(:rich_content, entity: @version, description: [{ "type" => "paragraph", "content" => [{ "text" => "This is Version content", "type" => "text" }] }])
        end

        it "does not delete any rich content objects" do
          expect do
            described_class.new.perform(product.id)
          end.to change { RichContent.count }.by(0)
          .and change { @version.alive_rich_contents.count }.by(0)
        end
      end
    end

    context "for tiered memberships" do
      let(:product) { create(:membership_product) }
      let(:variant_category) { product.tier_category }

      context "when tiers are deleted" do
        before do
          @version_1 = variant_category.variants.first
          @version_1.update!(deleted_at: 1.minute.ago)
          @version_2 = create(:variant, variant_category:, name: "Tier 2", deleted_at: 1.minute.ago)
          @version_3 = create(:variant, variant_category:, name: "Version 3")
          @rich_content = create(:rich_content, entity: @version_1, description: [{ "type" => "paragraph", "content" => [{ "text" => "This is Tier 1 content", "type" => "text" }] }])
          create(:rich_content, entity: @version_2, description: [{ "type" => "paragraph", "content" => [{ "text" => "This is Tier 2 content", "type" => "text" }] }])
          create(:rich_content, entity: @version_3, description: [{ "type" => "paragraph", "content" => [{ "text" => "This is Tier 3 content", "type" => "text" }] }])
          create(:purchase, link: product, variant_attributes: [@version_1])
        end

        it "soft-deletes rich content from tiers" do
          freeze_time do
            expect do
              described_class.new.perform(product.id)
            end.to change { RichContent.count }.by(0)
              .and change { RichContent.alive.count }.by(-2)

            expect(@rich_content.reload.deleted_at).to eq(Time.current)
            expect(@version_1.rich_contents.count).to eq(1)
            expect(@version_1.alive_rich_contents.count).to eq(0)
            expect(@version_2.rich_contents.count).to eq(1)
            expect(@version_2.alive_rich_contents.count).to eq(0)
            expect(@version_3.rich_contents.count).to eq(1)
            expect(@version_3.alive_rich_contents.count).to eq(1)
          end
        end
      end

      context "when versions are alive" do
        before do
          @version_1 = create(:variant, variant_category:, name: "Version 1")
          @version_2 = create(:variant, variant_category:, name: "Version 2")
          create(:rich_content, entity: @version_1, description: [{ "type" => "paragraph", "content" => [{ "text" => "This is Version 1 content", "type" => "text" }] }])
          create(:rich_content, entity: @version_2, description: [{ "type" => "paragraph", "content" => [{ "text" => "This is Version 2 content", "type" => "text" }] }])
        end

        it "does not delete any rich content objects" do
          expect do
            described_class.new.perform(product.id)
          end.to_not change { RichContent.count }

          expect(@version_1.alive_rich_contents.count).to eq(1)
          expect(@version_2.alive_rich_contents.count).to eq(1)
        end
      end
    end
  end
end
