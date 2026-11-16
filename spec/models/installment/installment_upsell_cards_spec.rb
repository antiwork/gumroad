# frozen_string_literal: true

require "spec_helper"

describe Installment, "#message_with_inline_syntax_highlighting_and_upsells" do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, name: "Calendar", price_cents: 700) }
  let(:category) { create(:variant_category, link: product) }
  let(:variant) { create(:variant, variant_category: category, name: "Bundle", price_difference_cents: 500) }
  let(:upsell) { create(:upsell, seller:, product:, variant:, is_content_upsell: true) }
  let(:installment) { create(:installment, seller:, message: %(<upsell-card id="#{upsell.external_id}"></upsell-card>)) }

  subject(:html) { Nokogiri::HTML.fragment(installment.message_with_inline_syntax_highlighting_and_upsells) }

  it "shows the selected version's name and price and links to it" do
    expect(html.at_css("h4").text).to eq("Calendar (Bundle)")
    expect(html.at_css(".section:last-child .section:last-child").text.squish).to eq("$12")
    expect(html.at_css("h4 a")["href"]).to include("option=#{CGI.escape(variant.external_id)}")
  end

  it "applies the offer code to the version's price" do
    upsell.update!(offer_code: create(:offer_code, user: seller, products: [product], amount_cents: 200))
    text = html.at_css(".section:last-child .section:last-child").text.squish
    expect(text).to eq("$12 $10")
  end

  it "keeps the base name, price and link when no version is selected" do
    upsell.update!(variant: nil)
    expect(html.at_css("h4").text).to eq("Calendar")
    expect(html.text).to include("$7")
    expect(html.at_css("h4 a")["href"]).not_to include("option=")
  end
end
