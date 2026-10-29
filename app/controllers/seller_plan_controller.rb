# frozen_string_literal: true

# Entry point for a seller the publish gate stopped. The offer already exists (the gate recorded it),
# so this only turns it into a hosted checkout session and hands the seller to Stripe.
class SellerPlanController < Sellers::BaseController
  def checkout
    authorize SellerPlanOffer

    offer = SellerPlanOffer.find_by(user_id: current_seller.id)
    return redirect_to root_path, alert: "That plan offer is no longer available." if offer.nil?

    edit_url = edit_link_url(offer.product.unique_permalink)
    # A seller who already pays must not be able to open a second checkout from a stale link.
    return redirect_to edit_url if offer.active?

    redirect_to SellerPlan::Checkout.new(offer:, success_url: edit_url, cancel_url: edit_url).url,
                allow_other_host: true
  rescue Stripe::APIConnectionError, Stripe::RateLimitError => e
    ErrorNotifier.notify(e)
    redirect_to edit_url, alert: "We couldn't reach our payment provider. Wait a minute, then publish again to retry."
  rescue StandardError => e
    ErrorNotifier.notify(e)
    redirect_to root_path, alert: "We couldn't start your plan checkout. Email support@gumroad.com and we'll sort it out."
  end
end
