# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"

describe Api::Internal::UtmLinks::UniquePermalinksController do
  let(:seller) { create(:user) }

  before do
    Feature.activate_user(:utm_links, seller)
  end

  include_context "with user signed in as admin for seller"

  describe "GET show" do
    it_behaves_like "authentication required for action", :get, :show

    it_behaves_like "authorize called for action", :get, :show do
      let(:record) { UtmLink }
      let(:policy_method) { :new? }
    end

    it "returns a new unique permalink" do
      allow(SecureRandom).to receive(:alphanumeric).and_return("unique01", "unique02")

      create(:utm_link, seller:, permalink: "unique01")

      get :show

      expect(response).to be_successful
      expect(response.parsed_body).to eq("permalink" => "unique02")
    end
  end
end
