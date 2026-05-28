# frozen_string_literal: true

require "spec_helper"

describe RequireAccountEmail, type: :controller do
  controller(ApplicationController) do
    include RequireAccountEmail

    def index
      render plain: "spec"
    end
  end

  let(:message) { "Please add an email address to your account before continuing." }

  context "when the logged-in user has no email or unconfirmed email" do
    let(:user) { create(:user, provider: :twitter, email: nil, unconfirmed_email: nil) }

    before { sign_in user }

    it "redirects html requests to the settings page with a warning" do
      get :index
      expect(response).to redirect_to(settings_main_path)
      expect(flash[:warning]).to eq(message)
    end

    it "responds with a forbidden error for json requests" do
      get :index, format: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["error_message"]).to eq(message)
    end

    it "does not redirect requests to the settings page itself" do
      allow(controller).to receive(:controller_path).and_return("settings/main")
      get :index
      expect(response).to be_successful
    end

    it "does not redirect logout requests" do
      allow_any_instance_of(ActionDispatch::Request).to receive(:path).and_return(logout_path)
      get :index
      expect(response).to be_successful
    end

    it "does not redirect when the user is being impersonated" do
      allow(controller).to receive(:impersonating?).and_return(true)
      get :index
      expect(response).to be_successful
    end
  end

  context "when the logged-in user has an unconfirmed email pending" do
    let(:user) { create(:user, provider: :twitter, email: nil, unconfirmed_email: "pending@example.com") }

    before { sign_in user }

    it "does not redirect" do
      get :index
      expect(response).to be_successful
    end
  end

  context "when the logged-in user has an email" do
    let(:user) { create(:user, provider: :twitter, email: "seller@example.com") }

    before { sign_in user }

    it "does not redirect" do
      get :index
      expect(response).to be_successful
    end
  end

  context "when there is no logged-in user" do
    it "does not redirect" do
      get :index
      expect(response).to be_successful
    end
  end

  describe "inclusion" do
    it "gates seller dashboard surfaces" do
      expect(Sellers::BaseController.ancestors).to include(described_class)
      expect(LinksController.ancestors).to include(described_class)
    end

    it "is not applied to ApplicationController app-wide" do
      expect(ApplicationController.ancestors).not_to include(described_class)
    end
  end
end
