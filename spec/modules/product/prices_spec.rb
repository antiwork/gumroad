# frozen_string_literal: true

require "spec_helper"

describe Product::Prices do
  before do
    @product = create(:product, price_cents: 2_50)

    @subscription_product = create(:subscription_product, price_cents: 4_00)
    @subscription_price = @subscription_product.prices.find_by!(recurrence: BasePrice::Recurrence::MONTHLY)
    create(:price, link: @subscription_product, price_cents: 35_00, recurrence: BasePrice::Recurrence::YEARLY)
  end

  describe "default_price" do
    it "has the correct default price for a subscription product" do
      expect(@subscription_product.default_price.price_cents).to eq(4_00)
      expect(@subscription_product.default_price.recurrence).to eq(BasePrice::Recurrence::MONTHLY)
    end

    it "has the correct default price for a non-subscription product" do
      expect(@product.default_price.price_cents).to eq(2_50)
      expect(@product.default_price.is_rental).to eq(false)
      expect(@product.default_price.recurrence).to eq(nil)
    end

    it "only considers alive prices" do
      create(:price, link: @subscription_product, recurrence: BasePrice::Recurrence::MONTHLY, deleted_at: Time.current)

      expect(@subscription_product.reload.default_price).to eq @subscription_price
    end

    it "considers the product currency" do
      create(:price, link: @product, price_cents: 2000, currency: "eur")

      expect(@product.default_price.currency).to eq("usd")
      expect(@product.default_price.price_cents).to eq(2_50)
    end
  end

  describe "#price_cents=" do
    it "writes to the price_cents column if product is not persisted" do
      product = build(:product)
      expect do
        product.price_cents = 1234
        expect(product.read_attribute(:price_cents)).to eq 1234
      end.not_to change { Price.count }
    end

    it "writes to the price_cents column if product is a tiered membership" do
      product = build(:product, is_tiered_membership: true)
      expect do
        product.price_cents = 1234
        expect(product.read_attribute(:price_cents)).to eq 1234
      end.not_to change { Price.count }
    end

    it "creates or updates the price record if the product is persisted" do
      product = create(:product)
      price = product.default_price

      product.price_cents = 1234
      expect(product.price_cents).to eq 1234
      expect(price.reload.price_cents).to eq 1234
    end

    it "updates the last price record as that is read when fetching `price_cents`" do
      product = create(:product)
      product.prices.first.dup.save!

      expect(product.prices.alive.size).to eq(2)
      second_price = product.prices.alive.second

      expect do
        expect do
          product.price_cents = 200
        end.to change { product.reload.price_cents }.from(100).to(200)
      end.to change { second_price.reload.price_cents }.from(100).to(200)
    end

    it "updates the price for the corresponding currency" do
      product = create(:product, price_currency_type: "usd", price_cents: 100)

      usd_price = product.default_price
      expect(usd_price.currency).to eq("usd")
      expect(usd_price.price_cents).to eq(100)

      product.update!(price_currency_type: "eur", price_cents: 200)
      euro_price = product.default_price
      expect(euro_price.currency).to eq("eur")
      expect(euro_price.price_cents).to eq(200)
      usd_price.reload
      expect(usd_price.currency).to eq("usd")
      expect(usd_price.price_cents).to eq(100)

      product.update!(price_currency_type: "usd", price_cents: 300)
      usd_price.reload
      expect(usd_price.currency).to eq("usd")
      expect(usd_price.price_cents).to eq(300)
      euro_price.reload
      expect(euro_price.currency).to eq("eur")
      expect(euro_price.price_cents).to eq(200)

      expect(product.alive_prices).to contain_exactly(usd_price, euro_price)
    end
  end

  describe "#set_customizable_price" do
    it "sets customizable_price to true if $0" do
      @product.price_cents = 0
      @product.save!
      expect(@product.customizable_price).to be(true)
      expect(@product.price_cents).to eq(0)
    end

    context "tiered memberships" do
      it "does not set customizable_price to true" do
        product = create(:membership_product, price_cents: 0)
        expect(product.customizable_price).to be nil
      end
    end

    context "product with premium versions" do
      it "sets customizable_price to true if there are no paid versions" do
        product = create(:product, price_cents: 0)
        expect(product.customizable_price).to be(true)
        expect(product.price_cents).to eq(0)
      end

      it "does not set customizable_price to true if there are paid versions" do
        product = create(:product, price_cents: 0)
        create(:variant_category, title: "versions", link: product)
        product.variant_categories.first.variants.create!(name: "premium version", price_difference_cents: 1_00)
        product.update!(customizable_price: false)
        expect(product.customizable_price).to be(false)
        expect(product.price_cents).to eq(0)
      end
    end
  end

  describe "#rental_price_range=" do
    context "when the price is blank" do
      it "raises an exception" do
        expect do
          @product.rental_price_range = ""
        end.to raise_error(ActiveRecord::RecordInvalid)
        expect(@product.errors[:base].first).to eq("Please enter the rental price.")
      end
    end

    context "when the price is valid" do
      it "sets the price correctly" do
        @product.rental_price_range = "1.23"

        expect(@product.valid?).to be(true)
        expect(@product.prices.alive.is_rental.last.price_cents).to be(123)
      end
    end
  end

  describe "#display_price_cents" do
    it "returns the default_price" do
      product = create(:product, price_cents: 5_00)
      expect(product.display_price_cents).to eq 5_00
    end

    context "for tiered membership" do
      let(:product) do
        recurrence_price_values = [
          { "monthly" => { enabled: true, price: 10 }, "yearly" => { enabled: true, price: 100 } },
          { "monthly" => { enabled: true, price: 2 }, "yearly" => { enabled: true, price: 15 } }
        ]
        create(:membership_product_with_preset_tiered_pricing, recurrence_price_values:, subscription_duration: "yearly")
      end

      it "returns the lowest price available for any tier" do
        expect(product.display_price_cents).to eq 2_00
      end

      context "when for_default_duration is true" do
        it "returns the lowest price available for any tier for the default duration" do
          expect(product.display_price_cents(for_default_duration: true)).to eq 15_00
        end
      end

      context "when the tier has no prices" do
        it "returns 0" do
          product = create(:membership_product)
          product.default_tier.prices.destroy_all

          expect(product.display_price_cents).to eq 0
        end
      end
    end

    context "for a product with live variants" do
      let(:product) { create(:product, price_cents: 5_00) }
      let(:category) { create(:variant_category, link: product) }

      context "with no price differences" do
        it "returns the default_price" do
          create(:variant, variant_category: category, price_difference_cents: nil)

          expect(product.display_price_cents).to eq 5_00
        end
      end

      context "with price differences" do
        it "returns the default_price plus the lowest live variant price difference" do
          create(:variant, variant_category: category, price_difference_cents: 200)
          create(:variant, variant_category: category, price_difference_cents: 99)
          create(:variant, variant_category: category, price_difference_cents: 50, deleted_at: 1.hour.ago)

          expect(product.display_price_cents).to eq 5_99
        end
      end
    end

    context "for a buy-or-rent product" do
      let(:product) { create(:product, price_cents: 5_00, rental_price_cents: 1_00, purchase_type: :buy_and_rent) }

      it "returns the buy price" do
        expect(product.display_price_cents).to eq 5_00
      end
    end

    context "for a rental-only product" do
      let(:product) { create(:product, rental_price_cents: 1_00, purchase_type: :rent_only) }

      it "returns the rental price" do
        expect(product.display_price_cents).to eq 1_00
      end
    end
  end

  describe "#available_price_cents" do
    context "for simple products" do
      let(:product) { create(:product, price_cents: 5_00) }

      it "returns the default_price" do
        expect(product.available_price_cents).to match_array([5_00])
      end
    end

    context "for simple products with rent prices" do
      let(:product) { create(:product, price_cents: 5_00, rental_price_cents: 2_00, purchase_type: :buy_and_rent) }

      it "ignores the rent price" do
        expect(product.available_price_cents).to match_array([5_00])
      end
    end

    context "for tiered membership" do
      context "when product has multiple tiers" do
        let(:recurrence_price_values) do
          [
            { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 10 } },
            { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 2 } }
          ]
        end
        let(:product) { create(:membership_product_with_preset_tiered_pricing, recurrence_price_values:) }

        it "returns the price available for all tiers" do
          expect(product.available_price_cents).to match_array([10_00, 2_00])
        end
      end

      context "when the tier has no prices" do
        let(:product) { create(:membership_product) }

        it "returns []" do
          product.default_tier.prices.destroy_all

          expect(product.available_price_cents).to be_empty
        end
      end
    end

    context "for a product with live variants" do
      let(:product) { create(:product, price_cents: 5_00) }
      let(:category) { create(:variant_category, link: product) }

      context "with no price differences" do
        let!(:variant) { create(:variant, variant_category: category, price_difference_cents: nil) }

        it "returns the default_price" do
          expect(product.available_price_cents).to match_array([5_00])
        end
      end

      context "with price differences" do
        let!(:variant1) { create(:variant, variant_category: category, price_difference_cents: 200) }
        let!(:variant2) { create(:variant, variant_category: category, price_difference_cents: 99) }
        let!(:variant3) { create(:variant, variant_category: category, price_difference_cents: 50, deleted_at: 1.hour.ago) }

        it "returns the default_price plus the live variant price difference" do
          expect(product.available_price_cents).to match_array([7_00, 5_99])
        end
      end

      context "with rent prices" do
        let(:product) { create(:product, price_cents: 5_00, rental_price_cents: 2_00, purchase_type: :buy_and_rent) }
        let!(:variant) { create(:variant, variant_category: category, price_difference_cents: 99) }

        it "ignores the rent price" do
          expect(product.available_price_cents).to match_array([5_99])
        end
      end
    end
  end

  describe "#display_price" do
    it "returns formatted display_price" do
      digital_product = create(:product, price_cents: 5_00)
      recurrence_price_values =             [
        { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 10 } },
        { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 2 } }
      ]
      membership_product = create(:membership_product_with_preset_tiered_pricing, recurrence_price_values:)

      expect(digital_product.display_price).to eq "$5"
      expect(membership_product.display_price).to eq "$2"
    end
  end

  describe "#price_formatted_verbose" do
    before :each do
      @product = create(:product, price_cents: 2_50)
    end

    it "returns the formatted price" do
      expect(@product.price_formatted_verbose).to eq "$2.50"
    end

    it "returns the formatted price for a pay-what-you-want product" do
      @product.update!(customizable_price: true)

      expect(@product.reload.price_formatted_verbose).to eq "$2.50+"
    end

    context "for a tiered membership" do
      before :each do
        recurrence_price_values =             [
          { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 3 }, BasePrice::Recurrence::YEARLY => { enabled: true, price: 30 } },
          { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 5 }, BasePrice::Recurrence::YEARLY => { enabled: true, price: 50 } }
        ]
        @product = create(:membership_product_with_preset_tiered_pricing, recurrence_price_values:, subscription_duration: BasePrice::Recurrence::YEARLY)
      end

      it "returns the formatted price for the minimum tier price" do
        expect(@product.price_formatted_verbose).to eq "$3+ a month"
      end

      it "includes a `+`" do
        @product.default_tier.update!(customizable_price: true)

        expect(@product.price_formatted_verbose).to eq "$3+ a month"
      end

      context "that has a single tier" do
        before :each do
          second_tier = @product.tiers.find_by!(name: "Second Tier")
          second_tier.prices.destroy_all
          second_tier.destroy
        end

        context "with multiple prices" do
          it "includes a `+`" do
            expect(@product.price_formatted_verbose).to eq "$3+ a month"
          end

          it "excludes rental prices" do
            @product.tiers.each do |tier|
              tier.prices.each do |price|
                price.is_rental = true
                price.save!
              end
            end
            @product.tiers.reload
            expect(@product.price_formatted_verbose).to eq "$0 a year"
          end
        end

        context "with a single price" do
          before :each do
            @first_tier = @product.tiers.find_by!(name: "First Tier")
            @first_tier.save_recurring_prices!({ BasePrice::Recurrence::YEARLY => { enabled: true, price: 2 } })
            expect(@first_tier.prices.alive.count).to eq 1
          end

          context "and is not pay-what-you-want" do
            it "does not include a `+`" do
              @product.tiers.reload
              expect(@product.price_formatted_verbose).to eq "$2 a year"
            end
          end

          context "and is pay-what-you-want" do
            it "includes a `+`" do
              @first_tier.update!(customizable_price: true)

              expect(@product.price_formatted_verbose).to eq "$2+ a year"
            end
          end
        end
      end

      context "when the tier has no prices" do
        it "returns $0 with the default subscription duration" do
          product = create(:membership_product, subscription_duration: BasePrice::Recurrence::YEARLY)
          product.default_tier.prices.destroy_all

          expect(product.price_formatted_verbose).to eq "$0 a year"
        end
      end
    end
  end

  describe "#base_price_formatted_without_dollar_sign" do
    context "when product is digital" do
      it "returns price not including version price" do
        category = create(:variant_category, link: @product)
        create(:variant, variant_category: category, name: "Version 1", price_difference_cents: 3_00)
        create(:variant, variant_category: category, name: "Version 2", price_difference_cents: 2_00)

        expect(@product.base_price_formatted_without_dollar_sign).to eq("2.50")
      end
    end

    context "when product is physical" do
      it "returns price not including variant price" do
        physical_link = create(:physical_product)
        category = create(:variant_category, link: physical_link, title: "Size")
        create(:variant, variant_category: category, name: "Small", price_difference_cents: 1_50)
        create(:variant, variant_category: category, name: "Large", price_difference_cents: 2_50)

        expect(physical_link.base_price_formatted_without_dollar_sign).to eq "1"
      end
    end

    context "when product is membership" do
      it "returns lowest tier price" do
        membership_product = create(:membership_product_with_preset_tiered_pricing)

        expect(membership_product.base_price_formatted_without_dollar_sign).to eq("3")
      end
    end
  end

  describe "#price_formatted_without_dollar_sign" do
    context "when product is digital" do
      it "returns price including price of least expensive version" do
        category = create(:variant_category, link: @product)
        create(:variant, variant_category: category, name: "Version 1", price_difference_cents: 3_00)
        create(:variant, variant_category: category, name: "Version 2", price_difference_cents: 2_00)

        expect(@product.price_formatted_without_dollar_sign).to eq("4.50")
      end
    end

    context "when product is physical" do
      it "returns price not including variant price" do
        physical_link = create(:physical_product)
        category = create(:variant_category, link: physical_link, title: "Size")
        create(:variant, variant_category: category, name: "Small", price_difference_cents: 1_50)
        create(:variant, variant_category: category, name: "Large", price_difference_cents: 2_50)

        expect(physical_link.price_formatted_without_dollar_sign).to eq "1"
      end
    end

    context "when product is membership" do
      it "returns lowest tier price" do
        membership_product = create(:membership_product_with_preset_tiered_pricing)

        expect(membership_product.price_formatted_without_dollar_sign).to eq("3")
      end
    end
  end

  describe "price_cents_for_recurrence" do
    it "returns the right price_cents" do
      expect(@subscription_product.price_cents_for_recurrence(BasePrice::Recurrence::MONTHLY)).to eq(4_00)
      expect(@subscription_product.price_cents_for_recurrence(BasePrice::Recurrence::YEARLY)).to eq(35_00)
    end
  end

  describe "price_formatted_without_dollar_sign_for_recurrence" do
    before do
      monthly_price = @subscription_product.default_price
      monthly_price.price_cents = 3_99
      monthly_price.save!
    end

    it "returns the right price_formatted_without_dollar_sign_for_recurrence" do
      expect(@subscription_product.price_formatted_without_dollar_sign_for_recurrence(BasePrice::Recurrence::MONTHLY)).to eq("3.99")
      expect(@subscription_product.price_formatted_without_dollar_sign_for_recurrence(BasePrice::Recurrence::YEARLY)).to eq("35")
    end
  end

  describe "has_price_for_recurrence?" do
    it "returns the right has_price_for_recurrence? value" do
      expect(@subscription_product.has_price_for_recurrence?(BasePrice::Recurrence::MONTHLY)).to eq(true)
      expect(@subscription_product.has_price_for_recurrence?(BasePrice::Recurrence::QUARTERLY)).to eq(false)
      expect(@subscription_product.has_price_for_recurrence?(BasePrice::Recurrence::BIANNUALLY)).to eq(false)
      expect(@subscription_product.has_price_for_recurrence?(BasePrice::Recurrence::YEARLY)).to eq(true)
    end
  end

  describe "suggested_price_cents_for_recurrence" do
    it "returns the right suggested_price_cents_for_recurrence price for recurrences that don't have prices" do
      expect(@subscription_product.send(:suggested_price_cents_for_recurrence, BasePrice::Recurrence::QUARTERLY)).to eq(12_00)
      expect(@subscription_product.send(:suggested_price_cents_for_recurrence, BasePrice::Recurrence::BIANNUALLY)).to eq(24_00)
    end

    it "returns the right suggested_price_cents_for_recurrence price for recurrences that have prices" do
      expect(@subscription_product.send(:suggested_price_cents_for_recurrence, BasePrice::Recurrence::MONTHLY)).to eq(4_00)
      expect(@subscription_product.send(:suggested_price_cents_for_recurrence, BasePrice::Recurrence::YEARLY)).to eq(35_00)
    end
  end

  describe "save_subscription_prices_and_duration!" do
    context "when the passed in subscription_duration is same as the value saved in the DB" do
      it "changes the prices of the recurrences properly" do
        recurrence_price_values = {
          BasePrice::Recurrence::MONTHLY => {
            enabled: true,
            price: "5"
          },
          BasePrice::Recurrence::YEARLY => {
            enabled: true,
            price: "40"
          }
        }

        @subscription_product.save_subscription_prices_and_duration!(recurrence_price_values:,
                                                                     subscription_duration: @subscription_product.subscription_duration)

        expect(@subscription_product.prices.alive.is_buy.count).to eq(2)
        expect(@subscription_product.price_cents_for_recurrence(BasePrice::Recurrence::MONTHLY)).to eq(5_00)
        expect(@subscription_product.price_cents_for_recurrence(BasePrice::Recurrence::YEARLY)).to eq(40_00)
      end

      it "adds and remove prices properly" do
        recurrence_price_values = {
          BasePrice::Recurrence::MONTHLY => {
            enabled: true,
            price: "5"
          },
          BasePrice::Recurrence::QUARTERLY => {
            enabled: true,
            price: "12"
          }
        }
        @subscription_product.save_subscription_prices_and_duration!(recurrence_price_values:,
                                                                     subscription_duration: @subscription_product.subscription_duration)

        expect(@subscription_product.prices.alive.is_buy.count).to eq(2)
        expect(@subscription_product.price_cents_for_recurrence(BasePrice::Recurrence::MONTHLY)).to eq(5_00)
        expect(@subscription_product.price_cents_for_recurrence(BasePrice::Recurrence::QUARTERLY)).to eq(12_00)
      end

      it "does not allow the default recurrence to be removed" do
        recurrence_price_values = {
          BasePrice::Recurrence::QUARTERLY => {
            enabled: true,
            price: "12"
          }
        }

        expect do
          @subscription_product.save_subscription_prices_and_duration!(recurrence_price_values:,
                                                                       subscription_duration: @subscription_product.subscription_duration)
        end.to raise_error(Link::LinkInvalid)
      end

      it "does not allow the a price to be created without an amount" do
        recurrence_price_values = {
          BasePrice::Recurrence::MONTHLY => {
            enabled: true,
            price: "5"
          },
          BasePrice::Recurrence::QUARTERLY => {
            enabled: true,
            price: ""
          }
        }

        expect do
          @subscription_product.save_subscription_prices_and_duration!(recurrence_price_values:,
                                                                       subscription_duration: @subscription_product.subscription_duration)
        end.to raise_error(Link::LinkInvalid)
      end
    end

    context "when the passed in subscription_duration is not the same as the value saved in the DB" do
      # Current subscription_duration: monthly
      it "saves the new subscription prices and duration" do
        recurrence_price_values = {
          BasePrice::Recurrence::MONTHLY => {
            enabled: true,
            price: "5"
          },
          BasePrice::Recurrence::QUARTERLY => {
            enabled: true,
            price: "12"
          }
        }
        @subscription_product.save_subscription_prices_and_duration!(recurrence_price_values:,
                                                                     subscription_duration: BasePrice::Recurrence::QUARTERLY)

        expect(@subscription_product.reload.subscription_duration.to_s).to eq(BasePrice::Recurrence::QUARTERLY)
        expect(@subscription_product.prices.alive.is_buy.count).to eq(2)
        expect(@subscription_product.price_cents_for_recurrence(BasePrice::Recurrence::MONTHLY)).to eq(5_00)
        expect(@subscription_product.price_cents_for_recurrence(BasePrice::Recurrence::QUARTERLY)).to eq(12_00)
      end

      it "does not save the subscription_duration if saving the price fails" do
        recurrence_price_values = {
          BasePrice::Recurrence::MONTHLY => {
            enabled: true,
            price: "5"
          },
          BasePrice::Recurrence::QUARTERLY => {
            enabled: true,
            price: "" # Invalid
          }
        }

        expect do
          expect do
            @subscription_product.save_subscription_prices_and_duration!(recurrence_price_values:,
                                                                         subscription_duration: BasePrice::Recurrence::QUARTERLY)
          end.to raise_error(Link::LinkInvalid)
        end.to_not change { [Price.count, @subscription_product.reload.subscription_duration] }
      end

      it "does not save prices if the price for the new subscription duration is missing" do
        recurrence_price_values = {
          BasePrice::Recurrence::MONTHLY => {
            enabled: true,
            price: "12"
          }
        }

        expect do
          expect do
            @subscription_product.save_subscription_prices_and_duration!(recurrence_price_values:,
                                                                         subscription_duration: BasePrice::Recurrence::BIANNUALLY)
          end.to raise_error(Link::LinkInvalid)
        end.to_not change { [Price.count, @subscription_product.reload.subscription_duration] }
      end
    end
  end

  describe "#save_recurring_prices!" do
    before :each do
      @product = create(:product)
      @recurrence_price_values = {
        BasePrice::Recurrence::MONTHLY => {
          enabled: true,
          price: "20",
          suggested_price: "25"
        },
        BasePrice::Recurrence::YEARLY => {
          enabled: true,
          price: "99.99",
          suggested_price: ""
        },
        BasePrice::Recurrence::BIANNUALLY => { enabled: false }
      }
    end

    it "saves valid prices" do
      @product.save_recurring_prices!(@recurrence_price_values)

      prices = @product.reload.prices.alive
      monthly_price = prices.find_by!(recurrence: BasePrice::Recurrence::MONTHLY)
      yearly_price = prices.find_by!(recurrence: BasePrice::Recurrence::YEARLY)

      expect(prices.length).to eq 2
      expect(monthly_price.price_cents).to eq 2000
      expect(monthly_price.suggested_price_cents).to eq 2500
      expect(yearly_price.price_cents).to eq 9999
      expect(yearly_price.suggested_price_cents).to be_nil
    end

    it "deletes any old prices" do
      biannual_price = create(:price, link: @product, recurrence: BasePrice::Recurrence::BIANNUALLY)
      quarterly_price = create(:price, link: @product, recurrence: BasePrice::Recurrence::QUARTERLY)
      non_recurring_price = create(:price, link: @product, recurrence: nil)

      @product.save_recurring_prices!(@recurrence_price_values)

      expect(@product.prices.alive.length).to eq 2
      expect(biannual_price.reload).to be_deleted
      expect(quarterly_price.reload).to be_deleted
      expect(non_recurring_price.reload).to be_deleted
    end

    context "updating Elasticsearch" do
      before :each do
        @product.save_recurring_prices!(@recurrence_price_values)
      end

      it "enqueues Elasticsearch update if a price is new or has changed" do
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

        expect(@product).to receive(:enqueue_index_update_for).with(["price_cents", "available_price_cents"]).twice

        @product.save_recurring_prices!(updated_recurrence_prices)
      end

      it "does not enqueue Elasticsearch update if prices have not changed" do
        expect(@product).not_to receive(:enqueue_index_update_for).with(["price_cents", "available_price_cents"])

        @product.save_recurring_prices!(@recurrence_price_values)
      end
    end

    context "missing price" do
      it "raises an error" do
        invalid_values = @recurrence_price_values
        invalid_values[BasePrice::Recurrence::MONTHLY].delete(:price)

        expect do
          @product.save_recurring_prices!(invalid_values)
        end.to raise_error Link::LinkInvalid
      end
    end
  end
end
