# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe SupportController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  it_behaves_like "authorize called for controller", SupportPolicy do
    let(:record) { :support }
  end

  describe "GET index" do
    it "returns http success and assigns props" do
      allow(controller).to receive(:helper_widget_host).and_return("https://help.example.test")
      allow(controller).to receive(:helper_session).and_return({ "session_id" => "abc123" })

      get :index

      expect(response).to be_successful
      expect(assigns[:props]).to eq(
        host: "https://help.example.test",
        session: { "session_id" => "abc123" }
      )
    end
  end
end
