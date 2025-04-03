# frozen_string_literal: true

class AffiliateMailerPreview < ActionMailer::Preview
  def direct_affiliate_invitation
    AffiliateMailer.direct_affiliate_invitation(DirectAffiliate.last&.id)
  end

  def notify_direct_affiliate_of_sale
    purchase = Purchase.where(affiliate_id: DirectAffiliate.pluck(:id)).last
    AffiliateMailer.notify_affiliate_of_sale(purchase&.id)
  end

  def notify_global_affiliate_of_sale
    purchase = Purchase.where(affiliate_id: GlobalAffiliate.pluck(:id)).last
    AffiliateMailer.notify_affiliate_of_sale(purchase&.id)
  end

  def notify_collaborator_of_sale
    purchase = Purchase.where(affiliate_id: Collaborator.pluck(:id)).last
    AffiliateMailer.notify_affiliate_of_sale(purchase&.id)
  end

  def notify_affiliate_of_original_subscription_sale
    AffiliateMailer.notify_affiliate_of_sale(Subscription.last&.original_purchase&.id)
  end

  def notify_affiliate_of_free_trial_sale
    AffiliateMailer.notify_affiliate_of_sale(Purchase.is_free_trial_purchase.where.not(affiliate_id: nil).last&.id)
  end

  def notify_direct_affiliate_of_updated_products
    AffiliateMailer.notify_direct_affiliate_of_updated_products(DirectAffiliate.last&.id)
  end

  def notify_direct_affiliate_of_new_product
    AffiliateMailer.notify_direct_affiliate_of_new_product(DirectAffiliate.last&.id, DirectAffiliate.last&.products&.last&.id)
  end

  def collaborator_creation
    AffiliateMailer.collaborator_creation(Collaborator.last&.id)
  end

  def collaborator_update
    AffiliateMailer.collaborator_update(Collaborator.last&.id)
  end

  def collaboration_ended_by_seller
    AffiliateMailer.collaboration_ended_by_seller(Collaborator.last&.id)
  end

  def collaborator_invited
    AffiliateMailer.collaborator_invited(Collaborator.last&.id)
  end

  def collaborator_invitation_accepted
    AffiliateMailer.collaborator_invitation_accepted(Collaborator.last&.id)
  end

  def collaborator_invitation_declined
    AffiliateMailer.collaborator_invitation_declined(Collaborator.last&.id)
  end

  def collaboration_ended_by_affiliate_user
    AffiliateMailer.collaboration_ended_by_affiliate_user(Collaborator.last&.id)
  end
end
