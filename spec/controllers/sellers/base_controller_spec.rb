# frozen_string_literal: true

require "spec_helper"

describe Sellers::BaseController do
  describe "authenticate_user!" do
    controller(Sellers::BaseController) do
      def index
        skip_authorization
        head :no_content
      end
    end

    let(:path_placeholder) { "/settings" }

    before do
      @request.path = path_placeholder
    end

    context "when user is not logged in" do
      it "redirects to login page" do
        get :index

        expect(response).to redirect_to login_path(next: path_placeholder)
      end
    end

    context "when user is logged in" do
      let(:user) { create(:user) }

      before do
        sign_in user
      end

      it "renders the page" do
        get :index

        expect(response).to have_http_status(:no_content)
      end
    end
  end

  describe "verify_authorized" do
    controller(Sellers::BaseController) do
      def index
        head :no_content
      end
    end

    before do
      sign_in create(:user)
    end

    it "raises when not authorized" do
      expect do
        get :index
      end.to raise_error(Pundit::AuthorizationNotPerformedError)
    end
  end
end
