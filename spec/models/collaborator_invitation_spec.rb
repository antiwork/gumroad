# frozen_string_literal: true

require "spec_helper"

RSpec.describe CollaboratorInvitation, type: :model do
  describe "#accept!" do
    it "destroys the invitation" do
      invitation = create(:collaborator_invitation)

      expect { invitation.accept! }.to change(CollaboratorInvitation, :count).by(-1)
      expect { invitation.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "sends a notification email" do
      invitation = create(:collaborator_invitation)

      expect { invitation.accept! }
        .to have_enqueued_mail(AffiliateMailer, :collaborator_invitation_accepted).with { invitation.id }
    end
  end

  describe "#decline!" do
    let(:collaborator) { create(:collaborator) }
    let(:invitation) { create(:collaborator_invitation, collaborator:) }

    it "marks the collaborator as deleted" do
      expect { invitation.decline! }.to change { collaborator.reload.deleted? }.from(false).to(true)
    end

    it "disables the is_collab flag on associated products" do
      products = create_list(:product, 2, is_collab: true)
      create(:product_affiliate, product: products.first, affiliate: collaborator)
      create(:product_affiliate, product: products.second, affiliate: collaborator)

      expect { invitation.decline! }
        .to change { products.first.reload.is_collab }.from(true).to(false)
        .and change { products.second.reload.is_collab }.from(true).to(false)
    end

    it "sends an email to the collaborator" do
      expect { invitation.decline! }
        .to have_enqueued_mail(AffiliateMailer, :collaborator_invitation_declined).with { invitation.id }
    end
  end
end
