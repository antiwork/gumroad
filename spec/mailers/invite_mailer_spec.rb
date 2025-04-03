# frozen_string_literal: true

require "spec_helper"

describe InviteMailer do
  describe "receiver_signed_up" do
    before do
      @user = create(:user)
      @invite = create(:invite, sender_id: @user.id)
      @invited_user = create(:user, email: @invite.receiver_email)
      @invited_user.mark_as_invited(@user.external_id)
    end

    it "has the correct 'to' and 'from' values" do
      mail = InviteMailer.receiver_signed_up(@invite.id)

      expect(mail.to).to eq [@user.form_email]
      expect(mail.from).to eq [ApplicationMailer::NOREPLY_EMAIL]
    end

    it "has the correct subject and title when the user has no name set" do
      mail = InviteMailer.receiver_signed_up(@invite.id)

      expect(mail.subject).to eq "A creator you invited has joined Gumroad."
      expect(mail.body.encoded).to include("A creator you invited has joined Gumroad.")
    end

    it "has the correct subject and title when the user has a name set" do
      @invited_user.name = "Sam Smith"
      @invited_user.save!

      mail = InviteMailer.receiver_signed_up(@invite.id)

      expect(mail.subject).to eq "#{@invited_user.name} has joined Gumroad, thanks to you."
      expect(mail.body.encoded).to include("#{@invited_user.name} has joined Gumroad, thanks to you.")
    end

    it "does not attempt to send an email if the 'to' email is empty" do
      @user.update_column(:email, nil)

      expect do
        InviteMailer.receiver_signed_up(@invite.id).deliver_now
      end.to_not change { ActionMailer::Base.deliveries.count }
    end

    it "has both username and email in body" do
      @invited_user.name = "Sam Smith"
      @invited_user.save!
      mail = InviteMailer.receiver_signed_up(@invite.id)
      expect(mail.body.encoded).to include("#{@invited_user.name} - #{@invited_user.email}")
    end
  end
end
