# frozen_string_literal: true

require "spec_helper"

describe CreatorMailer, ".marketing_x_reconnect" do
  let(:seller) { create(:user, twitter_handle: "edgar", twitter_oauth_token: "tok", twitter_oauth_secret: "sec") }
  let(:product) { create(:product, user: seller, name: "Beautiful widget") }
  let(:action) do
    create(:marketing_action, user: seller, link: product, copy: "New thing").tap do |a|
      a.approve!
      a.update!(error_code: Marketing::Action::X_WRITE_PERMISSION_MISSING)
    end
  end

  it "names the product and links to its Share tab, not Settings" do
    mail = described_class.marketing_x_reconnect(marketing_action_id: action.id)

    expect(mail.subject).to eq("Reconnect X to send your launch post")
    expect(mail.to).to eq([seller.form_email])
    expect(mail.body.encoded).to include("Beautiful widget")
    expect(mail.body.encoded).to include("/products/#{product.unique_permalink}/edit/share")
    expect(mail.body.encoded).not_to include("/settings/social_connections")
  end

  # X disables its Authorize button until this is ticked, so a seller who stops there stays broken.
  it "names the I trust this app step" do
    mail = described_class.marketing_x_reconnect(marketing_action_id: action.id)

    expect(mail.body.encoded).to include("I trust this app")
  end

  it "sends nothing once the seller has reconnected" do
    action.update!(error_code: nil)

    mail = described_class.marketing_x_reconnect(marketing_action_id: action.id)

    expect(mail.message).to be_a(ActionMailer::Base::NullMail)
  end

  it "sends nothing for an action that no longer exists" do
    mail = described_class.marketing_x_reconnect(marketing_action_id: -1)

    expect(mail.message).to be_a(ActionMailer::Base::NullMail)
  end
end
