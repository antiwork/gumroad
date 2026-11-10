# frozen_string_literal: true

require "spec_helper"

describe Purchase, "sharing the provider's processing fee with collaborators" do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 6900) }
  let(:collaborator) { create(:collaborator, seller:, affiliate_user: create(:user), affiliate_basis_points: 5000) }
  let(:purchase) { build(:purchase, link: product, seller:, affiliate: collaborator, price_cents: 6900).tap { |p| p.fee_cents = 740 } }

  it "uses only Gumroad's fee when there is no separate provider fee" do
    expect(purchase.send(:determine_affiliate_fee_cents)).to eq(370)
    expect(purchase.send(:determine_affiliate_balance_cents)).to eq(3080)
  end

  it "adds the USD-converted provider fee when it is booked separately" do
    allow(purchase).to receive(:paypal_fee_usd_cents).and_return(348)

    expect(purchase.send(:determine_affiliate_fee_cents)).to eq(544)
    expect(purchase.send(:determine_affiliate_balance_cents)).to eq(2906)
  end

  it "recomputes the credit at success so a fee known only after capture is shared" do
    paid = purchase
    paid.assign_attributes(charge_processor_id: PaypalChargeProcessor.charge_processor_id, processor_fee_cents: 348, processor_fee_cents_currency: "USD")
    allow(paid).to receive(:increment_sellers_balance!)
    allow(paid).to receive(:mark_successful!)
    paid.update_balance_and_mark_successful!

    expect(paid.affiliate_credit_cents).to eq(2906)
  end

  context "on a PayPal sale" do
    let!(:gumroad_paypal_account) { create(:merchant_account_paypal, user: nil) }
    let(:product) { create(:product, user: seller, price_cents: 100_00) }
    let(:seller_paypal_account) { create(:merchant_account_paypal, user: seller) }

    def paypal_purchase(**attributes)
      create(:purchase, :with_custom_fee, link: product, affiliate: collaborator, fee_cents: 10_00,
                                          charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                          merchant_account: seller_paypal_account, **attributes)
    end

    it "shares only this purchase's part of a cart capture's fee" do
      first, second = 2.times.map { paypal_purchase(purchase_state: "in_progress") }
      charge = create(:charge, seller:, processor: PaypalChargeProcessor.charge_processor_id, merchant_account: seller_paypal_account,
                               amount_cents: 200_00, processor_fee_cents: nil)
      charge.purchases << first << second
      capture = { "id" => "capture-1", "status" => "COMPLETED",
                  "seller_receivable_breakdown" => { "paypal_fee" => { "currency_code" => "USD", "value" => "7.00" } } }
      paypal_charge = PaypalCharge.new(paypal_transaction_id: "capture-1", order_api_used: true,
                                       payment_details: { "purchase_units" => [{ "payments" => { "captures" => [capture] } }] })

      allow(first).to receive(:mark_successful!)
      first.save_charge_data(paypal_charge)
      first.update_balance_and_mark_successful!

      expect(first.affiliate_credit_cents).to eq(43_25)
      expect(first.affiliate_credit).to have_attributes(amount_cents: 43_25)
    end

    def paid_paypal_purchase(price_cents:, fee_cents:, processor_fee_cents:)
      purchase = paypal_purchase(link: create(:product, user: seller, price_cents:), price_cents:, fee_cents:,
                                 processor_fee_cents:, processor_fee_cents_currency: "USD")
      allow(purchase).to receive(:mark_successful!)
      purchase.update_balance_and_mark_successful!
      purchase.save!
      purchase
    end

    context "when the sale is refunded" do
      let!(:gumroad_merchant_account) { create(:merchant_account, user: nil) }

      before do
        allow(ChargeProcessor).to receive(:refund!) do |_processor_id, charge_id, **|
          PaypalOrderRefund.new(double(id: SecureRandom.hex, status: "COMPLETED"), charge_id)
        end
      end

      it "debits exactly the credit across partial refunds" do
        purchase = paid_paypal_purchase(price_cents: 69_00, fee_cents: 7_40, processor_fee_cents: 3_48)
        expect(purchase.affiliate_credit).to have_attributes(amount_cents: 29_06, fee_cents: 5_44)

        2.times { expect(purchase.refund_and_save!(seller.id, amount_cents: 34_50)).to be_truthy }

        expect(purchase.affiliate_partial_refunds.pluck(:amount_cents)).to eq([14_53, 14_53])
        expect(collaborator.affiliate_user.reload.unpaid_balance_cents).to eq(0)
      end

      it "debits nothing when the fee leaves no credit" do
        fully_refunded, partially_refunded, disputed = 3.times.map { paid_paypal_purchase(price_cents: 1_00, fee_cents: 60, processor_fee_cents: 60) }

        expect(fully_refunded.refund_and_save!(seller.id)).to be_truthy
        expect(partially_refunded.refund_and_save!(seller.id, amount_cents: 50)).to be_truthy
        disputed.decrement_balance_for_refund_or_chargeback!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -1_00),
                                                             dispute: create(:dispute_formalized, purchase: disputed))

        expect([fully_refunded, partially_refunded, disputed].map(&:affiliate_credit_cents)).to eq([0, 0, 0])
        expect(collaborator.affiliate_user.reload.unpaid_balance_cents).to eq(0)
        expect(AffiliatePartialRefund.count).to eq(0)
      end
    end
  end
end
