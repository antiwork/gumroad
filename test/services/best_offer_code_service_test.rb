# frozen_string_literal: true

require "test_helper"

class BestOfferCodeServiceTest < ActiveSupport::TestCase
  self.described_class = BestOfferCodeService



  context_ BestOfferCodeService do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller, price_cents: 1000, price_currency_type: "usd") }
    let(:url_code) { nil }
    let(:quantity) { 1 }

    subject { described_class.new(product: product, url_code: url_code, quantity: quantity) }

  context_ "#result" do
  context_ "when both codes are blank" do
  test "returns nil" do
          expect(subject.result).to be_nil
        end

  context_ "when both are empty strings" do
          let(:url_code) { "" }

          before do
            product.update!(default_offer_code: nil)
          end

  test "returns nil" do
            expect(subject.result).to be_nil
          end
        end
      end

  context_ "when only url_code is provided" do
        let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, currency_type: product.price_currency_type) }

  context_ "and it is valid" do
          let(:url_code) { url_offer_code.code }

  test "returns the url_code" do
            expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
            expect(subject.result&.dig(:valid)).to be(true)
          end
        end

  context_ "and it is invalid" do
          let(:url_code) { "INVALID" }

  test "returns error result" do
            expect(subject.result).to eq({ valid: false, error_code: :invalid_offer })
          end
        end
      end

  context_ "when only default_code is provided" do
        let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 200, currency_type: product.price_currency_type) }

        before do
          product.update!(default_offer_code: default_offer_code)
        end

  context_ "and it is valid" do
  test "returns the default_code" do
            expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
            expect(subject.result&.dig(:valid)).to be(true)
          end
        end

  context_ "and it is invalid" do
          before do
            product.update!(default_offer_code: nil)
          end

  test "returns nil when both codes are blank" do
            expect(subject.result).to be_nil
          end
        end

  context_ "and it is expired" do
          before do
            default_offer_code.update_column(:expires_at, 1.day.ago)
          end

  test "returns nil rather than an error (buyer did not apply the code)" do
            expect(subject.result).to be_nil
          end
        end
      end

  context_ "when both codes are provided" do
        let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, currency_type: product.price_currency_type) }
        let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 300, currency_type: product.price_currency_type) }

        before do
          product.update!(default_offer_code: default_offer_code)
        end

  context_ "and both are valid" do
          let(:url_code) { url_offer_code.code }

  context_ "when url_code has a better discount (fixed amount)" do
            let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 400, currency_type: product.price_currency_type) }
            let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 200, currency_type: product.price_currency_type) }

  test "returns the url_code" do
              expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
              expect(subject.result&.dig(:valid)).to be(true)
            end
          end

  context_ "when default_code has a better discount (fixed amount)" do
            let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, currency_type: product.price_currency_type) }
            let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 400, currency_type: product.price_currency_type) }

  test "returns the default_code" do
              expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
              expect(subject.result&.dig(:valid)).to be(true)
            end
          end

  context_ "when url_code has a better discount (percentage)" do
            let(:url_offer_code) { create(:offer_code, products: [product], code: "URL30", amount_percentage: 30, amount_cents: nil, currency_type: product.price_currency_type) }
            let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT20", amount_percentage: 20, amount_cents: nil, currency_type: product.price_currency_type) }

  test "returns the url_code" do
              expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
              expect(subject.result&.dig(:valid)).to be(true)
            end
          end

  context_ "when default_code has a better discount (percentage)" do
            let(:url_offer_code) { create(:offer_code, products: [product], code: "URL20", amount_percentage: 20, amount_cents: nil, currency_type: product.price_currency_type) }
            let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT30", amount_percentage: 30, amount_cents: nil, currency_type: product.price_currency_type) }

  test "returns the default_code" do
              expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
              expect(subject.result&.dig(:valid)).to be(true)
            end
          end

  context_ "when discounts are equal" do
            let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, currency_type: product.price_currency_type) }
            let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 200, currency_type: product.price_currency_type) }

  test "returns the default_code (tie goes to default)" do
              expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
              expect(subject.result&.dig(:valid)).to be(true)
            end
          end

  context_ "when comparing fixed amount vs percentage" do
  context_ "and fixed amount is better" do
              let(:url_offer_code) { create(:offer_code, products: [product], code: "URL_FIXED", amount_cents: 400, currency_type: product.price_currency_type) }
              let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT_PERCENT", amount_percentage: 30, amount_cents: nil, currency_type: product.price_currency_type) }

  test "returns the code with better discount (400 cents > 30% of 1000 = 300 cents)" do
                expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
                expect(subject.result&.dig(:valid)).to be(true)
              end
            end

  context_ "and percentage is better" do
              let(:url_offer_code) { create(:offer_code, products: [product], code: "URL_PERCENT", amount_percentage: 50, amount_cents: nil, currency_type: product.price_currency_type) }
              let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT_FIXED", amount_cents: 200, currency_type: product.price_currency_type) }

  test "returns the code with better discount (50% of 1000 = 500 cents > 200 cents)" do
                expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
                expect(subject.result&.dig(:valid)).to be(true)
              end
            end
          end
        end

  context_ "when url_code is valid and default_code is invalid" do
          let(:url_code) { url_offer_code.code }

          before do
            product.update!(default_offer_code: nil)
          end

  test "returns the url_code" do
            expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
            expect(subject.result&.dig(:valid)).to be(true)
          end
        end

  context_ "when url_code is invalid and default_code is valid" do
          let(:url_code) { "INVALID" }

  test "returns the default_code" do
            expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
            expect(subject.result&.dig(:valid)).to be(true)
          end
        end

  context_ "when both are invalid" do
          let(:url_code) { "INVALID1" }

          before do
            product.update!(default_offer_code: nil)
          end

  test "returns error result for url_code" do
            expect(subject.result).to eq({ valid: false, error_code: :invalid_offer })
          end
        end
      end

  context_ "with quantity considerations" do
        let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 400, minimum_quantity: 2, currency_type: product.price_currency_type) }
        let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 300, minimum_quantity: 1, currency_type: product.price_currency_type) }
        let(:url_code) { url_offer_code.code }

        before do
          product.update!(default_offer_code: default_offer_code)
        end

  context_ "when quantity meets minimum for url_code" do
          let(:quantity) { 2 }

  test "considers url_code valid and returns it when it has better discount" do
            expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
            expect(subject.result&.dig(:valid)).to be(true)
          end
        end

  context_ "when quantity does not meet minimum for url_code" do
          let(:quantity) { 1 }
          let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, minimum_quantity: 2, currency_type: product.price_currency_type) }

  test "returns default_code" do
            expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
            expect(subject.result&.dig(:valid)).to be(true)
          end
        end
      end

  context_ "with inactive offer codes" do
        let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, valid_at: 1.day.from_now, currency_type: product.price_currency_type) }
        let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 300, currency_type: product.price_currency_type) }
        let(:url_code) { url_offer_code.code }

        before do
          product.update!(default_offer_code: default_offer_code)
        end

  test "treats inactive url_code as invalid" do
          expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
          expect(subject.result&.dig(:valid)).to be(true)
        end
      end

  context_ "with expired offer codes" do
        let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, valid_at: 2.days.ago, expires_at: 1.day.ago, currency_type: product.price_currency_type) }
        let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 300, currency_type: product.price_currency_type) }
        let(:url_code) { url_offer_code.code }

        before do
          product.update!(default_offer_code: default_offer_code)
        end

  test "treats expired url_code as invalid" do
          expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
          expect(subject.result&.dig(:valid)).to be(true)
        end

  context_ "when the default code is also expired" do
          let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, valid_at: 2.days.ago, currency_type: product.price_currency_type) }
          let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 300, valid_at: 2.days.ago, currency_type: product.price_currency_type) }

          before do
            url_offer_code.update_column(:expires_at, 1.day.ago)
            default_offer_code.update_column(:expires_at, 1.day.ago)
          end

  test "returns the url_code's error (buyer explicitly applied it)" do
            expect(subject.result).to eq({ valid: false, error_code: :inactive })
          end
        end
      end

  context_ "with sold out offer codes" do
        let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, max_purchase_count: 0, currency_type: product.price_currency_type) }
        let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 300, currency_type: product.price_currency_type) }
        let(:url_code) { url_offer_code.code }

        before do
          product.update!(default_offer_code: default_offer_code)
        end

  test "treats sold out url_code as invalid" do
          expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
          expect(subject.result&.dig(:valid)).to be(true)
        end
      end

  context_ "with offer codes that don't apply to the product" do
        let(:other_product) { create(:product, user: seller, price_cents: 1000, price_currency_type: "usd") }
        let(:url_offer_code) { create(:offer_code, products: [other_product], code: "URL10", amount_cents: 200, currency_type: other_product.price_currency_type) }
        let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 300, currency_type: product.price_currency_type) }
        let(:url_code) { url_offer_code.code }

        before do
          product.update!(default_offer_code: default_offer_code)
        end

  test "treats non-applicable url_code as invalid" do
          expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
          expect(subject.result&.dig(:valid)).to be(true)
        end
      end

  context_ "with universal offer codes" do
        let(:default_offer_code) { create(:offer_code, products: [product], code: "DEFAULT10", amount_cents: 300, currency_type: product.price_currency_type) }
        let(:url_code) { url_offer_code.code }

        before do
          product.update!(default_offer_code: default_offer_code)
        end

  context_ "when url_code is better" do
          let(:url_offer_code) { create(:universal_offer_code, user: seller, code: "URL10", amount_cents: 400, currency_type: product.price_currency_type) }

  test "returns the url_code" do
            expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
            expect(subject.result&.dig(:valid)).to be(true)
          end
        end

  context_ "when default_code is better" do
          let(:url_offer_code) { create(:universal_offer_code, user: seller, code: "URL10", amount_cents: 200, currency_type: product.price_currency_type) }

  test "returns the default_code" do
            expect(subject.result&.dig(:code)).to eq(default_offer_code.code)
            expect(subject.result&.dig(:valid)).to be(true)
          end
        end
      end

  context_ "with default quantity" do
        let(:url_offer_code) { create(:offer_code, products: [product], code: "URL10", amount_cents: 200, currency_type: product.price_currency_type) }
        let(:url_code) { url_offer_code.code }

  test "uses quantity of 1 by default" do
          expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
          expect(subject.result&.dig(:valid)).to be(true)
        end
      end

  context_ "with an existing-customer-only code" do
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

  test "rejects when buyer does not own the required product" do
          result = subject.result
          expect(result).to include(valid: false, error_code: :not_existing_customer)
        end

  test "applies when buyer owns the required product" do
          create(:purchase, purchaser: buyer, link: product, seller:, price_cents: product.price_cents)
          expect(subject.result&.dig(:valid)).to be(true)
          expect(subject.result&.dig(:code)).to eq("RENEW50")
        end
      end
    end
  end
end
