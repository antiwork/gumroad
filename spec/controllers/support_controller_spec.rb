# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe SupportController, inertia: true do
  let(:seller) { create(:named_seller) }

  describe "GET index" do
    context "when user is signed in" do
      before { sign_in seller }

      it "returns http success and renders Inertia component with props" do
        allow(controller).to receive(:helper_widget_host).and_return("https://help.example.test")
        allow(controller).to receive(:helper_session).and_return({ "session_id" => "abc123" })

        get :index

        expect(response).to be_successful
        expect(inertia.component).to eq("Support/Index")
        expect(inertia.props[:host]).to eq("https://help.example.test")
        expect(inertia.props[:session]).to eq({ session_id: "abc123" })
      end
    end

    context "when user is not signed in" do
      it "redirects to help center" do
        get :index

        expect(response).to redirect_to(help_center_root_path)
      end
    end
  end
end
