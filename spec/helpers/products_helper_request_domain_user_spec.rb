# frozen_string_literal: true

require "spec_helper"

describe ProductsHelper do
  describe "#url_for_product_page request host lookup (gp#4844)" do
    let(:seller) { create(:user) }
    let(:products) { create_list(:product, 5, user: seller) }
    let(:request) { ActionDispatch::TestRequest.create("HTTP_HOST" => "#{seller.username}.#{ROOT_DOMAIN.split(":").first}") }

    it "resolves the owner of the request host once, not once per product link" do
      expect(Subdomain).to receive(:find_seller_by_hostname).once.and_call_original

      urls = products.map { |product| helper.url_for_product_page(product, request:) }

      expect(urls).to all(include(request.host))
    end

    it "keeps linking to the request host for the host's owner and to the canonical URL for other sellers" do
      other_product = create(:product)

      own = helper.url_for_product_page(products.first, request:)
      other = helper.url_for_product_page(other_product, request:)

      expect(own).to start_with("http://#{request.host}")
      expect(other).not_to include(request.host)
    end
  end
end
