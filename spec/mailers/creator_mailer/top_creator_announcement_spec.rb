# frozen_string_literal: true

require "spec_helper"

describe CreatorMailer do
  describe "#top_creator_announcement" do
    it "doesn't send email if user does not exist" do
      mail = described_class.top_creator_announcement(user_id: 0)
      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    it "doesn't send email if user has been marked as deleted" do
      deleted_user = create(:user, :deleted)
      mail = described_class.top_creator_announcement(user_id: deleted_user.id)
      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    it "doesn't send email if user is suspended" do
      suspended_user = create(:tos_user)
      mail = described_class.top_creator_announcement(user_id: suspended_user.id)
      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    it "doesn't send email if user's email is invalid" do
      user = create(:user)
      user.update_column(:email, "notvalid")
      mail = described_class.top_creator_announcement(user_id: user.id)
      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    it "sets correct attributes" do
      user = create(:user)
      mail = described_class.top_creator_announcement(user_id: user.id)
      expect(mail.to).to eq([user.form_email])
      expect(mail.from).to eq(["gumroad@#{CREATOR_CONTACTING_CUSTOMERS_MAIL_DOMAIN}"])
      expect(mail.subject).to eq("You're a Top Creator!")
    end

    it "includes the badge image and announcement copy in the body" do
      user = create(:user)
      mail = described_class.top_creator_announcement(user_id: user.id)
      body = mail.body.encoded
      expect(body).to include("top_creator_badge")
      expect(body).to include("You just earned the Top Creator badge on Gumroad.")
      expect(body).to include("The Gumroad Team")
    end
  end
end
