# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe Settings::PasswordController, :vcr, type: :controller, inertia: true do
  it_behaves_like "inherits from Sellers::BaseController"

  let (:user) { create(:user) }

  before do
    sign_in user
  end

  it_behaves_like "authorize called for controller", Settings::Password::UserPolicy do
    let(:record) { user }
  end

  describe "GET show" do
    it "returns http success and renders Inertia component" do
      get :show

      expect(response).to be_successful
      expect(inertia.component).to eq("Settings/Password/Show")
      expected_props = {
        require_old_password: user.provider.blank?,
      }
      # Compare only the expected props from inertia.props (ignore shared props)
      actual_props = inertia.props.slice(*expected_props.keys)
      expect(actual_props).to eq(expected_props)
    end
  end

  describe "PUT update" do
    context "when request payload is missing" do
      it "returns failure response" do
        with_real_pwned_password_check do
          put :update
        end
        expect(response).to redirect_to(settings_password_path)
        expect(response).to have_http_status :found
        expect(flash[:alert]).to eq("Incorrect password.")
      end
    end

    context "when the specified new password is not compromised" do
      it "returns success response" do
        with_real_pwned_password_check do
          put :update, params: { user: { password: user.password, new_password: "#{user.password}-new" } }
        end
        expect(response).to redirect_to(settings_password_path)
        expect(response).to have_http_status :see_other
        expect(flash[:notice]).to eq("You have successfully changed your password.")
      end
    end

    context "when the specified new password is compromised" do
      it "returns failure response" do
        with_real_pwned_password_check do
          put :update, params: { user: { password: user.password, new_password: "password" } }
        end
        expect(response).to redirect_to(settings_password_path)
        expect(response).to have_http_status :found
        expect(flash[:alert]).to be_present
      end
    end

    it "invalidates the user's active sessions and keeps the current session active" do
      travel_to(DateTime.current) do
        expect do
          put :update, params: { user: { password: user.password, new_password: "#{user.password}-new" } }
        end.to change { user.reload.last_active_sessions_invalidated_at }.from(nil).to(DateTime.current)

        expect(response).to redirect_to(settings_password_path)
        expect(response).to have_http_status :see_other
        expect(flash[:notice]).to eq("You have successfully changed your password.")
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
        put :update, params: { user: { password: "", new_password: "#{user}-new" } }
      end
      expect(response).to redirect_to(settings_password_path)
      expect(response).to have_http_status :see_other
      expect(flash[:notice]).to eq("You have successfully changed your password.")
    end
  end
end
