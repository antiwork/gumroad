# frozen_string_literal: true

require "test_helper"
require "shared_examples/max_purchase_count_concern"

class VariantTest < ActiveSupport::TestCase
  self.described_class = Variant



  context_ Variant do
    it_behaves_like "MaxPurchaseCount concern", :variant

  context_ "lifecycle hooks" do
  context_ "before_validation :strip_subscription_price_change_message" do
  test "ensures text is present or sets message to nil" do
          ["", "<p><br></p>", "<div></div>"].each do |message|
            variant = build(:variant, subscription_price_change_message: message)
            expect do
              variant.valid?
            end.to change { variant.subscription_price_change_message }.to(nil)
          end
          ["<p>hello</p>", "<a href='foo'>a link</a>"].each do |message|
            variant = build(:variant, subscription_price_change_message: message)
            expect do
              variant.valid?
            end.not_to change { variant.subscription_price_change_message }
          end
        end
      end

  context_ "before_create :set_position" do
  test "sets the position if not already set" do
          preexisting_variant = create(:variant)
          variant = build(:variant, variant_category: preexisting_variant.variant_category)

          variant.save!

          expect(variant.reload.position_in_category).to eq 1
        end

  test "does not set the position if already set" do
          preexisting_variant = create(:variant)
          variant = build(
            :variant,
            variant_category: preexisting_variant.variant_category,
            position_in_category: 0
          )

          variant.save!

          expect(variant.reload.position_in_category).to eq 0
        end
      end

  context_ "after_save :set_customizable_price" do
  context_ "for a tier variant" do
          let(:product) { create(:membership_product) }
          let(:tier) { product.tiers.first }
          let(:monthly_price) { tier.prices.alive.find_by!(recurrence: BasePrice::Recurrence::MONTHLY) }

  context_ "when the variant has at least one price with price_cents > 0" do
  test "does not set customizable_price to true" do
              expect(monthly_price.price_cents).not_to eq 0
              create(:variant_price, variant: tier, price_cents: 0, recurrence: BasePrice::Recurrence::YEARLY)

              tier.save

              expect(tier.reload.customizable_price).to be nil
            end
          end

  context_ "when the variant has no prices" do
  test "does not set customizable_price" do
              tier.save

              expect(tier.reload.customizable_price).to be nil
            end
          end

  context_ "when the variant has no prices with price_cents > 0" do
  test "sets customizable_price to true" do
              monthly_price.update!(price_cents: 0)
              create(:variant_price, variant: tier, price_cents: 0, recurrence: BasePrice::Recurrence::YEARLY, deleted_at: Time.current)

              tier.save

              expect(tier.reload.customizable_price).to eq true
            end
          end
        end

  context_ "for a non-tier variant" do
  test "does not set customizable_price" do
            variant = create(:variant)
            create(:variant_price, variant:, price_cents: 0)

            variant.save

            expect(variant.customizable_price).to be nil
          end
        end
      end
    end

  context_ "validations" do
  context_ "price_must_be_within_range" do
        let(:variant) { create(:variant) }

  context_ "for a variant with live prices" do
  test "succeeds if prices are within acceptable bounds" do
            create(:variant_price, variant:, price_cents: 1_00)
            create(:variant_price, variant:, price_cents: 5000_00)

            expect(variant).to be_valid
          end

  test "fails if a price is too high" do
            create(:variant_price, variant:, price_cents: 5000_01)

            expect(variant).not_to be_valid
            expect(variant.errors.full_messages).to include "Sorry, we don't support pricing products above $5,000."
          end

  test "fails if a price is too low" do
            create(:variant_price, variant:, price_cents: 98)

            expect(variant).not_to be_valid
            expect(variant.errors.full_messages).to include "Sorry, a product must be at least $0.99."
          end
        end

  context_ "for a variant without live prices" do
  test "succeeds" do
            create(:variant_price, variant:, price_cents: 98, deleted_at: Time.current)
            expect(variant).to be_valid
          end
        end
      end

  context_ "apply_price_changes_to_existing_memberships_settings" do
  test "succeeds if setting is disabled" do
          variant = build(:variant, apply_price_changes_to_existing_memberships: false)
          expect(variant).to be_valid
        end

  context_ "setting is enabled" do
          let(:variant) { build(:variant, apply_price_changes_to_existing_memberships: true) }

  test "succeeds if effective date is present" do
            variant.subscription_price_change_effective_date = 7.days.from_now.to_date
            expect(variant).to be_valid
          end

  test "fails if effective date is missing" do
            expect(variant).not_to be_valid
            expect(variant.errors.full_messages).to include "Effective date for existing membership price changes must be present"
          end

  test "fails if effective date is < 7 days from now" do
            variant.subscription_price_change_effective_date = 6.days.from_now.in_time_zone(variant.user.timezone).to_date
            expect(variant).not_to be_valid
            expect(variant.errors.full_messages).to include "The effective date must be at least 7 days from today"
          end

  test "succeeds if effective date is < 7 days from now but is not being changed" do
            variant.subscription_price_change_effective_date = 6.days.from_now.in_time_zone(variant.user.timezone).to_date
            variant.save(validate: false)
            expect(variant).to be_valid
          end
        end
      end

  context_ "variant belongs to call" do
        let(:call) { create(:call_product) }
        let(:variant_category) { call.variant_categories.first }

  context_ "duration_in_minutes is not a number" do
  test "adds an error" do
            variant = build(:variant, variant_category:, duration_in_minutes: nil)
            expect(variant).not_to be_valid
            expect(variant.errors.full_messages).to eq(["Duration in minutes is not a number"])

            variant.duration_in_minutes = "not a number"
            expect(variant).not_to be_valid
            expect(variant.errors.full_messages).to eq(["Duration in minutes is not a number"])
          end
        end

  context_ "duration_in_minutes is less than or equal to 0" do
  test "adds an error" do
            variant = build(:variant, variant_category:, duration_in_minutes: 0)
            expect(variant).not_to be_valid
            expect(variant.errors.full_messages).to eq(["Duration in minutes must be greater than 0"])

            variant.duration_in_minutes = -1
            expect(variant).not_to be_valid
            expect(variant.errors.full_messages).to eq(["Duration in minutes must be greater than 0"])
          end
        end

  context_ "duration_in_minutes is greater than 0" do
  test "does not add an error" do
            variant = build(:variant, variant_category:, duration_in_minutes: 100)
            expect(variant).to be_valid
          end
        end
      end

  context_ "variant belongs to coffee" do
        let(:seller) { create(:user, :eligible_for_service_products) }
        let(:coffee) { create(:product, user: seller, native_type: Link::NATIVE_TYPE_COFFEE) }
        let(:variant_category) { create(:variant_category, link: coffee) }

  context_ "name is blank" do
  test "does not add an error" do
            variant = build(:variant, variant_category:, price_difference_cents: 100)
            expect(variant).to be_valid
          end
        end
      end
    end

  context_ "#is_downloadable?" do
      let(:variant) { create(:variant) }

  test "returns false if product is rent-only" do
        variant.link.update!(purchase_type: "rent_only", rental_price_cents: 1_00)

        expect(variant.is_downloadable?).to eq(false)
      end

  test "returns false if product has stampable PDFs" do
        variant.product_files << create(:readable_document, link: variant.link)
        variant.product_files << create(:readable_document, pdf_stamp_enabled: true, link: variant.link)

        expect(variant.is_downloadable?).to eq(false)
      end

  test "returns false if product has only stream-only files" do
        variant.product_files << create(:streamable_video, stream_only: true, link: variant.link)

        expect(variant.is_downloadable?).to eq(false)
      end

  test "returns true if product has at least one unstampable file that's not stream-only" do
        variant.product_files << create(:readable_document, link: variant.link)
        variant.product_files << create(:streamable_video, stream_only: true, link: variant.link)

        expect(variant.is_downloadable?).to eq(true)
      end
    end

  context_ "sales_count_for_inventory" do
  context_ "when the product is not a membership" do
        before :each do
          @variant = create(:variant)
          product = @variant.link

          create(:purchase, link: product, variant_attributes: [@variant])
          create(:purchase, link: product, variant_attributes: [@variant], purchase_state: "failed")
        end

  test "count all successful purchases" do
          expect(@variant.sales_count_for_inventory).to eq 1
        end

  test "excludes purchases for other products" do
          create(:purchase)
          create(:membership_purchase)

          expect(@variant.sales_count_for_inventory).to eq 1
        end
      end

  context_ "when the product is a membership" do
        before :each do
          @product = create(:membership_product)
          tier_category = @product.tier_category
          @first_tier = tier_category.variants.first
          @second_tier = create(:variant, variant_category: tier_category, name: "2nd Tier")

          # first tier has 1 active subscription, 1 inactive subscription, and 1 non-subscription purchase
          active_subscription = create(:subscription, link: @product)
          create(:purchase, link: @product, variant_attributes: [@first_tier], subscription: active_subscription, is_original_subscription_purchase: true)
          inactive_subscription = create(:subscription, link: @product, deactivated_at: Time.current)
          create(:purchase, link: @product, variant_attributes: [@first_tier], subscription: inactive_subscription, is_original_subscription_purchase: true)
          create(:purchase, link: @product, variant_attributes: [@first_tier])

          # second tier has 1 active subscription, 1 inactive subscription, and 1 non-subscription purchase
          active_subscription = create(:subscription, link: @product)
          create(:purchase, link: @product, variant_attributes: [@second_tier], subscription: active_subscription, is_original_subscription_purchase: true)
          inactive_subscription = create(:subscription, link: @product, deactivated_at: Time.current)
          create(:purchase, link: @product, variant_attributes: [@second_tier], subscription: inactive_subscription, is_original_subscription_purchase: true)
          create(:purchase, link: @product, variant_attributes: [@second_tier])
        end

  test "only counts active subscriptions + non-subscription purchases for the given tier" do
          expect(@first_tier.sales_count_for_inventory).to eq 2
        end

  test "excludes purchases for other products" do
          create(:purchase)
          create(:membership_purchase)

          expect(@first_tier.sales_count_for_inventory).to eq 2
        end
      end
    end

  context_ "quantity_left" do
  context_ "has max_purchase_count" do
        before do
          @variant = create(:variant, max_purchase_count: 3)
          @purchase = create(:purchase)
          @purchase.variant_attributes << @variant
          @purchase.save
        end

  test "show correctly" do
          expect(@variant.quantity_left).to eq 2
        end
      end

  context_ "no max_purchase_count" do
        before do
          @variant = create(:variant)
        end

  test "returns nil" do
          expect(@variant.quantity_left).to eq nil
        end
      end

  context_ "max_purchase_count and validation" do
        before do
          @variant = create(:variant, max_purchase_count: 1)
          @purchase = create(:purchase, variant_attributes: [@variant])
        end

  test "is valid" do
          @variant.save
          expect(@variant).to be_valid
        end

  test "remains valid if when inventory sold is greater" do
          @variant = create(:variant, max_purchase_count: 3)
          create_list(:purchase, 3, link: @variant.variant_category.link, variant_attributes: [@variant])
          @variant.update_column(:max_purchase_count, 1)
          expect(@variant.valid?).to eq(true)
          @variant.max_purchase_count = 2
          expect(@variant.valid?).to eq(false)
        end
      end
    end

  context_ "price_formatted_without_dollar_sign" do
  context_ "whole dollar amount" do
        before do
          @variant = create(:variant, price_difference_cents: 300)
        end

  test "shows correctly" do
          expect(@variant.price_formatted_without_dollar_sign).to eq "3"
        end
      end

  context_ "dollars and cents" do
        before do
          @variant = create(:variant, price_difference_cents: 350)
        end

  test "shows correctly" do
          expect(@variant.price_formatted_without_dollar_sign).to eq "3.50"
        end
      end
    end

  context_ "available?" do
  context_ "no max_purchase_count" do
        before do
          @variant = create(:variant)
        end

  test "returns true" do
          expect(@variant.available?).to be(true)
        end
      end

  context_ "available" do
        before do
          @variant = create(:variant, max_purchase_count: 2)
        end

  test "returns true" do
          expect(@variant.available?).to be(true)
        end
      end

  context_ "unavailable" do
        before do
          @variant = create(:variant, max_purchase_count: 1)
          @purchase = create(:purchase, variant_attributes: [@variant])
        end

  test "returns false" do
          expect(@variant.available?).to be(false)
        end
      end
    end

  context_ "#mark_deleted" do
      before do
        @variant = create(:variant)
      end

  test "marks the variant deleted" do
        travel_to(Time.current) do
          expect { @variant.mark_deleted }.to change { @variant.reload.deleted_at.try(:utc).try(:to_i) }.from(nil).to(Time.current.to_i)
        end
      end

  test "marks the variant deleted and enqueues deletion for rich content and product file archives" do
        freeze_time do
          expect do
            @variant.mark_deleted
          end.to change { @variant.reload.deleted_at }.from(nil).to(Time.current)

          expect(DeleteProductRichContentWorker).to have_enqueued_sidekiq_job(@variant.variant_category.link_id, @variant.id)
          expect(DeleteProductFilesArchivesWorker).to have_enqueued_sidekiq_job(@variant.variant_category.link_id, @variant.id)
        end
      end
    end

  context_ "price_difference_cents_validation" do
  test "marks negative variants as invalid" do
        expect { create(:variant, price_difference_cents: -100) }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

  context_ "scopes" do
  context_ "alive" do
        before do
          @variant_category = create(:variant_category, link: create(:product))
          @variant = create(:variant, variant_category: @variant_category)
          create(:variant, variant_category: @variant_category, deleted_at: Time.current)
        end

  test "retuns the correct variants" do
          expect(@variant_category.variants.alive.count).to eq 1
          expect(@variant_category.variants.alive.first.id).to eq @variant.id
        end
      end
    end

  context_ "#user" do
      before do
        @product = create(:product)
        @variant_category = create(:variant_category, link: @product)
        @variant = create(:variant, variant_category: @variant_category)
      end

  test "returns value matches the owning link user" do
        expect(@variant.user).to eq(@product.user)
      end
    end

  context_ "#name_displayable" do
      before do
        @product = create(:product, name: "Crazy Link")
        @variant_category = create(:variant_category, link: @product)
        @variant = create(:variant, variant_category: @variant_category, name: "Version A")
      end

  test "consolidates the link and variant names" do
        expect(@variant.name_displayable).to eq("Crazy Link (Version A)")
      end
    end

  context_ "#free?" do
  test "returns true when price_difference_cents IS 0 and the variant HAS NO live prices with price_cents > 0" do
        variant = create(:variant)
        create(:variant_price, variant:, price_cents: 0)
        create(:variant_price, variant:, price_cents: 100, deleted_at: Time.current)

        expect(variant).to be_free
      end

  test "returns false when price_difference_cents IS 0 and the variant HAS live prices with price_cents > 0" do
        variant = create(:variant)
        create(:variant_price, variant:, price_cents: 100)

        expect(variant).not_to be_free
      end

  test "returns false when price_difference_cents IS NOT 0 and the variant HAS NO live prices with price_cents > 0" do
        variant = create(:variant, price_difference_cents: 100)
        create(:variant_price, variant:, price_cents: 0)
        create(:variant_price, variant:, price_cents: 100, deleted_at: Time.current)

        expect(variant).not_to be_free
      end

  test "returns false when price_difference_cents IS 0 and the variant HAS live prices with price_cents > 0" do
        variant = create(:variant)
        create(:variant_price, variant:, price_cents: 100)
        create(:variant_price, variant:, price_cents: 100, deleted_at: Time.current)

        expect(variant).not_to be_free
      end

  test "returns true when price_difference_cents IS 0 and the variant only has live RENTAL prices with price_cents > 0" do
        variant = create(:variant)
        price = create(:variant_price, variant:, price_cents: 100)
        price.is_rental = true
        price.save!

        expect(variant).to be_free
      end

  test "does not error if price_difference_cents is nil" do
        variant = create(:variant, price_difference_cents: nil)

        expect(variant).to be_free
      end
    end

  context_ "#as_json" do
  context_ "for a variant with prices" do
  context_ "and is pay-what-you-want enabled" do
  test "includes prices and pay-what-you-want state" do
            variant = create(:variant, customizable_price: true)
            create(:price, link: variant.link, recurrence: "monthly")
            create(:variant_price, variant:, suggested_price_cents: 5_00, price_cents: 3_00, recurrence: "monthly")

            variant_hash = variant.as_json
            prices_hash = variant_hash["recurrence_price_values"]

            expect(variant_hash["is_customizable_price"]).to eq true
            expect(prices_hash["monthly"][:enabled]).to eq true
            expect(prices_hash["monthly"][:price]).to eq "3"
            expect(prices_hash["monthly"][:suggested_price]).to eq "5"
          end
        end

  context_ "and is NOT pay-what-you-want enabled" do
  test "includes prices and pay-what-you-want state" do
            variant = create(:variant, customizable_price: false)
            create(:price, link: variant.link, recurrence: "monthly")
            create(:variant_price, variant:, price_cents: 3_00, recurrence: "monthly")

            variant_hash = variant.as_json
            prices_hash = variant_hash["recurrence_price_values"]

            expect(variant_hash["is_customizable_price"]).to eq false
            expect(prices_hash["monthly"][:enabled]).to eq true
            expect(prices_hash["monthly"][:price]).to eq "3"
            expect(prices_hash["monthly"].has_key?(:suggested_price)).to be false
          end
        end

  test "excludes rental prices" do
          variant = create(:variant, customizable_price: true)
          price = create(:variant_price, variant:, suggested_price_cents: 5_00, price_cents: 3_00, recurrence: "monthly")
          price.is_rental = true
          price.save!

          variant_hash = variant.as_json
          monthly_price_hash = variant_hash["recurrence_price_values"]["monthly"]

          expect(monthly_price_hash[:enabled]).to eq false
          expect(monthly_price_hash[:price]).to be_nil
        end
      end

  context_ "for a variant without prices" do
  test "does not include prices or pay-what-you-want state" do
          variant = create(:variant)

          variant_hash = variant.as_json
          expect(variant_hash.has_key?("is_customizable_price")).to be false
          expect(variant_hash.has_key?("recurrence_price_values")).to be false
        end
      end

  context_ "for_seller" do
        let(:variant) { create(:variant) }

  test "includes protected information when for_seller is true" do
          variant_hash = variant.as_json(for_views: true, for_seller: true)
          expect(variant_hash.has_key?("active_subscriber_count")).to eq true
          expect(variant_hash.has_key?("settings")).to eq true
        end

  test "does not include protected information when for_seller is false or missing" do
          variant_hash = variant.as_json(for_views: true, for_seller: false)
          expect(variant_hash.has_key?("active_subscriber_count")).to eq false
          expect(variant_hash.has_key?("settings")).to eq false

          variant_hash = variant.as_json(for_views: true)
          expect(variant_hash.has_key?("active_subscriber_count")).to eq false
          expect(variant_hash.has_key?("settings")).to eq false
        end
      end
    end

  context_ "#to_option" do
  test "returns a hash of attributes for use in checkout" do
        variant = create(:variant, name: "Red", description: "The red one")

        expect(variant.to_option).to eq(
          id: variant.external_id,
          name: variant.name,
          quantity_left: nil,
          description: variant.description,
          price_difference_cents: 0,
          recurrence_price_values: nil,
          is_pwyw: false,
          duration_in_minutes: nil,
        )
      end
    end

  context_ "#recurrence_price_values" do
  context_ "with subscription recurrence" do
        before do
          @variant = create(:variant)
          @variant_price = create(:variant_price, variant: @variant, recurrence: "yearly")

          product_price = create(:price, link: @variant.link, recurrence: "yearly")
          payment_option = create(:payment_option, price: product_price)
          @subscription = payment_option.subscription
          create(:membership_purchase, subscription: @subscription, variant_attributes: [@variant], price_cents: 1234)
        end

  context_ "with deleted prices" do
          before :each do
            @variant_price.mark_deleted!
          end

  test "includes the deleted price details for the subscription's recurrence" do
            result = @variant.recurrence_price_values
            expect(result["yearly"]).not_to be

            result = @variant.recurrence_price_values(subscription_attrs: {
                                                        recurrence: @subscription.recurrence,
                                                        variants: @subscription.original_purchase.variant_attributes,
                                                        price_cents: @subscription.original_purchase.displayed_price_cents,
                                                      })
            expect(result["yearly"]).to be
          end

  test "does not include deleted price details for other recurrences" do
            create(:price, link: @variant.link, recurrence: "monthly", deleted_at: 1.day.ago)
            create(:variant_price, variant: @variant, recurrence: "monthly")


            result = @variant.recurrence_price_values(subscription_attrs: {
                                                        recurrence: @subscription.recurrence,
                                                        variants: @subscription.original_purchase.variant_attributes,
                                                        price_cents: @subscription.original_purchase.displayed_price_cents,
                                                      })

            expect(result["monthly"]).not_to be
          end

  test "uses the subscription's existing price" do
            result = @variant.recurrence_price_values(subscription_attrs: {
                                                        recurrence: @subscription.recurrence,
                                                        variants: @subscription.original_purchase.variant_attributes,
                                                        price_cents: @subscription.original_purchase.displayed_price_cents,
                                                      })
            expect(result["yearly"][:price_cents]).to eq 1234
          end
        end

  context_ "when the subscription tier has been deleted" do
  test "only includes the price for the current subscription recurrence" do
            create(:price, link: @variant.link, recurrence: "monthly")
            create(:variant_price, variant: @variant, recurrence: "monthly")

            result = @variant.recurrence_price_values(subscription_attrs: {
                                                        recurrence: @subscription.recurrence,
                                                        variants: @subscription.original_purchase.variant_attributes,
                                                        price_cents: @subscription.original_purchase.displayed_price_cents,
                                                      })
            expect(result.keys).to match_array ["monthly", "yearly"]

            @variant.mark_deleted!

            result = @variant.recurrence_price_values(subscription_attrs: {
                                                        recurrence: @subscription.recurrence,
                                                        variants: @subscription.original_purchase.variant_attributes,
                                                        price_cents: @subscription.original_purchase.displayed_price_cents,
                                                      })
            expect(result.keys).to match_array ["yearly"]
          end
        end
      end
    end

  context_ "#save_recurring_prices!" do
      before :each do
        @variant = create(:variant)
        @recurrence_price_values = {
          BasePrice::Recurrence::MONTHLY => {
            enabled: true,
            price: "20",
            suggested_price: "25",
            suggested_price_cents: 2500,
          },
          BasePrice::Recurrence::YEARLY => {
            enabled: true,
            price_cents: 9999,
            suggested_price: ""
          },
          BasePrice::Recurrence::BIANNUALLY => { enabled: false }
        }
      end

  test "saves valid prices" do
        @variant.save_recurring_prices!(@recurrence_price_values)

        prices = @variant.prices
        monthly_price = prices.find_by!(recurrence: BasePrice::Recurrence::MONTHLY)
        yearly_price = prices.find_by!(recurrence: BasePrice::Recurrence::YEARLY)

        expect(prices.length).to eq 2
        expect(monthly_price.price_cents).to eq 2000
        expect(monthly_price.suggested_price_cents).to eq 2500
        expect(yearly_price.price_cents).to eq 9999
        expect(yearly_price.suggested_price_cents).to be_nil
      end

  test "saves product prices with price_cents 0" do
        @variant.save_recurring_prices!(@recurrence_price_values)

        prices = @variant.link.prices.alive
        monthly_price = prices.find_by(recurrence: BasePrice::Recurrence::MONTHLY)
        yearly_price = prices.find_by(recurrence: BasePrice::Recurrence::YEARLY)

        expect(prices.length).to eq 2
        expect(monthly_price.price_cents).to eq 0
        expect(monthly_price.suggested_price_cents).to eq 0
        expect(yearly_price.price_cents).to eq 0
        expect(yearly_price.suggested_price_cents).to be_nil
      end

  test "deletes any old prices" do
        biannual_price = create(:variant_price, variant: @variant, recurrence: BasePrice::Recurrence::BIANNUALLY)
        quarterly_price = create(:variant_price, variant: @variant, recurrence: BasePrice::Recurrence::QUARTERLY)
        non_recurring_price = create(:variant_price, variant: @variant, recurrence: nil)

        @variant.save_recurring_prices!(@recurrence_price_values)

        expect(@variant.prices.alive.length).to eq 2
        expect(biannual_price.reload).to be_deleted
        expect(quarterly_price.reload).to be_deleted
        expect(non_recurring_price.reload).to be_deleted
      end

  context_ "updating Elasticsearch" do
        before :each do
          @variant.save_recurring_prices!(@recurrence_price_values)
          @product = @variant.link
        end

  test "enqueues Elasticsearch update if a price is new or has changed" do
          updated_recurrence_prices = @recurrence_price_values.merge(
            BasePrice::Recurrence::MONTHLY => {
              enabled: true,
              price: "25",
              suggested_price: "30"
            },
            BasePrice::Recurrence::QUARTERLY => {
              enabled: true,
              price: "70",
              suggested_price: "75"
            }
          )

          # update is called for the changed monthly variant price and new quarterly variant and product prices
          expect(@product).to receive(:enqueue_index_update_for).with(["price_cents", "available_price_cents"]).exactly(3).times

          @variant.save_recurring_prices!(updated_recurrence_prices)
        end

  test "does not enqueue Elasticsearch update if prices have not changed" do
          expect(@product).not_to receive(:enqueue_index_update_for).with(["price_cents", "available_price_cents"])

          @variant.save_recurring_prices!(@recurrence_price_values)
        end

  test "enqueues Elasticsearch update if a prices is disabled" do
          updated_recurrence_prices = @recurrence_price_values.merge(
            BasePrice::Recurrence::YEARLY => { enabled: false }
          )

          # called for yearly variant price change and product price
          expect(@product).to receive(:enqueue_index_update_for).with(["price_cents", "available_price_cents"]).exactly(2).times

          @variant.save_recurring_prices!(updated_recurrence_prices)
        end
      end

  context_ "missing price" do
  test "raises an error" do
          invalid_values = @recurrence_price_values
          invalid_values[BasePrice::Recurrence::MONTHLY].delete(:price)

          expect do
            @variant.save_recurring_prices!(invalid_values)
          end.to raise_error Link::LinkInvalid
        end
      end

  context_ "with price that is too low" do
  test "raises an error" do
          @recurrence_price_values[BasePrice::Recurrence::MONTHLY][:price] = "0.98"

          expect do
            @variant.save_recurring_prices!(@recurrence_price_values)
          end.to raise_error ActiveRecord::RecordInvalid
        end
      end

  context_ "with price that is too high" do
  test "raises an error" do
          @recurrence_price_values[BasePrice::Recurrence::MONTHLY][:price] = "5000.01"

          expect do
            @variant.save_recurring_prices!(@recurrence_price_values)
          end.to raise_error ActiveRecord::RecordInvalid
        end
      end
    end

  context_ "associations" do
  context_ "has many `base_variant_integrations`" do
  test "returns alive and deleted base_variant_integrations" do
          integration_1 = create(:circle_integration)
          integration_2 = create(:circle_integration)
          variant = create(:variant, active_integrations: [integration_1, integration_2])
          expect do
            variant.base_variant_integrations.find_by(integration: integration_1).mark_deleted!
          end.to change { variant.base_variant_integrations.count }.by(0)
          expect(variant.base_variant_integrations.pluck(:integration_id)).to match_array [integration_1, integration_2].map(&:id)
        end
      end

  context_ "has many `live_base_variant_integrations`" do
  test "does not return deleted base_variant_integrations" do
          integration_1 = create(:circle_integration)
          integration_2 = create(:circle_integration)
          variant = create(:variant, active_integrations: [integration_1, integration_2])
          expect do
            variant.base_variant_integrations.find_by(integration: integration_1).mark_deleted!
          end.to change { variant.live_base_variant_integrations.count }.by(-1)
          expect(variant.live_base_variant_integrations.pluck(:integration_id)).to match_array [integration_2.id]
        end
      end

  context_ "has many `active_integrations`" do
  test "does not return deleted integrations" do
          integration_1 = create(:circle_integration)
          integration_2 = create(:circle_integration)
          variant = create(:variant, active_integrations: [integration_1, integration_2])
          expect do
            variant.base_variant_integrations.find_by(integration: integration_1).mark_deleted!
          end.to change { variant.active_integrations.count }.by(-1)
          expect(variant.active_integrations.pluck(:integration_id)).to match_array [integration_2.id]
        end
      end

  test "has many `subscription_plan_changes`" do
        variant = create(:variant)
        plan_changes = create_list(:subscription_plan_change, 2, tier: variant)

        expect(variant.subscription_plan_changes).to match_array plan_changes
      end
    end

  context_ "#rich_content_json" do
      let(:variant) { create(:variant) }
      let!(:rich_content) { create(:rich_content, entity: variant, title: "Page title", description: [{ "type" => "paragraph", "content" => [{ "text" => "This is variant-level rich content", "type" => "text" }] }]) }

  test "returns associated variant-level rich contents" do
        expect(variant.rich_content_json).to eq([{ id: rich_content.external_id, page_id: rich_content.external_id, variant_id: variant.external_id, title: "Page title", description: { type: "doc", content: [{ "type" => "paragraph", "content" => [{ "text" => "This is variant-level rich content", "type" => "text" }] }] }, updated_at: rich_content.updated_at }])
      end

  context_ "when associated product's `Link#has_same_rich_content_for_all_variants?` is true" do
        before do
          variant.link.update!(has_same_rich_content_for_all_variants: true)
        end

  test "returns empty array" do
          expect(variant.rich_content_json).to eq([])
        end
      end

  context_ "when variant does not have associated rich content" do
        before do
          variant.rich_contents.each(&:destroy!)
        end

  test "returns empty hash" do
          expect(variant.reload.rich_content_json).to eq([])
        end
      end
    end
  end
end
