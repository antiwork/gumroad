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
          expect(subject.result&.dig(:code)).to eq(url_offer_code.code)
          expect(subject.result&.dig(:valid)).to be(true)
        end
      end

      context "and it is invalid" do
        let(:url_code) { "INVALID" }

        it "returns error result" do
          expect(subject.result).to eq({ valid: false, error_code: :invalid_offer })
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
  end
end
