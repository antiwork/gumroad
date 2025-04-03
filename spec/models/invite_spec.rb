# frozen_string_literal: true

require "spec_helper"

describe Invite do
  describe "scopes" do
    before do
      @invite_sent            = create(:invite)
      @invite_signed_up       = create(:invite, invite_state: "signed_up")
    end

    describe "#invitation_sent" do
      it "returns only the records with status invitation_sent" do
        expect(Invite.invitation_sent.to_a).to eq([@invite_sent])
      end
    end

    describe "#signed_up" do
      it "returns only the records with status signed_up" do
        expect(Invite.signed_up.to_a).to eq([@invite_signed_up])
      end
    end
  end

  describe "#mark_signed_up" do
    it "transitions the status correctly and sends an email in case of success" do
      user = create(:user)
      invite = create(:invite, sender_id: user.id)
      invited_user = create(:user, email: invite.receiver_email)
      invite.update!(receiver_id: invited_user.id)

      expect do
        expect do
          invite.mark_signed_up
        end.to change { invite.reload.signed_up? }.from(false).to(true)
      end.to have_enqueued_mail(InviteMailer, :receiver_signed_up).with(invite.id)
    end
  end

  describe "#invite_state_text" do
    it "returns the correct text depending on the status of the invite" do
      invite = build(:invite)

      expect(invite.invite_state_text).to eq("Invitation sent")

      invite.invite_state = "signed_up"
      expect(invite.invite_state_text).to eq("Signed up!")
    end
  end
end
