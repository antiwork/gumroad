# frozen_string_literal: true

require "spec_helper"

describe Installment do
  describe "#message_with_inline_syntax_highlighting_and_upsells" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller, name: "Annual calendar", price_cents: 700) }
    let(:variant) { create(:variant, variant_category: create(:variant_category, link: product), name: "Calendar bundle", price_difference_cents: 500) }
    let(:offer_code) { nil }
    let(:upsell) { create(:upsell, seller:, product:, variant:, offer_code:, is_content_upsell: true) }
    let(:installment) { create(:audience_installment, seller:, message: %(<upsell-card id="#{upsell.external_id}"></upsell-card>)) }
    let(:card) { Nokogiri::HTML.fragment(installment.message_with_inline_syntax_highlighting_and_upsells) }

    it "renders the selected version's name, price, and checkout option" do
      expect(card.at_css("h4").text).to eq("Annual calendar (Calendar bundle)")
      expect(card.text.squish).to eq("Annual calendar (Calendar bundle) $12")
      query = Rack::Utils.parse_query(URI(card.at_css("h4 a")["href"]).query)
      expect(query).to include("accepted_offer_id" => upsell.external_id, "product" => product.unique_permalink, "option" => variant.external_id)
    end

    context "with a fixed discount" do
      let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_cents: 200) }

      it "applies the discount to the selected version's price" do
        expect(card.at_css("s").text).to eq("$12")
        expect(card.text.squish).to eq("Annual calendar (Calendar bundle) $12 $10")
      end
    end

    context "with a percentage discount" do
      let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_cents: nil, amount_percentage: 25) }

      it "calculates the discount from the selected version's price" do
        expect(card.at_css("s").text).to eq("$12")
        expect(card.text.squish).to eq("Annual calendar (Calendar bundle) $12 $9")
      end
    end

    context "without a selected version" do
      let(:variant) { nil }

      it "keeps the base product name, price, and checkout link" do
        expect(card.text.squish).to eq("Annual calendar $7")
        query = Rack::Utils.parse_query(URI(card.at_css("h4 a")["href"]).query)
        expect(query).to include("accepted_offer_id" => upsell.external_id, "product" => product.unique_permalink)
        expect(query).not_to have_key("option")
      end
    end
  end
end
