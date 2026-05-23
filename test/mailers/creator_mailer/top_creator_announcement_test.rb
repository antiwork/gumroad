# frozen_string_literal: true

require "test_helper"

class CreatorMailerTest < ActionMailer::TestCase
  self.described_class = CreatorMailer
  tests CreatorMailer



  context_ CreatorMailer do
  context_ "#top_creator_announcement" do
  test "doesn't send email if user does not exist" do
        mail = described_class.top_creator_announcement(user_id: 0)
        expect(mail.message).to be_a(ActionMailer::Base::NullMail)
      end

  test "doesn't send email if user has been marked as deleted" do
        deleted_user = create(:user, :deleted)
        mail = described_class.top_creator_announcement(user_id: deleted_user.id)
        expect(mail.message).to be_a(ActionMailer::Base::NullMail)
      end

  test "doesn't send email if user is suspended" do
        suspended_user = create(:tos_user)
        mail = described_class.top_creator_announcement(user_id: suspended_user.id)
        expect(mail.message).to be_a(ActionMailer::Base::NullMail)
      end

  test "doesn't send email if user's email is invalid" do
        user = create(:user)
        user.update_column(:email, "notvalid")
        mail = described_class.top_creator_announcement(user_id: user.id)
        expect(mail.message).to be_a(ActionMailer::Base::NullMail)
      end

  test "sets correct attributes" do
        user = create(:user)
        mail = described_class.top_creator_announcement(user_id: user.id)
        expect(mail.to).to eq([user.form_email])
        expect(mail.from).to eq(["gumroad@#{CREATOR_CONTACTING_CUSTOMERS_MAIL_DOMAIN}"])
        expect(mail.subject).to eq("You're a Top Creator!")
      end

  test "includes the badge image and announcement copy in the body" do
        user = create(:user)
        mail = described_class.top_creator_announcement(user_id: user.id)
        body = mail.body.encoded
        expect(body).to include("top_creator_badge")
        expect(body).to include("You just earned the Top Creator badge on Gumroad.")
      end
    end
  end
end
