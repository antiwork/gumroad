# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Settings::PasswordController, :vcr do
  it_behaves_like "inherits from Sellers::BaseController"

  let (:user) { create(:user) }

  before do
    sign_in user
  end

  it_behaves_like "authorize called for controller", Settings::Password::UserPolicy do
    let(:record) { user }
  end

  describe "GET show" do
    it "returns http success and assigns correct instance variables" do
      get :show

      expect(response).to be_successful
      expect(assigns(:react_component_props)).to eq(
        require_old_password: true, settings_pages: %w(main profile team payments password third_party_analytics advanced)
      )
    end
  end

  describe "PUT update" do
    context "when request payload is missing" do
      it "returns failure response" do
        with_real_pwned_password_check do
          put :update, xhr: true
        end
        expect(response.parsed_body["success"]).to be(false)
      end
    end

    context "when the specified new password is not compromised" do
      it "returns success response" do
        with_real_pwned_password_check do
          put :update, xhr: true, params: { user: { password: user.password, new_password: "#{user.password}-new" } }
        end
        expect(response.parsed_body["success"]).to be(true)
      end
    end

    context "when the specified new password is compromised" do
      it "returns failure response" do
        with_real_pwned_password_check do
          put :update, xhr: true, params: { user: { password: user.password, new_password: "password" } }
        end
        expect(response.parsed_body["success"]).to be(false)
      end
    end

    it "invalidates the user's active sessions and keeps the current session active" do
      travel_to(DateTime.current) do
        expect do
          put :update, xhr: true, params: { user: { password: user.password, new_password: "#{user.password}-new" } }
        end.to change { user.reload.last_active_sessions_invalidated_at }.from(nil).to(DateTime.current)

        expect(response.parsed_body["success"]).to be(true)
        expect(request.env["warden"].session["last_sign_in_at"]).to eq(DateTime.current.to_i)
      end
    end
  end

  describe "PUT update with social-provided account" do
    let (:user) { create(:user, provider: :facebook) }

    before do
      sign_in user
    end

    it "returns http success without checking for old password" do
      with_real_pwned_password_check do
        put :update, xhr: true, params: { user: { password: "", new_password: "#{user}-new" } }
      end
      expect(response.parsed_body["success"]).to be(true)
    end
  end
end
