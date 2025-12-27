# frozen_string_literal: true

require "spec_helper"

describe Product::VariantCategoryUpdaterService do
  describe ".perform" do
    context "when trying to update a variant from another product" do
      let(:product) { create(:product) }
      let(:other_product) { create(:product) }
      let(:variant) { create(:variant, variant_category: create(:variant_category, link: product)) }
      let(:other_variant) { create(:variant, variant_category: create(:variant_category, link: other_product)) }
      let(:variant_category_params) do
        {
          id: variant.variant_category.external_id, title: variant.variant_category.title,
          options: [
            {
              id: other_variant.external_id,
              name: other_variant.name,
            }
          ]
        }
      end

      it "raises an error and does not update the variant" do
        expect { Product::VariantCategoryUpdaterService.new(product: product, category_params: variant_category_params).perform }.to raise_error(ActiveRecord::RecordNotFound)
        expect(variant.reload.name).not_to eq other_variant.name
      end
    end

    describe "notifying subscribers of price changes" do
      let(:product) { create(:product) }
      let(:was_applying_price_changes_to_existing_memberships) { false }
      let(:was_subscription_price_change_effective_date) { 10.days.from_now.to_date }
      let(:variant) do
        create(
          :variant,
          variant_category: create(:variant_category, link: product),
          apply_price_changes_to_existing_memberships: was_applying_price_changes_to_existing_memberships,
          subscription_price_change_effective_date: was_subscription_price_change_effective_date
        )
      end

      let(:variant_category_params) do
        {
          id: variant.variant_category.external_id,
          title: variant.variant_category.title,
          options: [
            {
              id: variant.external_id,
              name: variant.name,
              apply_price_changes_to_existing_memberships:,
              subscription_price_change_effective_date:,
            }
          ]
        }
      end

      context "when apply_price_changes_to_existing_memberships is enabled and the effective date changed" do
        let(:apply_price_changes_to_existing_memberships) { true }
        let(:subscription_price_change_effective_date) { 7.days.from_now.to_date }

        it "schedules ScheduleMembershipPriceUpdatesJob" do
          expect(ScheduleMembershipPriceUpdatesJob).to receive(:perform_async).with(variant.id)

          Product::VariantCategoryUpdaterService.new(product: product, category_params: variant_category_params).perform
        end
      end

      context "when disabling apply_price_changes_to_existing_memberships" do
        let(:was_applying_price_changes_to_existing_memberships) { true }
        let(:apply_price_changes_to_existing_memberships) { false }
        let(:subscription_price_change_effective_date) { was_subscription_price_change_effective_date }

        it "does not schedule ScheduleMembershipPriceUpdatesJob" do
          expect(ScheduleMembershipPriceUpdatesJob).not_to receive(:perform_async).with(variant.id)
        end

        context "when the flags previously changed" do
          it "notifies Bugsnag" do
            expect(Bugsnag).to receive(:notify).with("Not notifying subscribers of membership price change - tier: #{variant.id}; apply_price_changes_to_existing_memberships: false; subscription_price_change_effective_date: #{was_subscription_price_change_effective_date}")

            Product::VariantCategoryUpdaterService.new(product: product, category_params: variant_category_params).perform
          end
        end

        context "when the effective date previously changed" do
          let(:was_applying_price_changes_to_existing_memberships) { false }
          let(:apply_price_changes_to_existing_memberships) { false }
          let(:was_subscription_price_change_effective_date) { 7.days.from_now.to_date }
          let(:subscription_price_change_effective_date) { 10.days.from_now.to_date }

          it "notifies Bugsnag" do
            expect(Bugsnag).to receive(:notify).with("Not notifying subscribers of membership price change - tier: #{variant.id}; apply_price_changes_to_existing_memberships: false; subscription_price_change_effective_date: #{subscription_price_change_effective_date}")

            Product::VariantCategoryUpdaterService.new(product: product, category_params: variant_category_params).perform
          end
        end
      end

      context "when changing the effective date and apply_price_changes_to_existing_memberships is already enabled" do
        let(:was_applying_price_changes_to_existing_memberships) { true }
        let(:apply_price_changes_to_existing_memberships) { true }
        let(:subscription_price_change_effective_date) { 7.days.from_now.to_date }

        it "schedules ScheduleMembershipPriceUpdatesJob" do
          expect(ScheduleMembershipPriceUpdatesJob).to receive(:perform_async).with(variant.id)

          Product::VariantCategoryUpdaterService.new(product: product, category_params: variant_category_params).perform
        end
      end
    end

    context "when associating files" do
      before do
        @product = create(:product)
        vc = create(:variant_category, link: @product)
        @variant = create(:variant, variant_category: vc)
        @file1 = create(:product_file, link: @product)
        @file2 = create(:product_file, link: @product)
        @variant.product_files << @file1

        @variant_category_params = {
          title: vc.title,
          id: vc.external_id,
          options: [
            {
              id: @variant.external_id,
              name: @variant.name,
              rich_content: [{ id: nil, title: "Page title", description: [@file1, @file2].map { { type: "fileEmbed", attrs: { id: _1.external_id, uid: SecureRandom.uuid } } } }],
            }
          ]
        }
      end

      it "saves new files on versions" do
        Product::VariantCategoryUpdaterService.new(
          product: @product,
          category_params: @variant_category_params
        ).perform

        expect(@variant.reload.product_files).to match_array [@file1, @file2]
      end

      context "when versions are removed" do
        it "marks them as deleted and queues a DeleteProductRichContentWorker" do
          freeze_time do
            expect do
              Product::VariantCategoryUpdaterService.new(
                product: @product,
                category_params: { id: @variant.variant_category.external_id, title: "" },
                ).perform
            end.to change { @variant.reload.deleted_at }.from(nil).to(Time.current)

            expect(DeleteProductRichContentWorker).to have_enqueued_sidekiq_job(@product.id, @variant.id)
          end
        end
      end
    end

    context "for tiered memberships" do
      before :each do
        @product = create(:membership_product)
        @effective_date = 7.days.from_now.to_date
        @variant_category_params = {
          title: "Tier",
          id: @product.tier_category.external_id,
          options: [
            {
              name: "First Tier",
              description: nil,
              price_difference: nil,
              max_purchase_count: 10,
              id: nil,
              url: "http://tier1.com",
              apply_price_changes_to_existing_memberships: true,
              subscription_price_change_effective_date: @effective_date.strftime("%Y-%m-%d"),
            },
            {
              name: "Second Tier",
              description: nil,
              price_difference: nil,
              max_purchase_count: nil,
              id: nil,
            }
          ]
        }
      end

      it "updates the tiers" do
        Product::VariantCategoryUpdaterService.new(
          product: @product,
          category_params: @variant_category_params
        ).perform

        first_tier = @product.reload.tier_category.variants.find_by(name: "First Tier")
        expect(first_tier.max_purchase_count).to eq 10
        expect(first_tier.apply_price_changes_to_existing_memberships).to eq true
        expect(first_tier.subscription_price_change_effective_date).to eq @effective_date
      end

      context "with recurrence pricing" do
        before :each do
          @variant_category_params[:options][0].merge!(
            recurrence_price_values: {
              BasePrice::Recurrence::MONTHLY => {
                enabled: true,
                price_cents: 2005,
              },
              BasePrice::Recurrence::QUARTERLY => {
                enabled: true,
                price_cents: 4500,
              },
              BasePrice::Recurrence::YEARLY => {
                enabled: true,
                price_cents: 12000,
              },
              BasePrice::Recurrence::BIANNUALLY => {
                enabled: false
              },
              BasePrice::Recurrence::EVERY_TWO_YEARS => {
                enabled: false
              }
            }
          )

          @variant_category_params[:options][1].merge!(
            recurrence_price_values: {
              BasePrice::Recurrence::MONTHLY => {
                enabled: true,
                price_cents: 1000,
              },
              BasePrice::Recurrence::QUARTERLY => {
                enabled: true,
                price_cents: 2500,
              },
              BasePrice::Recurrence::YEARLY => {
                enabled: true,
                price_cents: 6000,
              },
              BasePrice::Recurrence::BIANNUALLY => {
                enabled: false
              },
              BasePrice::Recurrence::EVERY_TWO_YEARS => {
                enabled: false
              }
            }
          )
        end

        it "saves variants with valid recurrence prices" do
          Product::VariantCategoryUpdaterService.new(
            product: @product,
            category_params: @variant_category_params
          ).perform

          variants = @product.reload.tier_category.variants
          first_tier_prices = variants.find_by!(name: "First Tier").prices.alive
          second_tier_prices = variants.find_by!(name: "Second Tier").prices.alive

          expect(first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::MONTHLY).price_cents).to eq 2005
          expect(first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::QUARTERLY).price_cents).to eq 4500
          expect(first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::YEARLY).price_cents).to eq 12000
          expect(first_tier_prices.find_by(recurrence: BasePrice::Recurrence::BIANNUALLY)).to be nil
          expect(first_tier_prices.find_by(recurrence: BasePrice::Recurrence::EVERY_TWO_YEARS)).to be nil

          expect(second_tier_prices.find_by!(recurrence: BasePrice::Recurrence::MONTHLY).price_cents).to eq 1000
          expect(second_tier_prices.find_by!(recurrence: BasePrice::Recurrence::QUARTERLY).price_cents).to eq 2500
          expect(second_tier_prices.find_by!(recurrence: BasePrice::Recurrence::YEARLY).price_cents).to eq 6000
          expect(second_tier_prices.find_by(recurrence: BasePrice::Recurrence::BIANNUALLY)).to be nil
          expect(second_tier_prices.find_by(recurrence: BasePrice::Recurrence::EVERY_TWO_YEARS)).to be nil
        end

        context "with pay-what-you-want pricing" do
          before :each do
            @variant_category_params[:options][0][:customizable_price] = "1"
            @variant_category_params[:options][0][:recurrence_price_values][BasePrice::Recurrence::MONTHLY][:suggested_price_cents] = 2200
            @variant_category_params[:options][0][:recurrence_price_values][BasePrice::Recurrence::QUARTERLY][:suggested_price_cents] = 4700
            @variant_category_params[:options][0][:recurrence_price_values][BasePrice::Recurrence::YEARLY][:suggested_price_cents] = 12200
          end

          it "saves suggested prices" do
            Product::VariantCategoryUpdaterService.new(
              product: @product,
              category_params: @variant_category_params
            ).perform

            first_tier = @product.reload.tier_category.variants.find_by(name: "First Tier")
            first_tier_prices = first_tier.prices.alive

            expect(first_tier.customizable_price).to be true
            expect(first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::MONTHLY).suggested_price_cents).to eq 2200
            expect(first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::QUARTERLY).suggested_price_cents).to eq 4700
            expect(first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::YEARLY).suggested_price_cents).to eq 12200
          end

          context "without suggested prices" do
            it "succeeds" do
              @variant_category_params[:options][0][:recurrence_price_values][BasePrice::Recurrence::MONTHLY][:suggested_price_cents] = nil
              @variant_category_params[:options][0][:recurrence_price_values][BasePrice::Recurrence::QUARTERLY].delete(:suggested_price_cents)

              Product::VariantCategoryUpdaterService.new(
                product: @product,
                category_params: @variant_category_params
              ).perform

              first_tier = @product.reload.tier_category.variants.find_by(name: "First Tier")
              first_tier_prices = first_tier.prices.alive
              expect(first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::MONTHLY).suggested_price_cents).to be_nil
              expect(first_tier_prices.find_by!(recurrence: BasePrice::Recurrence::QUARTERLY).suggested_price_cents).to be_nil
            end
          end

          context "missing all prices values" do
            it "raises an error" do
              category_params = @variant_category_params
              category_params[:options][0].delete(:recurrence_price_values)

              expect do
                Product::VariantCategoryUpdaterService.new(
                  product: @product,
                  category_params:
                ).perform
              end.to raise_error Link::LinkInvalid
              expect(@product.errors.full_messages).to include "Please provide suggested payment options."
            end
          end

          context "with a suggested price that is below price_cents" do
            it "raises an error" do
              @variant_category_params[:options][0][:recurrence_price_values][BasePrice::Recurrence::MONTHLY][:suggested_price_cents] = 2004

              expect do
                Product::VariantCategoryUpdaterService.new(
                  product: @product,
                  category_params: @variant_category_params
                ).perform
              end.to raise_error Link::LinkInvalid
              expect(@product.errors.full_messages).to include "The suggested price you entered was too low."
            end
          end
        end

        context "with invalid recurrences" do
          context "such as missing a price for the default recurrence" do
            it "raises an error" do
              @variant_category_params[:options].each do |option|
                option[:recurrence_price_values].delete(BasePrice::Recurrence::MONTHLY)
              end

              expect do
                Product::VariantCategoryUpdaterService.new(
                  product: @product,
                  category_params: @variant_category_params
                ).perform
              end.to raise_error Link::LinkInvalid

              expect(@product.errors.full_messages).to include "Please provide a price for the default payment option."
            end
          end

          context "such as specifying enabled: false for the default recurrence" do
            it "raises an error" do
              @variant_category_params[:options][0][:recurrence_price_values][BasePrice::Recurrence::MONTHLY][:enabled] = false

              expect do
                Product::VariantCategoryUpdaterService.new(
                  product: @product,
                  category_params: @variant_category_params
                ).perform
              end.to raise_error Link::LinkInvalid

              expect(@product.errors.full_messages).to include "Please provide a price for the default payment option."
            end
          end

          context "such as different recurrences for different variants" do
            it "raises an error" do
              category_params = @variant_category_params
              category_params[:options][0][:recurrence_price_values].delete(BasePrice::Recurrence::YEARLY)

              expect do
                Product::VariantCategoryUpdaterService.new(
                  product: @product,
                  category_params:
                ).perform
              end.to raise_error Link::LinkInvalid

              expect(@product.errors.full_messages).to include "All tiers must have the same set of payment options."
            end
          end

          context "such as missing price for a recurrence" do
            it "raises an error" do
              category_params = @variant_category_params
              category_params[:options][0][:recurrence_price_values][BasePrice::Recurrence::MONTHLY].delete(:price_cents)

              expect do
                Product::VariantCategoryUpdaterService.new(
                  product: @product,
                  category_params:
                ).perform
              end.to raise_error Link::LinkInvalid

              expect(@product.errors.full_messages).to include "Please provide a price for all selected payment options."
            end
          end

          context "such as a price that is too high" do
            it "raises an error" do
              category_params = @variant_category_params
              category_params[:options][0][:recurrence_price_values][BasePrice::Recurrence::MONTHLY][:price_cents] = 500001

              expect do
                Product::VariantCategoryUpdaterService.new(
                  product: @product,
                  category_params:
                ).perform
              end.to raise_error Link::LinkInvalid

              expect(@product.errors.full_messages).to include "Sorry, we don't support pricing products above $5,000."
            end
          end

          context "such as a price that is too low" do
            it "raises an error" do
              category_params = @variant_category_params
              category_params[:options][0][:recurrence_price_values][BasePrice::Recurrence::MONTHLY][:price_cents] = 98

              expect do
                Product::VariantCategoryUpdaterService.new(
                  product: @product,
                  category_params:
                ).perform
              end.to raise_error Link::LinkInvalid

              expect(@product.errors.full_messages).to include "Sorry, a product must be at least $0.99."
            end
          end

          context "such as an invalid recurrence option" do
            it "raises an error" do
              category_params = @variant_category_params
              category_params[:options][0][:recurrence_price_values]["whenever"] = {
                enabled: true,
                price_cents: 10000
              }
              category_params[:options][1][:recurrence_price_values]["whenever"] = {
                enabled: true,
                price_cents: 10000
              }

              expect do
                Product::VariantCategoryUpdaterService.new(
                  product: @product,
                  category_params:
                ).perform
              end.to raise_error Link::LinkInvalid

              expect(@product.errors.full_messages).to include "Please provide a valid payment option."
            end
          end
        end
      end

      context "when tiers are removed" do
        it "marks them as deleted and queues a DeleteProductRichContentWorker" do
          tier = @product.tier_category.variants.first

          freeze_time do
            expect do
              Product::VariantCategoryUpdaterService.new(
                product: @product,
                category_params: { id: @product.tier_category.external_id, title: "Monthly" },
                ).perform
            end.to change { tier.reload.deleted_at }.from(nil).to(Time.current)

            expect(DeleteProductRichContentWorker).to have_enqueued_sidekiq_job(@product.id, tier.id)
          end
        end
      end
    end

    describe "content upsells" do
      before do
        @product = create(:product)
        @variant_category = create(:variant_category, link: @product)
        @variant = create(:variant, variant_category: @variant_category)
        @rich_content = create(:rich_content, entity: @variant, description: [
                                 {
                                   "type" => "paragraph",
                                   "content" => [
                                     {
                                       "type" => "text",
                                       "text" => "Original content"
                                     }
                                   ]
                                 }
                               ])
      end

      it "processes content upsells for variant rich content" do
        new_description = [
          {
            "type" => "paragraph",
            "content" => [
              {
                "type" => "text",
                "text" => "New content"
              }
            ]
          }
        ]

        expect(SaveContentUpsellsService).to receive(:new).with(
          seller: @product.user,
          content: new_description,
          old_content: @rich_content.description
        ).and_call_original

        Product::VariantCategoryUpdaterService.new(
          product: @product,
          category_params: {
            id: @variant_category.external_id,
            title: @variant_category.title,
            options: [
              {
                id: @variant.external_id,
                name: @variant.name,
                rich_content: [
                  {
                    id: @rich_content.external_id,
                    title: "Page title",
                    description: new_description
                  }
                ]
              }
            ]
          }
        ).perform
      end
    end
  end
end
