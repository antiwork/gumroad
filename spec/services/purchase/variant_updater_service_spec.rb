# frozen_string_literal: true

require "spec_helper"

describe Purchase::VariantUpdaterService do
  describe ".perform" do
    context "when the product has variants" do
      before :each do
        @product = create(:product)
        @category1 = create(:variant_category, link: @product, title: "Color")
        category2 = create(:variant_category, link: @product, title: "Size")
        @blue_variant = create(:variant, variant_category: @category1, name: "Blue")
        @green_variant = create(:variant, variant_category: @category1, name: "Green")
        @small_variant = create(:variant, variant_category: category2, name: "Small")
      end

      context "and the purchase has a variant for the category" do
        it "updates the variant" do
          purchase = create(
            :purchase,
            link: @product,
            variant_attributes: [@blue_variant, @small_variant]
          )

          success = Purchase::VariantUpdaterService.new(
            purchase:,
            variant_id: @green_variant.external_id,
            quantity: purchase.quantity,
          ).perform

          expect(success).to be true
          expect(purchase.reload.variant_attributes).to match_array [@green_variant, @small_variant]
        end
      end

      context "and the purchase doesn't have a variant for the category" do
        it "adds the variant" do
          purchase = create(
            :purchase,
            link: @product,
            variant_attributes: [@small_variant]
          )

          success = Purchase::VariantUpdaterService.new(
            purchase:,
            variant_id: @green_variant.external_id,
            quantity: purchase.quantity,
          ).perform

          expect(success).to be true
          expect(purchase.reload.variant_attributes).to match_array [@small_variant, @green_variant]
        end
      end

      context "and there is insufficient inventory" do
        context "when switching variants" do
          it "returns an error" do
            red_variant = create(:variant, variant_category: @category1, name: "Red", max_purchase_count: 1)

            purchase = create(
              :purchase,
              link: @product,
              quantity: 2,
              variant_attributes: [@small_variant]
            )

            success = Purchase::VariantUpdaterService.new(
              purchase:,
              variant_id: red_variant.external_id,
              quantity: purchase.quantity,
            ).perform

            expect(success).to be false
            purchase.reload
            expect(purchase.variant_attributes).to eq [@small_variant]
            expect(purchase.quantity).to eq 2
          end
        end

        context "when not switching variants" do
          it "returns an error" do
            purchase = create(
              :purchase,
              link: @product,
              quantity: 2,
              variant_attributes: [@small_variant]
            )
            @small_variant.update!(max_purchase_count: 3)

            success = Purchase::VariantUpdaterService.new(
              purchase:,
              variant_id: @small_variant.external_id,
              quantity: 4,
            ).perform

            expect(success).to be false
            expect(purchase.reload.quantity).to eq 2
          end
        end
      end

      context "gift sender purchase" do
        let(:gift_sender_purchase) do
          create(
            :purchase,
            link: @product,
            variant_attributes: [@blue_variant],
            is_gift_sender_purchase: true
          )
        end
        let(:gift_receiver_purchase) do
          create(
            :purchase,
            link: @product,
            variant_attributes: [@blue_variant],
            is_gift_receiver_purchase: true,
          )
        end

        before do
          create(:gift, gifter_purchase: gift_sender_purchase, giftee_purchase: gift_receiver_purchase)
          gift_sender_purchase.reload
          gift_receiver_purchase.reload
        end

        it "invokes the service on the gift receiver purchase" do
          allow(Purchase::VariantUpdaterService).to receive(:new).and_call_original

          expect(Purchase::VariantUpdaterService).to receive(:new).with(
            purchase: gift_receiver_purchase,
            variant_id: @green_variant.external_id,
            quantity: 1,
          ).and_call_original

          success = Purchase::VariantUpdaterService.new(
            purchase: gift_sender_purchase,
            variant_id: @green_variant.external_id,
            quantity: 1,
          ).perform

          expect(success).to be true
          expect(gift_sender_purchase.reload.variant_attributes).to eq [@green_variant]
          expect(gift_receiver_purchase.reload.variant_attributes).to eq [@green_variant]
        end
      end
    end

    context "when the product has SKUs" do
      before :each do
        @product = create(:physical_product)
        create(:variant_category, link: @product, title: "Color")
        create(:variant_category, link: @product, title: "Size")
        @large_blue_sku = create(:sku, link: @product, name: "Blue - large")
        @small_green_sku = create(:sku, link: @product, name: "Green - small")
      end

      context "and the purchase has a SKU" do
        it "updates the SKU" do
          purchase = create(
            :physical_purchase,
            link: @product,
            variant_attributes: [@large_blue_sku]
          )

          success = Purchase::VariantUpdaterService.new(
            purchase:,
            variant_id: @small_green_sku.external_id,
            quantity: purchase.quantity,
          ).perform

          expect(success).to be true
          expect(purchase.reload.variant_attributes).to eq [@small_green_sku]
        end
      end

      context "and the purchase doesn't have a SKU" do
        it "adds the SKU" do
          purchase = create(
            :physical_purchase,
            link: @product
          )

          success = Purchase::VariantUpdaterService.new(
            purchase:,
            variant_id: @small_green_sku.external_id,
            quantity: purchase.quantity,
          ).perform

          expect(success).to be true
          expect(purchase.reload.variant_attributes).to eq [@small_green_sku]
        end
      end

      context "and there is insufficient inventory" do
        it "returns an error" do
          medium_green_sku = create(:sku, link: @product, name: "Green - medium", max_purchase_count: 1)

          purchase = create(
            :physical_purchase,
            link: @product,
            quantity: 2,
            variant_attributes: [@large_blue_sku]
          )

          success = Purchase::VariantUpdaterService.new(
            purchase:,
            variant_id: medium_green_sku.external_id,
            quantity: purchase.quantity,
          ).perform

          expect(success).to be false
          expect(purchase.reload.variant_attributes).to eq [@large_blue_sku]
        end
      end
    end

    context "inventory counter caches" do
      before { @product = create(:product) }

      it "moves the cached sales count from the old variant to the new one when only the variant changes" do
        category = create(:variant_category, link: @product, title: "Color")
        blue = create(:variant, variant_category: category, name: "Blue")
        green = create(:variant, variant_category: category, name: "Green")

        purchase = create(:purchase, link: @product, variant_attributes: [blue])
        blue.reload
        green.reload
        blue_before = blue.sales_count_for_inventory_cache.to_i
        green_before = green.sales_count_for_inventory_cache.to_i

        Purchase::VariantUpdaterService.new(purchase:, variant_id: green.external_id, quantity: purchase.quantity).perform

        expect(blue.reload.sales_count_for_inventory_cache.to_i).to eq(blue_before - purchase.quantity)
        expect(green.reload.sales_count_for_inventory_cache.to_i).to eq(green_before + purchase.quantity)
      end

      it "reconciles caches when the variant and quantity both change" do
        category = create(:variant_category, link: @product, title: "Color")
        blue = create(:variant, variant_category: category, name: "Blue")
        green = create(:variant, variant_category: category, name: "Green")

        purchase = create(:purchase, link: @product, variant_attributes: [blue], quantity: 1)
        blue.reload
        green.reload
        blue_before = blue.sales_count_for_inventory_cache.to_i
        green_before = green.sales_count_for_inventory_cache.to_i

        Purchase::VariantUpdaterService.new(purchase:, variant_id: green.external_id, quantity: 3).perform

        expect(blue.reload.sales_count_for_inventory_cache.to_i).to eq(blue_before - 1)
        expect(green.reload.sales_count_for_inventory_cache.to_i).to eq(green_before + 3)
      end
    end

    context "with invalid arguments" do
      context "such as an invalid variant_id" do
        it "returns an error" do
          purchase = create(:purchase)

          success = Purchase::VariantUpdaterService.new(
            purchase:,
            variant_id: "fake-id",
            quantity: purchase.quantity,
          ).perform

          expect(success).to be false
        end
      end

      context "such as a variant that doesn't belong to the right product" do
        it "returns an error" do
          purchase = create(:purchase)
          variant = create(:variant)

          success = Purchase::VariantUpdaterService.new(
            purchase:,
            variant_id: variant.external_id,
            quantity: purchase.quantity,
          ).perform

          expect(success).to be false
        end
      end
    end
    context "when the new variant's content carries a license-key block" do
      let(:product) { create(:product, is_licensed: true) }
      let(:category) { create(:variant_category, link: product, title: "Tier") }
      let(:free_variant) { create(:variant, variant_category: category, name: "Free Version") }
      let(:full_variant) { create(:variant, variant_category: category, name: "Full Version") }

      before do
        create(:rich_content, entity: free_variant, description: [{ "type" => "paragraph" }])
        create(:rich_content, entity: full_variant, description: [{ "type" => RichContent::LICENSE_KEY_NODE_TYPE }])
      end

      it "mints the license the purchase had suppressed" do
        purchase = create(:purchase, link: product, variant_attributes: [free_variant])
        expect(purchase.license).to be_nil

        success = Purchase::VariantUpdaterService.new(
          purchase:,
          variant_id: full_variant.external_id,
          quantity: purchase.quantity,
        ).perform

        expect(success).to be true
        expect(purchase.reload.uses_license_key?).to be true
        expect(purchase.license).to be_present
        expect(purchase.license.serial).to be_present
        expect(product.reload.licenses).to include(purchase.license)
      end

      it "keeps the existing license when the purchase already has one" do
        other_full_variant = create(:variant, variant_category: category, name: "Full Version 2")
        create(:rich_content, entity: other_full_variant, description: [{ "type" => RichContent::LICENSE_KEY_NODE_TYPE }])
        purchase = create(:purchase, link: product, variant_attributes: [full_variant])
        existing = purchase.create_license!
        expect(existing).to be_present

        Purchase::VariantUpdaterService.new(
          purchase:,
          variant_id: other_full_variant.external_id,
          quantity: purchase.quantity,
        ).perform

        expect(purchase.reload.uses_license_key?).to be true
        expect(purchase.license).to eq(existing)
        expect(License.where(purchase_id: purchase.id).count).to eq(1)
      end

      it "does not mint a license when the new variant's content omits the block" do
        purchase = create(:purchase, link: product, variant_attributes: [full_variant])

        Purchase::VariantUpdaterService.new(
          purchase:,
          variant_id: free_variant.external_id,
          quantity: purchase.quantity,
        ).perform

        expect(purchase.reload.uses_license_key?).to be false
        expect(purchase.license).to be_nil
      end

      it "backfills the license onto the original purchase when a recurring charge is swapped" do
        subscription = create(:subscription, link: product)
        original = create(:purchase, link: product, subscription:, is_original_subscription_purchase: true,
                                     variant_attributes: [free_variant])
        charge = create(:purchase, link: product, subscription:, is_original_subscription_purchase: false,
                                   variant_attributes: [free_variant])
        expect(charge.is_recurring_subscription_charge).to be true

        expect do
          Purchase::VariantUpdaterService.new(
            purchase: charge,
            variant_id: full_variant.external_id,
            quantity: charge.quantity,
          ).perform
        end.to change { License.count }.by(1)

        expect(License.where(purchase_id: charge.id)).to be_empty
        expect(original.reload.license).to be_present
        expect(charge.reload.license).to eq(original.license)

        license_pushes = ElasticsearchIndexerWorker.jobs.map { |job| job["args"] }
          .select { |action, params| action == "update" && params["fields"] == ["license_serial", "license_uses"] }
        expect(license_pushes.map { |_, params| params["record_id"] }).to match_array([charge.id, original.id])
      end

      it "does not mint a duplicate when another request minted the license after the stale check" do
        purchase = create(:purchase, link: product, variant_attributes: [full_variant])
        purchase.license # cache the association as absent
        Purchase.find(purchase.id).create_license!

        expect { purchase.create_license! }.not_to change { License.count }
      end
    end
  end
end
