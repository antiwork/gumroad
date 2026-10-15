# frozen_string_literal: true

require "spec_helper"

# Inertia's client head manager replaces this tag only after mount, so the server-rendered
# <style> is what the first frame paints with.
describe "Seller custom styles in the server-rendered head", type: :request do
  let(:seller) { create(:user, username: "customstylesseller") }
  let(:product) { create(:product, user: seller) }

  # Nokogiri keeps <style> content raw, so escaped quotes stay visible as &quot;.
  def custom_styles_css
    Nokogiri::HTML.parse(response.body).at_css('style[inertia="custom_styles"]')&.text
  end

  shared_examples "unescaped custom styles" do
    it "renders the compiled CSS without HTML-escaping its quotes" do
      get page_url

      expect(response).to be_successful
      expect(custom_styles_css).to include('--font-family: "ABC Favorit"')
      expect(custom_styles_css).to eq(seller.seller_profile.custom_styles)
    end
  end

  context "on a product page" do
    let(:page_url) { product.long_url }

    include_examples "unescaped custom styles"
  end

  context "on a profile page" do
    let(:page_url) { "#{seller.subdomain_with_protocol}/" }

    include_examples "unescaped custom styles"
  end
end
