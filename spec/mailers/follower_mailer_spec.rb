# frozen_string_literal: true

require "spec_helper"

describe FollowerMailer do
  describe "#confirm_follower" do
    let(:followee) { create(:user) }
    let(:unconfirmed_follower) { create(:follower, user: followee) }

    it "sends email to follower to confirm the follow" do
      mail = FollowerMailer.confirm_follower(followee.id, unconfirmed_follower.id)
      expect(mail.from).to eq ["noreply@staging.followers.gumroad.com"]
      expect(mail.to).to eq [unconfirmed_follower.email]
      expect(mail.subject).to eq("Please confirm your follow request to #{followee.name_or_username}.")
      expect(mail.body.encoded).to include "Please confirm your follow request to #{followee.name_or_username}."
      expect(mail.body.encoded).to include "Click the button below to confirm:"
      confirm_follow_route = Rails.application.routes.url_helpers.confirm_follow_url(unconfirmed_follower.external_id, host: "#{PROTOCOL}://#{DOMAIN}")
      expect(mail.body.encoded).to include confirm_follow_route
    end

    it "names the product when the signup came from a product waitlist" do
      product = create(:product, user: followee, name: "Espresso Machine")

      mail = FollowerMailer.confirm_follower(followee.id, unconfirmed_follower.id, product.id)

      expect(mail.body.encoded).to include "confirm you want to hear when Espresso Machine launches"
    end

    it "sets the correct SendGrid account" do
      stub_const(
        "EMAIL_CREDENTIALS",
        {
          MailerInfo::EMAIL_PROVIDER_SENDGRID => {
            followers: {
              address: SENDGRID_SMTP_ADDRESS,
              username: "apikey",
              password: "sendgrid-api-secret",
              domain: FOLLOWER_CONFIRMATION_MAIL_DOMAIN,
            }
          }
        }
      )

      mail = FollowerMailer.confirm_follower(followee.id, unconfirmed_follower.id)

      expect(mail.delivery_method.settings[:user_name]).to eq "apikey"
      expect(mail.delivery_method.settings[:password]).to eq "sendgrid-api-secret"
    end
  end
end
