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
  end
end
