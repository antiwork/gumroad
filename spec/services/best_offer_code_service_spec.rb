# frozen_string_literal: true

require "spec_helper"

describe BestOfferCodeService do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 1000, price_currency_type: "usd") }
  let(:url_code) { nil }
  let(:quantity) { 1 }

  subject { described_class.new(product: product, url_code: url_code, quantity: quantity) }

  describe "#result" do
    context "when both codes are blank" do
      it "returns nil" do
        expect(subject.result).to be_nil
      end

      context "when both are empty strings" do
        let(:url_code) { "" }

        before do
          product.update!(default_offer_code: nil)
        end

        it "returns nil" do
          expect(subject.result).to be_nil
        end
      end
    end

    context "when only url_code is provided" do
      let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, currency_type: product.price_currency_type) }

      context "and it is valid" do
        let(:url_code) { url_offer_code.code }

        it "returns the url_code" do
          result = subject.result

          expect(result&.dig(:code)).to eq(url_offer_code.code)
          expect(result&.dig(:valid)).to be(true)
          expect(result).not_to have_key(:offer_code)
        end
      end

      context "and it is invalid" do
        let(:url_code) { "INVALID" }

        it "returns error result" do
          expect(subject.result).to eq({ valid: false, error_code: :invalid_offer })
        end
      end

      context "and it has leading whitespace" do
        let(:url_code) { " #{url_offer_code.code}" }

        it "matches the code and echoes it as submitted" do
          result = subject.result

          expect(result&.dig(:valid)).to be(true)
          expect(result&.dig(:code)).to eq(" URL10")
        end
      end
    end

    context "when only default_code is provided" do
      let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 200, currency_type: product.price_currency_type) }

      before do
        product.update!(default_offer_code: default_offer_code)
      end

      context "and it is valid" do
        it "returns the default_code" do
          expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
          expect(subject.result&.dig(:valid)).to be(true)
        end
      end

      context "and it is invalid" do
        before do
          product.update!(default_offer_code: nil)
        end

        it "returns nil when both codes are blank" do
          expect(subject.result).to be_nil
        end
      end

      context "and it is expired" do
        before do
          default_offer_code.update_column(:expires_at, 1.day.ago)
        end

        it "returns nil rather than an error (buyer did not apply the code)" do
          expect(subject.result).to be_nil
        end
      end
    end

    context "when both codes are provided" do
      let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, currency_type: product.price_currency_type) }
      let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 300, currency_type: product.price_currency_type) }

      before do
        product.update!(default_offer_code: default_offer_code)
      end

      context "and both are valid" do
        let(:url_code) { url_offer_code.code }

        context "when url_code has a better discount (fixed amount)" do
          let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 400, currency_type: product.price_currency_type) }
          let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 200, currency_type: product.price_currency_type) }

          it "returns the url_code" do
            expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
            expect(subject.result&.dig(:valid)).to be(true)
          end
        end

        context "when default_code has a better discount (fixed amount)" do
          let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, currency_type: product.price_currency_type) }
          let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 400, currency_type: product.price_currency_type) }

          it "returns the default_code" do
            expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
            expect(subject.result&.dig(:valid)).to be(true)
          end
        end

        context "when url_code has a better discount (percentage)" do
          let(:url_offer_code) { create(:offer_code, products: [product], code: "URL30", amount_percentage: 30, amount_cents: nil, currency_type: product.price_currency_type) }
          let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT20", amount_percentage: 20, amount_cents: nil, currency_type: product.price_currency_type) }

          it "returns the url_code" do
            expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
            expect(subject.result&.dig(:valid)).to be(true)
          end
        end

        context "when default_code has a better discount (percentage)" do
          let(:url_offer_code) { create(:offer_code, products: [product], code: "URL20", amount_percentage: 20, amount_cents: nil, currency_type: product.price_currency_type) }
          let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT30", amount_percentage: 30, amount_cents: nil, currency_type: product.price_currency_type) }

          it "returns the default_code" do
            expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
            expect(subject.result&.dig(:valid)).to be(true)
          end
        end

        context "when the buyer qualifies for a better ownership tier" do
          let(:buyer) { create(:user) }
          let(:url_offer_code) do
            create(
              :tiered_offer_code,
              user: seller,
              products: [product],
              code: "URL_TIERED"
            )
          end
          let(:default_offer_code) do
            create(
              :offer_code,
              products: [product],
              code: "DEFAULT20",
              amount_cents: nil,
              amount_percentage: 20,
              currency_type: product.price_currency_type
            )
          end
          let(:url_code) { url_offer_code.code }

          subject { described_class.new(product:, url_code:, quantity:, buyer:) }

          before do
            create(:purchase, purchaser: buyer, link: product, seller:, created_at: 13.months.ago)
          end

          it "compares the percentage resolved for the buyer" do
            expect(subject.result).to include(
              code: url_offer_code.code,
              discount: include(percents: 50)
            )
          end
        end

        context "when discounts are equal" do
          let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, currency_type: product.price_currency_type) }
          let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 200, currency_type: product.price_currency_type) }

          it "returns the default_code (tie goes to default)" do
            expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
            expect(subject.result&.dig(:valid)).to be(true)
          end
        end

        context "when comparing fixed amount vs percentage" do
          context "and fixed amount is better" do
            let(:url_offer_code) { create(:offer_code, products: [product], code: "URL_FIXED", amount_cents: 400, currency_type: product.price_currency_type) }
            let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT_PERCENT", amount_percentage: 30, amount_cents: nil, currency_type: product.price_currency_type) }

            it "returns the code with better discount (400 cents > 30% of 1000 = 300 cents)" do
              expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
              expect(subject.result&.dig(:valid)).to be(true)
            end
          end

          context "and percentage is better" do
            let(:url_offer_code) { create(:offer_code, products: [product], code: "URL_PERCENT", amount_percentage: 50, amount_cents: nil, currency_type: product.price_currency_type) }
            let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT_FIXED", amount_cents: 200, currency_type: product.price_currency_type) }

            it "returns the code with better discount (50% of 1000 = 500 cents > 200 cents)" do
              expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
              expect(subject.result&.dig(:valid)).to be(true)
            end
          end
        end
      end

      context "when url_code is valid and default_code is invalid" do
        let(:url_code) { url_offer_code.code }

        before do
          product.update!(default_offer_code: nil)
        end

        it "returns the url_code" do
          expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
          expect(subject.result&.dig(:valid)).to be(true)
        end
      end

      context "when url_code is invalid and default_code is valid" do
        let(:url_code) { "INVALID" }

        it "returns the default_code" do
          expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
          expect(subject.result&.dig(:valid)).to be(true)
        end
      end

      context "when both are invalid" do
        let(:url_code) { "INVALID1" }

        before do
          product.update!(default_offer_code: nil)
        end

        it "returns error result for url_code" do
          expect(subject.result).to eq({ valid: false, error_code: :invalid_offer })
        end
      end
    end

    context "with quantity considerations" do
      let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 400, minimum_quantity: 2, currency_type: product.price_currency_type) }
      let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 300, minimum_quantity: 1, currency_type: product.price_currency_type) }
      let(:url_code) { url_offer_code.code }

      before do
        product.update!(default_offer_code: default_offer_code)
      end

      context "when quantity meets minimum for url_code" do
        let(:quantity) { 2 }

        it "considers url_code valid and returns it when it has better discount" do
          expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
          expect(subject.result&.dig(:valid)).to be(true)
        end
      end

      context "when quantity does not meet minimum for url_code" do
        let(:quantity) { 1 }
        let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, minimum_quantity: 2, currency_type: product.price_currency_type) }

        it "returns default_code" do
          expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
          expect(subject.result&.dig(:valid)).to be(true)
        end
      end

      context "when comparing a once-per-cart fixed code with a percentage code" do
        let(:quantity) { 10 }
        let(:url_offer_code) do
          create(:offer_code, products: [product], code: "URL_FIXED", amount_cents: 1000, currency_type: product.price_currency_type,
                              once_per_cart: true)
        end
        let(:default_offer_code) do
          create(:offer_code, products: [product], code: "DEFAULT_PERCENT", amount_cents: nil, amount_percentage: 20,
                              currency_type: product.price_currency_type)
        end

        it "chooses the code that saves more across the full quantity" do
          expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
        end
      end

      context "when percentage rounding differs between one unit and the total" do
        let(:product) { create(:product, user: seller, price_cents: 199, price_currency_type: "usd") }
        let(:quantity) { 2 }
        let(:url_offer_code) do
          create(:offer_code, products: [product], code: "URL_PERCENT", amount_cents: nil, amount_percentage: 50,
                              currency_type: product.price_currency_type)
        end
        let(:default_offer_code) do
          create(:offer_code, products: [product], code: "DEFAULT_FIXED", amount_cents: 199,
                              currency_type: product.price_currency_type, once_per_cart: true)
        end

        it "uses the same per-unit rounding as checkout" do
          expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
        end
      end
    end

    context "with inactive offer codes" do
      let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, valid_at: 1.day.from_now, currency_type: product.price_currency_type) }
      let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 300, currency_type: product.price_currency_type) }
      let(:url_code) { url_offer_code.code }

      before do
        product.update!(default_offer_code: default_offer_code)
      end

      it "treats inactive url_code as invalid" do
        expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
        expect(subject.result&.dig(:valid)).to be(true)
      end
    end

    context "with expired offer codes" do
      let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, valid_at: 2.days.ago, expires_at: 1.day.ago, currency_type: product.price_currency_type) }
      let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 300, currency_type: product.price_currency_type) }
      let(:url_code) { url_offer_code.code }

      before do
        product.update!(default_offer_code: default_offer_code)
      end

      it "treats expired url_code as invalid" do
        expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
        expect(subject.result&.dig(:valid)).to be(true)
      end

      context "when the default code is also expired" do
        let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, valid_at: 2.days.ago, currency_type: product.price_currency_type) }
        let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 300, valid_at: 2.days.ago, currency_type: product.price_currency_type) }

        before do
          url_offer_code.update_column(:expires_at, 1.day.ago)
          default_offer_code.update_column(:expires_at, 1.day.ago)
        end

        it "returns the url_code's error (buyer explicitly applied it)" do
          expect(subject.result).to eq({ valid: false, error_code: :inactive })
        end
      end
    end

    context "with sold out offer codes" do
      let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, max_purchase_count: 0, currency_type: product.price_currency_type) }
      let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 300, currency_type: product.price_currency_type) }
      let(:url_code) { url_offer_code.code }

      before do
        product.update!(default_offer_code: default_offer_code)
      end

      it "treats sold out url_code as invalid" do
        expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
        expect(subject.result&.dig(:valid)).to be(true)
      end
    end

    context "with offer codes that don't apply to the product" do
      let(:other_product) { create(:product, user: seller, price_cents: 1000, price_currency_type: "usd") }
      let(:url_offer_code) { create(:offer_code, products: [other_product], code: "URL10", amount_cents: 200, currency_type: other_product.price_currency_type) }
      let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 300, currency_type: product.price_currency_type) }
      let(:url_code) { url_offer_code.code }

      before do
        product.update!(default_offer_code: default_offer_code)
      end

      it "treats non-applicable url_code as invalid" do
        expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
        expect(subject.result&.dig(:valid)).to be(true)
      end
    end

    context "with universal offer codes" do
      let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 300, currency_type: product.price_currency_type) }
      let(:url_code) { url_offer_code.code }

      before do
        product.update!(default_offer_code: default_offer_code)
      end

      context "when url_code is better" do
        let(:url_offer_code) { create(:universal_offer_code, user: seller, code: "URL10", amount_cents: 400, currency_type: product.price_currency_type) }

        it "returns the url_code" do
          expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
          expect(subject.result&.dig(:valid)).to be(true)
        end
      end

      context "when default_code is better" do
        let(:url_offer_code) { create(:universal_offer_code, user: seller, code: "URL10", amount_cents: 200, currency_type: product.price_currency_type) }

        it "returns the default_code" do
          expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
          expect(subject.result&.dig(:valid)).to be(true)
        end
      end
    end

    context "with default quantity" do
      let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, currency_type: product.price_currency_type) }
      let(:url_code) { url_offer_code.code }

      it "uses quantity of 1 by default" do
        expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
        expect(subject.result&.dig(:valid)).to be(true)
      end
    end

    context "with an existing-customer-only code" do
      let(:buyer) { create(:user) }
      let!(:url_offer_code) do
        create(:offer_code,
               user: seller,
               products: [product],
               ownership_products: [product],
               existing_customers_only: true,
               code: "RENEW50",
               amount_cents: nil,
               amount_percentage: 50,
               currency_type: nil)
      end
      let(:url_code) { "RENEW50" }

      subject { described_class.new(product: product, url_code: url_code, buyer: buyer) }

      it "rejects when buyer does not own the required product" do
        result = subject.result
        expect(result).to include(valid: false, error_code: :not_existing_customer)
      end

      it "applies when buyer owns the required product" do
        create(:purchase, purchaser: buyer, link: product, seller:, price_cents: product.price_cents)
        expect(subject.result&.dig(:valid)).to be(true)
        expect(subject.result&.dig(:code)).to eq("RENEW50")
      end
    end
  end

  describe "shop-wide auto-applied code" do
    let(:auto_code) { seller.offer_codes.create!(code: "SHOP30", amount_percentage: 30, universal: true, products: [], auto_apply: true) }

    before { Current.reset }

    it "applies with no url code" do
      auto_code
      result = described_class.new(product: product).result

      expect(result).to include(valid: true, code: "SHOP30")
      expect(result[:discount][:percents]).to eq(30)
    end

    it "lets an explicit per-product default win" do
      auto_code
      own = create(:percentage_offer_code, products: [product], code: "OWN10", amount_percentage: 10)
      product.update!(default_offer_code: own)

      expect(described_class.new(product: product).result).to include(valid: true, code: "OWN10")
    end

    context "with an existing-customers-only default" do
      let(:buyer) { create(:user) }
      let(:own) do
        create(:offer_code, user: seller, products: [product], ownership_products: [product], existing_customers_only: true,
                            code: "RENEW50", amount_cents: nil, amount_percentage: 50, currency_type: nil)
      end

      before do
        auto_code
        product.update!(default_offer_code: own)
      end

      it "gives a buyer who does not qualify the shop-wide sale" do
        expect(described_class.new(product:, buyer:).result).to include(valid: true, code: "SHOP30")
      end

      it "keeps a larger existing-customer default for a buyer who qualifies" do
        create(:purchase, purchaser: buyer, link: product, seller:, price_cents: product.price_cents)

        expect(described_class.new(product:, buyer:).result).to include(valid: true, code: "RENEW50")
      end

      [[10, "SHOP30", "the larger shop-wide sale"], [30, "RENEW30", "their default on a tie"]].each do |percentage, winner, outcome|
        context "when a qualifying buyer's default takes #{percentage}% off" do
          let(:own) do
            create(:offer_code, user: seller, products: [product], ownership_products: [product], existing_customers_only: true,
                                code: "RENEW#{percentage}", amount_cents: nil, amount_percentage: percentage, currency_type: nil)
          end

          it "gives them #{outcome}" do
            create(:purchase, purchaser: buyer, link: product, seller:, price_cents: product.price_cents)

            expect(described_class.new(product:, buyer:).result).to include(valid: true, code: winner)
          end
        end
      end

      [[{ minimum_quantity: 2 }, "quantity"], [{ minimum_amount_cents: 20_00 }, "spend"]].each do |minimum, kind|
        context "when a larger sale has a #{kind} minimum" do
          let(:auto_code) do
            seller.offer_codes.create!(code: "SHOP50", amount_percentage: 50, universal: true, products: [], auto_apply: true, **minimum)
          end
          let(:own) do
            create(:offer_code, user: seller, products: [product], ownership_products: [product], existing_customers_only: true,
                                code: "RENEW20", amount_cents: nil, amount_percentage: 20, currency_type: nil)
          end

          it "keeps a qualifying buyer's default until the order meets the sale's minimum" do
            create(:purchase, purchaser: buyer, link: product, seller:, price_cents: product.price_cents)

            expect(described_class.new(product:, buyer:).result).to include(valid: true, code: "RENEW20")
            expect(described_class.new(product:, buyer:, quantity: 2).result).to include(valid: true, code: "SHOP50")
          end
        end
      end

      context "when a fixed default no longer matches the product currency" do
        let(:own) do
          create(:offer_code, user: seller, products: [product], ownership_products: [product], existing_customers_only: true,
                              code: "RENEW5", amount_cents: 500, currency_type: "usd")
        end

        it "gives a qualifying buyer the shop-wide sale" do
          create(:purchase, purchaser: buyer, link: product, seller:, price_cents: product.price_cents)
          product.update!(price_currency_type: "eur", price_range: "10")

          result = described_class.new(product:, buyer:).result

          expect(result).to include(valid: true, code: "SHOP30")
          expect(result[:discount]).to include(type: "percent", percents: 30)
        end
      end
    end

    context "with an existing-customers-only default on a membership priced only by its tiers" do
      let(:product) do
        create(:membership_product_with_preset_tiered_pricing, user: seller,
                                                               recurrence_price_values: [{ monthly: { enabled: true, price: 10 } }, { monthly: { enabled: true, price: 20 } }])
      end
      let(:owned) { create(:product, user: seller, price_cents: 10_00) }
      let(:buyer) { create(:user) }

      before do
        auto_code
        create(:purchase, purchaser: buyer, link: owned, seller:, price_cents: owned.price_cents)
      end

      it "weighs a percent default on the lowest tier, so only a larger one beats the sale" do
        own = create(:offer_code, user: seller, products: [product], ownership_products: [owned], existing_customers_only: true,
                                  code: "RENEW", amount_cents: nil, amount_percentage: 10, currency_type: nil)
        product.update!(default_offer_code: own)

        expect(described_class.new(product:, buyer:).result).to include(valid: true, code: "SHOP30")
        expect(product.price_cents).to eq(0)
        expect(product.display_price_cents(for_default_duration: true)).to eq(10_00)

        own.update!(amount_percentage: 50)

        expect(described_class.new(product:, buyer:).result).to include(valid: true, code: "RENEW")
      end

      it "weighs a fixed default against the sale's share of the lowest tier, so only a larger one beats it" do
        own = create(:offer_code, user: seller, products: [product], ownership_products: [owned], existing_customers_only: true,
                                  code: "RENEW", amount_cents: 2_00, currency_type: "usd")
        product.update!(default_offer_code: own)

        expect(described_class.new(product:, buyer:).result).to include(valid: true, code: "SHOP30")
        expect(product.price_cents).to eq(0)
        expect(product.display_price_cents(for_default_duration: true)).to eq(10_00)

        own.update!(amount_cents: 5_00)

        expect(described_class.new(product:, buyer:).result).to include(valid: true, code: "RENEW")
      end
    end

    it "gives no discount to an excluded product" do
      auto_code.update!(excluded_products: [product])

      expect(described_class.new(product: product).result).to be_nil
    end

    it "gives no discount outside the validity window" do
      auto_code.update!(valid_at: 2.days.from_now, expires_at: 9.days.from_now)
      expect(described_class.new(product: product).result).to be_nil

      Current.reset
      auto_code.update!(valid_at: 9.days.ago, expires_at: 2.days.ago)
      expect(described_class.new(product: product).result).to be_nil
    end

    it "gives no discount once auto apply is off" do
      auto_code.update!(auto_apply: false)

      expect(described_class.new(product: product).result).to be_nil
    end
  end
end
