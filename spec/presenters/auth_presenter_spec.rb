# frozen_string_literal: true

require "spec_helper"

describe AuthPresenter do
  let(:params) { {} }
  let(:application) { nil }
  let(:presenter) { described_class.new(params:, application:) }

  before do
    allow(GlobalConfig).to receive(:get).with("RECAPTCHA_LOGIN_SITE_KEY").and_return("recaptcha_login_site_key")
    allow(GlobalConfig).to receive(:get).with("RECAPTCHA_SIGNUP_SITE_KEY").and_return("recaptcha_signup_site_key")
  end

  describe "#login_props" do
    context "with no params" do
      it "returns correct props" do
        expect(presenter.login_props).to eq(
          {
            email: nil,
            application_name: nil,
            recaptcha_site_key: GlobalConfig.get("RECAPTCHA_LOGIN_SITE_KEY"),
          }
        )
      end
    end

    context "with an oauth application" do
      let(:application) { create(:oauth_application, name: "Test App") }

      it "returns correct props" do
        expect(presenter.login_props).to eq(
          {
            email: nil,
            application_name: "Test App",
            recaptcha_site_key: GlobalConfig.get("RECAPTCHA_LOGIN_SITE_KEY"),
          }
        )
      end
    end
  end

  describe "#signup_props" do
    context "with no options and data" do
      before do
        $redis.del(RedisKey.total_made)
        $redis.del(RedisKey.number_of_creators)
      end

      it "returns correct props" do
        expect(presenter.signup_props).to eq(
          {
            email: nil,
            application_name: nil,
            referrer: nil,
            stats: {
              number_of_creators: 0,
              total_made: 0,
            },
            recaptcha_site_key: GlobalConfig.get("RECAPTCHA_SIGNUP_SITE_KEY"),
          }
        )
      end
    end

    context "with options passed" do
      let(:referrer) { create(:user, name: "Test Referrer") }
      let(:params) { { referrer: referrer.username } }
      let(:application) { create(:oauth_application, name: "Test App") }

      before do
        $redis.mset(
          RedisKey.total_made, 923_456_789,
          RedisKey.number_of_creators, 56_789
        )
      end

      it "returns correct props" do
        expect(presenter.signup_props).to eq(
          {
            email: nil,
            application_name: "Test App",
            referrer: {
              id: referrer.external_id,
              name: referrer.name,
            },
            stats: {
              number_of_creators: 56_789,
              total_made: 923_456_789,
            },
            recaptcha_site_key: GlobalConfig.get("RECAPTCHA_SIGNUP_SITE_KEY"),
          }
        )
      end
    end

    context "with a team invitation" do
      let(:team_invitation) { create(:team_invitation) }
      let(:params) do
        {
          next: Rails.application.routes.url_helpers.accept_settings_team_invitation_path(team_invitation.external_id, email: team_invitation.email)
        }
      end

      it "extracts the email to prefill" do
        expect(presenter.signup_props).to include(email: team_invitation.email)
      end
    end
  end
end
