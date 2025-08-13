# frozen_string_literal: true

require "spec_helper"

RSpec.describe AffiliateInvitation, type: :model do
  describe "#accept!" do
    it "destroys the invitation when accepted" do
      invitation = create(:affiliate_invitation)

      expect { invitation.accept! }.to change(AffiliateInvitation, :count).by(-1)
      expect { invitation.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "sends a notification email when accepted" do
      invitation = create(:affiliate_invitation)

      expect { invitation.accept! }
        .to have_enqueued_mail(AffiliateMailer, :affiliate_invitation_accepted).with(invitation.affiliate_id)
    end
  end

  describe "#decline!" do
    let(:affiliate) { create(:direct_affiliate) }
    let(:invitation) { create(:affiliate_invitation, affiliate:) }

    it "marks the affiliate as deleted when declined" do
      expect { invitation.decline! }.to change { affiliate.reload.deleted? }.from(false).to(true)
    end

    it "sends a notification email when declined" do
      expect { invitation.decline! }
        .to have_enqueued_mail(AffiliateMailer, :affiliate_invitation_declined).with(invitation.affiliate_id)
    end
  end
end
