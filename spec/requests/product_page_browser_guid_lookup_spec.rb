# frozen_string_literal: true

require "spec_helper"

describe "product page purchase lookup by browser guid", type: :request do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  def browser_guid_purchase_queries(&block)
    queries = []
    callback = ->(_name, _started, _finished, _id, payload) { queries << payload[:sql] }
    ::ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    queries.grep(/FROM `purchases`.*`browser_guid`/i)
  end

  it "skips the lookup when the request carried no _gumroad_guid cookie" do
    queries = browser_guid_purchase_queries { get "http://#{seller.subdomain}/l/#{product.unique_permalink}" }

    expect(response).to have_http_status(:ok)
    expect(response.cookies["_gumroad_guid"]).to be_present
    expect(queries).to be_empty
  end

  it "still finds the purchase for a returning browser" do
    purchase = create(:purchase, link: product, browser_guid: "returning-guid")

    queries = browser_guid_purchase_queries do
      get "http://#{seller.subdomain}/l/#{product.unique_permalink}", headers: { "Cookie" => "_gumroad_guid=#{purchase.browser_guid}" }
    end

    expect(response).to have_http_status(:ok)
    expect(queries).not_to be_empty
    expect(response.body).to include(purchase.external_id)
  end
end
