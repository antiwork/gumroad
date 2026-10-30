# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::SessionsController, :vcr do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: @user)
    @params = {
      mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
      access_token: create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "mobile_api").token
    }
  end

  describe "POST create" do
    context "with valid credentials" do
      it "signs in the user and responds with HTTP success" do
        post :create, params: @params

        expect(controller.current_user).to eq(@user)
        expect(response).to be_successful
        expect(response.parsed_body["success"]).to eq(true)
        expect(response.parsed_body["user"]["email"]).to eq @user.email
      end
    end

    context "with a brand account token" do
      it "signs in the team member and selects the brand" do
        brand = create(:user)
        membership = create(:team_membership, user: @user, seller: brand, role: TeamMembership::ROLE_ADMIN)
        brand_token = MobileAccountToken.issue!(application: @app, scopes: "mobile_api", expires_in: nil, resource_owner: brand, team_membership: membership)

        post :create, params: @params.merge(access_token: brand_token.token)

        expect(response).to be_successful
        expect(controller.current_user).to eq(@user)
        expect(cookies.encrypted[:current_seller_id]).to eq(brand.id)
        expect(response.parsed_body["user"]["email"]).to eq(brand.email)
      end

      it "drops the brand selection when the member's own token signs in afterwards" do
        brand = create(:user)
        membership = create(:team_membership, user: @user, seller: brand, role: TeamMembership::ROLE_ADMIN)
        brand_token = MobileAccountToken.issue!(application: @app, scopes: "mobile_api", expires_in: nil, resource_owner: brand, team_membership: membership)
        post :create, params: @params.merge(access_token: brand_token.token)
        expect(cookies.encrypted[:current_seller_id]).to eq(brand.id)

        @controller = described_class.new
        post :create, params: @params

        expect(response).to be_successful
        expect(controller.current_user).to eq(@user)
        expect(cookies.encrypted[:current_seller_id]).to be_nil
        expect(controller.current_seller).to eq(@user)
      end

      it "does not pick up the impersonation of a staff brand owner" do
        brand = create(:admin_user)
        membership = create(:team_membership, user: @user, seller: brand, role: TeamMembership::ROLE_ADMIN)
        brand_token = MobileAccountToken.issue!(application: @app, scopes: "mobile_api", expires_in: nil, resource_owner: brand, team_membership: membership)
        $redis.set(RedisKey.impersonated_user(brand.id), create(:user).id)

        post :create, params: @params.merge(access_token: brand_token.token)

        expect(response).to be_successful
        expect(controller.current_user).to eq(@user)
        expect(cookies.encrypted[:current_seller_id]).to eq(brand.id)
        expect(response.parsed_body["user"]["email"]).to eq(brand.email)
      end

      it "signs in as the seller a staff member impersonates, as their own token does" do
        @user.update!(is_team_member: true)
        brand = create(:user)
        impersonated = create(:user)
        membership = create(:team_membership, user: @user, seller: brand, role: TeamMembership::ROLE_ADMIN)
        brand_token = MobileAccountToken.issue!(application: @app, scopes: "mobile_api", expires_in: nil, resource_owner: brand, team_membership: membership)
        $redis.set(RedisKey.impersonated_user(@user.id), impersonated.id)

        post :create, params: @params.merge(access_token: brand_token.token)

        expect(response).to be_successful
        expect(controller.current_user).to eq(impersonated)
        expect(response.parsed_body["user"]["email"]).to eq(impersonated.email)
      end
    end

    context "with invalid credentials" do
      it "responds with HTTP unauthorized" do
        post :create, params: @params.merge(access_token: "invalid")

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe "POST resend_confirmation_email" do
    context "when the account is unconfirmed" do
      before { @user.update_column(:confirmed_at, nil) }

      it "queues a confirmation email and reports it as sent" do
        expect { post :resend_confirmation_email, params: @params }
          .to change { ResendConfirmationEmailJob.jobs.size }.by(1)

        expect(ResendConfirmationEmailJob).to have_enqueued_sidekiq_job(@user.id)
        expect(response).to be_successful
        expect(response.parsed_body).to eq("success" => true, "status" => "sent")
      end

      it "refuses a second request inside the one-minute floor and says how long to wait" do
        @user.update_column(:confirmation_sent_at, 20.seconds.ago)

        expect { post :resend_confirmation_email, params: @params }
          .not_to change { ResendConfirmationEmailJob.jobs.size }

        expect(response).to have_http_status(:too_many_requests)
        expect(response.parsed_body).to include("success" => false, "status" => "throttled")
        expect(response.parsed_body["retry_after"]).to be_between(1, 40)
      end

      it "sends again once the floor has passed" do
        @user.update_column(:confirmation_sent_at, 2.minutes.ago)

        expect { post :resend_confirmation_email, params: @params }
          .to change { ResendConfirmationEmailJob.jobs.size }.by(1)

        expect(response.parsed_body).to include("success" => true, "status" => "sent")
      end

      it "does not need a signed-in web session" do
        post :resend_confirmation_email, params: @params

        expect(controller.current_user).to be_nil
        expect(response).to be_successful
      end
    end

    context "when the account is already confirmed" do
      it "sends nothing and reports already_confirmed so the app can retry" do
        expect { post :resend_confirmation_email, params: @params }
          .not_to change { ResendConfirmationEmailJob.jobs.size }

        expect(response).to be_successful
        expect(response.parsed_body).to eq("success" => true, "status" => "already_confirmed")
      end
    end

    context "when the account is confirming a changed email" do
      before { @user.update_columns(unconfirmed_email: "new@example.com", confirmation_sent_at: nil) }

      it "queues a confirmation email" do
        expect { post :resend_confirmation_email, params: @params }
          .to change { ResendConfirmationEmailJob.jobs.size }.by(1)

        expect(response.parsed_body).to include("status" => "sent")
      end
    end

    context "with invalid credentials" do
      it "responds with HTTP unauthorized and sends nothing" do
        @user.update_column(:confirmed_at, nil)

        expect { post :resend_confirmation_email, params: @params.merge(access_token: "invalid") }
          .not_to change { ResendConfirmationEmailJob.jobs.size }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "without the mobile token" do
      it "responds with HTTP unauthorized" do
        post :resend_confirmation_email, params: @params.except(:mobile_token)

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
