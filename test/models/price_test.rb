# frozen_string_literal: true

require "test_helper"

class PriceTest < ActiveSupport::TestCase
  self.described_class = Price



  context_ Price do
  test "belongs to a link" do
      price = create(:price)
      expect(price.link).to be_a Link
    end

  test "validates presence of the link" do
      invalid_price = create(:price)
      invalid_price.link = nil
      expect(invalid_price).not_to be_valid
      expect(invalid_price.errors.full_messages).to include "Link can't be blank"
    end

  context_ "recurrence validation" do
  context_ "for a product without recurring billing" do
  test "does not require recurrence to be set" do
          product = create(:product)
          price = build(:price, link: product, recurrence: nil)
          expect(price).to be_valid
        end
      end

  context_ "for a product with recurring billing " do
        before :each do
          @product = create(:subscription_product)
        end

  test "must set recurrence" do
          price = build(:price, link: @product, recurrence: nil)
          expect(price).not_to be_valid
        end

  test "must be one of the permitted recurrences" do
          BasePrice::Recurrence.all.each do |recurrence|
            price = build(:price, link: @product, recurrence:)
            expect(price).to be_valid
          end

          invalid_price = build(:price, link: @product, recurrence: "whenever")
          expect(invalid_price).not_to be_valid
          expect(invalid_price.errors.full_messages).to include "Invalid recurrence"
        end
      end
    end

  context_ ".alive" do
  test "excludes deleted prices" do
        product = create(:product)
        live_price = product.default_price
        create(:price, link: product, deleted_at: Time.current)

        expect(Price.alive).to match_array([live_price])
      end
    end

  context_ "#alive?" do
  test "returns true if not deleted" do
        price = create(:price)

        expect(price.alive?).to eq true
      end

  test "returns false if price is deleted" do
        price = create(:price, deleted_at: Time.current)

        expect(price.alive?).to eq false
      end
    end

  context_ "as_json" do
      before do
        @product = create(:subscription_product, price_cents: 10_00)
        @price_monthly = @product.default_price
      end

  test "has the proper json" do
        expect(@price_monthly.as_json).to eq(id: @price_monthly.external_id,
                                             price_cents: 10_00,
                                             recurrence: "monthly",
                                             recurrence_formatted: " a month")
      end

  test "includes product duration if it exists" do
        @product.update_attribute(:duration_in_months, 6)
        expect(@price_monthly.as_json).to eq(id: @price_monthly.external_id,
                                             price_cents: 10_00,
                                             recurrence: "monthly",
                                             recurrence_formatted: " a month x 6")
      end
    end
  end
end
