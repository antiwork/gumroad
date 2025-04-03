# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe TestPingsController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:user, notification_endpoint: "http://notification.com") }
  let(:product) { create(:product, user: seller) }

  include_context "with user signed in as admin for seller"

  it_behaves_like "authorize called for action", :post, :create do
    let(:record) { seller }
    let(:policy_klass) { Settings::Advanced::UserPolicy }
    let(:policy_method) { :test_ping? }
  end

  describe "POST create" do
    it "posts a test ping containing latest sale details to the specified endpoint" do
      create(:purchase, link: product, created_at: 2.days.ago)
      create(:purchase, link: product)
      last_purchase = create(:purchase, link: product, created_at: 2.hours.from_now)
      ping_url = last_purchase.seller.notification_endpoint
      ping_params = last_purchase.payload_for_ping_notification
      http_double = double
      expect(HTTParty).to receive(:post).with(ping_url,
                                              timeout: 5,
                                              body: ping_params.merge(test: true).deep_stringify_keys,
                                              headers: { "Content-Type" => last_purchase.seller.notification_content_type })
                                        .and_return(http_double)
      post :create, params: { url: ping_url }
      expect(response.body).to include "Your last sale's data has been sent to your Ping URL."
    end

    it "fails and displays error if no sale present for the user" do
      expect(HTTParty).not_to receive(:post)
      post :create, params: { url: product.user.notification_endpoint }
      expect(response.body).to include "There are no sales on your account to test with. Please make a test purchase and try again."
    end

    it "fails and displays error if invalid URL is passed" do
      expect(HTTParty).not_to receive(:post)
      post :create, params: { url: "not_a_url" }
      expect(response.body).to include "That URL seems to be invalid."
    end
  end
end
