# frozen_string_literal: true

require "test_helper"

class InviteTest < ActiveSupport::TestCase
  self.described_class = Invite



  context_ Invite do
  context_ "scopes" do
      before do
        @invite_sent            = create(:invite)
        @invite_signed_up       = create(:invite, invite_state: "signed_up")
      end

  context_ "#invitation_sent" do
  test "returns only the records with status invitation_sent" do
          expect(Invite.invitation_sent.to_a).to eq([@invite_sent])
        end
      end

  context_ "#signed_up" do
  test "returns only the records with status signed_up" do
          expect(Invite.signed_up.to_a).to eq([@invite_signed_up])
        end
      end
    end

  context_ "#mark_signed_up" do
  test "transitions the status correctly and sends an email in case of success" do
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

  context_ "#invite_state_text" do
  test "returns the correct text depending on the status of the invite" do
        invite = build(:invite)

        expect(invite.invite_state_text).to eq("Invitation sent")

        invite.invite_state = "signed_up"
        expect(invite.invite_state_text).to eq("Signed up!")
      end
    end
  end
end
