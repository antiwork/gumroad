# frozen_string_literal: true

# Entry point for a seller the publish gate stopped. The offer already exists (the gate recorded it),
# so this only turns it into a hosted checkout session and hands the seller to Stripe.
class SellerPlanController < Sellers::BaseController
  def checkout
    authorize SellerPlanOffer

    offer = SellerPlanOffer.find_by(user_id: current_user.id)
    return redirect_to root_path, alert: "That plan offer is no longer available." if offer.nil?

    # A seller who already pays must not be able to open a second checkout and buy a second
    # subscription from a stale link.
    return redirect_to edit_link_url(offer.link.unique_permalink) if offer.active?

    redirect_to SellerPlan::Checkout.new(
      offer:,
      success_url: edit_link_url(offer.link.unique_permalink),
      cancel_url: edit_link_url(offer.link.unique_permalink)
    ).url, allow_other_host: true
  rescue StandardError => e
    ErrorNotifier.notify(e)
    redirect_to root_path, alert: "Something broke starting your plan. We're looking into it."
  end
end
