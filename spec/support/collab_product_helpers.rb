# frozen_string_literal: true

# Helper methods for testing collabs product functionality
module CollabProductHelper
  def setup_collab_purchases_for(user)
    collaborator = create(:collaborator, affiliate_user: user)
    collab_product = create(:product, :is_collab, user: collaborator.seller, name: "collab product", price_cents: 1600, collaborator:, collaborator_cut: 25_00)
    collab_purchases = create_list(:purchase_in_progress, 6, link: collab_product, seller: collab_product.user, affiliate: collaborator, created_at: 2.days.ago)
    collab_purchases.each_with_index do |purchase, i|
      purchase.process!
      purchase.update_balance_and_mark_successful!
      purchase.update!(tax_cents: 10 * i) # simulate products with taxes (should not show up for affiliates, who don't pay any taxes)
    end

    # chargeback collab purchase
    chargedback_purchase = collab_purchases.first
    allow_any_instance_of(Purchase).to receive(:fight_chargeback).and_return(true)
    event_flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, chargedback_purchase.total_transaction_cents)
    event = build(:charge_event_dispute_formalized, charge_id: chargedback_purchase.stripe_transaction_id, flow_of_funds: event_flow_of_funds)
    chargedback_purchase.handle_event_dispute_formalized!(event)
    chargedback_purchase.reload

    # refund collab purchase
    refunded_purchase = collab_purchases.second
    refunded_purchase.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, collab_product.price_cents), user.id)

    # partially refund collab purchase
    partially_refunded_purchase = collab_purchases.third
    partially_refunded_purchase.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, collab_product.price_cents / 2), user.id)

    gross = 1600 * 0.25 * 6 # 25% of 6 $16 purchases
    fees = (286 * 0.25).ceil * 3 + (286 * 0.25).ceil - (286 * 0.25 * 0.5).floor # 25% of fees for 3 non-chargedback / refunded purchases, plus 25% of fees for 1/2 refunded purchase
    refunds = 400 + (800 * 0.25) # 1 fully refunded purchase, plus 25% of the $8 refund on the other
    chargebacks = 1600 * 0.25 # 25% of 1 $16 purchase
    net = gross - fees - refunds - chargebacks

    { gross:, fees:, refunds:, chargebacks:, net: }
  end
end
