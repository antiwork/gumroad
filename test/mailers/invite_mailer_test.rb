# frozen_string_literal: true

require "test_helper"

class InviteMailerTest < ActionMailer::TestCase
  self.described_class = InviteMailer
  tests InviteMailer



  context_ InviteMailer do
  context_ "receiver_signed_up" do
      before do
        @user = create(:user)
        @invite = create(:invite, sender_id: @user.id)
        @invited_user = create(:user, email: @invite.receiver_email)
        @invited_user.mark_as_invited(@user.external_id)
      end

  test "has the correct 'to' and 'from' values" do
        mail = InviteMailer.receiver_signed_up(@invite.id)

        expect(mail.to).to eq [@user.form_email]
        expect(mail.from).to eq [ApplicationMailer::NOREPLY_EMAIL]
      end

  test "has the correct subject and title when the user has no name set" do
        mail = InviteMailer.receiver_signed_up(@invite.id)

        expect(mail.subject).to eq "A creator you invited has joined Gumroad."
        expect(mail.body.encoded).to include("A creator you invited has joined Gumroad.")
      end

  test "has the correct subject and title when the user has a name set" do
        @invited_user.name = "Sam Smith"
        @invited_user.save!

        mail = InviteMailer.receiver_signed_up(@invite.id)

        expect(mail.subject).to eq "#{@invited_user.name} has joined Gumroad, thanks to you."
        expect(mail.body.encoded).to include("#{@invited_user.name} has joined Gumroad, thanks to you.")
      end

  test "does not attempt to send an email if the 'to' email is empty" do
        @user.update_column(:email, nil)

        expect do
          InviteMailer.receiver_signed_up(@invite.id).deliver_now
        end.not_to change { ActionMailer::Base.deliveries.count }
      end

  test "has both username and email in body" do
        @invited_user.name = "Sam Smith"
        @invited_user.save!
        mail = InviteMailer.receiver_signed_up(@invite.id)
        expect(mail.body.encoded).to include("#{@invited_user.name} - #{@invited_user.email}")
      end
    end
  end
end
