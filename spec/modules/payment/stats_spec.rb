# frozen_string_literal: true

require "spec_helper"

describe Payment::Stats, :vcr do
  describe "revenue_by_link" do
    before do
      @user = create(:singaporean_user_with_compliance_info, user_risk_state: "compliant", payment_address: "bob@cat.com")
      @json = JSON.parse(File.open("#{Rails.root}/spec/support/fixtures/stripe.json").read)
      @product_1 = create(:product, user: @user, price_cents: 1000)
      @product_2 = create(:product, user: @user, price_cents: 2000)
      @product_3 = create(:product, user: @user, price_cents: 3000)
      @affiliate = create(:direct_affiliate, seller: @user, affiliate_basis_points: 1500, apply_to_all_products: true)
      WebMock.stub_request(:post, PAYPAL_ENDPOINT)
             .to_return(body: "TIMESTAMP=2012%2d10%2d26T20%3a29%3a14Z&CORRELATIONID=c51c5e0cecbce&ACK=Success&VERSION=90%2e0&BUILD=4072860")
      allow_any_instance_of(Purchase).to receive(:create_dispute_evidence_if_needed!).and_return(nil)
      allow_any_instance_of(User).to receive(:unpaid_balance_cents).and_return(100_00)
    end

    it "calculates the revenue per link based on all purchases during the payout period, even with affiliate_credits" do
      travel_to(Date.today - 10) do
        p1 = create(:purchase, link: @product_1, price_cents: @product_1.price_cents, purchase_state: "in_progress")
        p1.update_balance_and_mark_successful!
        p2 = create(:purchase, link: @product_2, price_cents: @product_2.price_cents, purchase_state: "in_progress")
        p2.update_balance_and_mark_successful!
      end
      travel_to(Date.today - 9) do
        p3 = create(:purchase, link: @product_2, price_cents: @product_2.price_cents, purchase_state: "in_progress")
        p3.update_balance_and_mark_successful!
        @p4 = create(:purchase, link: @product_3, price_cents: @product_3.price_cents, affiliate: @affiliate, purchase_state: "in_progress")
        @p4.process!
        @p4.update_balance_and_mark_successful!
      end
      travel_to(Date.today - 3) do
        # This one shouldn't be included in the stats since it's only 3 days ago
        p5 = create(:purchase, link: @product_2, price_cents: @product_2.price_cents, purchase_state: "in_progress")
        p5.update_balance_and_mark_successful!
      end

      Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 7, PayoutProcessorType::PAYPAL, [@user], from_admin: true)
      revenue_by_link = Payment.last.revenue_by_link
      expect(revenue_by_link.count).to eq 3
      expect(revenue_by_link[@product_1.id]).to eq 791
      expect(revenue_by_link[@product_2.id]).to eq 3324
      expect(revenue_by_link[@product_3.id]).to eq 2154 # @p4.price_cents (3000) - @p4.fee_cents (467) - @p4.affiliate_credit_cents (379)
      expect(Payment.last.amount_cents + Payment.last.gumroad_fee_cents).to eq revenue_by_link.values.sum
      expect(Payment.last.gumroad_fee_cents).to eq (revenue_by_link.values.sum * PaypalPayoutProcessor::PAYPAL_PAYOUT_FEE_PERCENT / 100.0).ceil
    end

    describe "chargeback", :vcr do
      it "deducts the chargeback and refund fees from the link's revenue if we didn't waive our fee" do
        travel_to(Date.today - 10) do
          p1 = create(:purchase_in_progress, link: @product_1, chargeable: create(:chargeable))
          p1.process!
          p1.update_balance_and_mark_successful!
          p1.reload.refund_and_save!(@product_1.user.id)
          p1.is_refund_chargeback_fee_waived = false
          p1.save!

          p2 = create(:purchase_in_progress, link: @product_2, chargeable: create(:chargeable))
          p2.process!
          p2.update_balance_and_mark_successful!

          allow_any_instance_of(Purchase).to receive(:create_dispute_evidence_if_needed!).and_return(nil)
          Purchase.handle_charge_event(build(:charge_event_dispute_formalized, charge_reference: p2.external_id))

          p2.reload.is_refund_chargeback_fee_waived = false
          p2.save!

          p3 = create(:purchase_in_progress, link: @product_2, chargeable: create(:chargeable))
          p3.process!
          p3.update_balance_and_mark_successful!
        end

        Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 7, PayoutProcessorType::PAYPAL, [@user], from_admin: true)

        revenue_by_link = Payment.last.revenue_by_link
        expect(revenue_by_link.count).to eq(2)
        expect(revenue_by_link[@product_1.id]).to eq(-50)
        expect(revenue_by_link[@product_2.id]).to eq(1662) # 20_00 (price) - 2_88 (12.9% + 50c + 30c fee)
      end

      it "deducts the full purchase amount if the chargeback or refund happened in this period but the original purchase did not (fees waived)" do
        refunded_purchase = nil
        chargedback_purchase = nil
        travel_to(Date.today - 20) do
          refunded_purchase = create(:purchase_in_progress, link: @product_1, chargeable: create(:chargeable), affiliate: @affiliate)
          refunded_purchase.process!
          refunded_purchase.update_balance_and_mark_successful!

          chargedback_purchase = create(:purchase_in_progress, link: @product_2, chargeable: create(:chargeable))
          chargedback_purchase.process!
          chargedback_purchase.update_balance_and_mark_successful!

          p3 = create(:purchase, link: @product_2, price_cents: @product_2.price_cents, purchase_state: "in_progress")
          p3.update_balance_and_mark_successful!
        end

        Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 14, PayoutProcessorType::PAYPAL, [@user], from_admin: true)
        payment = Payment.last
        PaypalPayoutProcessor.handle_paypal_event("payment_date" => payment.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                                  "receiver_email_0" => payment.user.payment_address,
                                                  "masspay_txn_id_0" => "sometxn1",
                                                  "status_0" => "Completed",
                                                  "unique_id_0" => payment.id,
                                                  "mc_fee_0" => "2.99                            ")

        travel_to(Date.today - 10) do
          refunded_purchase.reload.refund_and_save!(refunded_purchase.seller.id)

          allow_any_instance_of(Purchase).to receive(:create_dispute_evidence_if_needed!).and_return(nil)
          Purchase.handle_charge_event(build(:charge_event_dispute_formalized, charge_reference: chargedback_purchase.external_id))

          # A few purchases so that the user's balance goes over $10 and is therefore payable
          p4 = create(:purchase, link: @product_2, price_cents: @product_2.price_cents, purchase_state: "in_progress")
          p4.update_balance_and_mark_successful!
          p5 = create(:purchase, link: @product_2, price_cents: @product_2.price_cents, purchase_state: "in_progress")
          p5.update_balance_and_mark_successful!
          p6 = create(:purchase, link: @product_2, price_cents: @product_2.price_cents, purchase_state: "in_progress")
          p6.update_balance_and_mark_successful!
        end

        Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [@user], from_admin: true)

        revenue_by_link = Payment.last.revenue_by_link
        expect(revenue_by_link.count).to eq(2)
        expect(revenue_by_link[@product_1.id]).to eq(-723) # - $10 (price cents) + $1.5 (affiliate cents) + $0.77 (returned fee) for the refunded purchase
        expect(revenue_by_link[@product_2.id]).to eq(3324) # 3 new sales, one chargeback: 3 * (20 - (20 * 0.129 + 50 + 30)) - (20 - 2.88)
        expect(Payment.last.amount_cents + Payment.last.gumroad_fee_cents).to eq revenue_by_link.values.sum
        expect(Payment.last.gumroad_fee_cents).to eq (revenue_by_link.values.sum * PaypalPayoutProcessor::PAYPAL_PAYOUT_FEE_PERCENT / 100.0).ceil
      end

      it "deducts the full purchase amount if the chargeback or refund happened in this period but the original purchase did not (fees not waived)" do
        refunded_purchase = nil
        chargedback_purchase = nil
        travel_to(Date.today - 20) do
          refunded_purchase = create(:purchase_in_progress, link: @product_1, chargeable: create(:chargeable), affiliate: @affiliate)
          refunded_purchase.process!
          refunded_purchase.update_balance_and_mark_successful!

          chargedback_purchase = create(:purchase_in_progress, link: @product_2, chargeable: create(:chargeable))
          chargedback_purchase.process!
          chargedback_purchase.update_balance_and_mark_successful!

          p3 = create(:purchase, link: @product_2, price_cents: @product_2.price_cents, purchase_state: "in_progress")
          p3.update_balance_and_mark_successful!
        end

        Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 14, PayoutProcessorType::PAYPAL, [@user], from_admin: true)
        payment = Payment.last
        PaypalPayoutProcessor.handle_paypal_event("payment_date" => payment.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                                  "receiver_email_0" => payment.user.payment_address,
                                                  "masspay_txn_id_0" => "sometxn1",
                                                  "status_0" => "Completed",
                                                  "unique_id_0" => payment.id,
                                                  "mc_fee_0" => "2.99                            ")

        travel_to(Date.today - 10) do
          refunded_purchase.reload.refund_and_save!(refunded_purchase.seller.id)
          refunded_purchase.is_refund_chargeback_fee_waived = false
          refunded_purchase.save!

          allow_any_instance_of(Purchase).to receive(:create_dispute_evidence_if_needed!).and_return(nil)
          Purchase.handle_charge_event(build(:charge_event_dispute_formalized, charge_reference: chargedback_purchase.external_id))
          chargedback_purchase.reload.is_refund_chargeback_fee_waived = false
          chargedback_purchase.save!

          # A few purchases so that the user's balance goes over $10 and is therefore payable
          p4 = create(:purchase, link: @product_2, price_cents: @product_2.price_cents, purchase_state: "in_progress")
          p4.update_balance_and_mark_successful!
          p5 = create(:purchase, link: @product_2, price_cents: @product_2.price_cents, purchase_state: "in_progress")
          p5.update_balance_and_mark_successful!
          p6 = create(:purchase, link: @product_2, price_cents: @product_2.price_cents, purchase_state: "in_progress")
          p6.update_balance_and_mark_successful!
        end

        Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [@user], from_admin: true)

        revenue_by_link = Payment.last.revenue_by_link
        expect(revenue_by_link.count).to eq 2
        expect(revenue_by_link[@product_1.id]).to eq(-723) # - $10 (purchase price) + $1.5 (affiliate commission) + $1.27 (returned fee)
        expect(revenue_by_link[@product_2.id]).to eq(3324) # 3 new sales, one chargeback: 3 * (20 - (20 * 0.129 + 50 + 30)) - (20 - 2.88)
      end
    end

    describe "partial refund" do
      it "deducts the refund amount if the refund happened in this period but the original purchase did not (fees not waived)" do
        refunded_purchase = nil
        travel_to(Date.today - 20) do
          refunded_purchase = create(:purchase_in_progress, link: @product_3, chargeable: create(:chargeable), affiliate: @affiliate)
          refunded_purchase.process!
          refunded_purchase.update_balance_and_mark_successful!
        end

        Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 14, PayoutProcessorType::PAYPAL, [@user], from_admin: true)
        payment = Payment.last
        PaypalPayoutProcessor.handle_paypal_event("payment_date" => payment.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                                  "receiver_email_0" => payment.user.payment_address,
                                                  "masspay_txn_id_0" => "sometxn1",
                                                  "status_0" => "Completed",
                                                  "unique_id_0" => payment.id,
                                                  "mc_fee_0" => "2.99                            ")

        travel_to(Date.today - 10) do
          refunded_purchase.reload.refund_and_save!(refunded_purchase.seller.id, amount_cents: 1500)
          refunded_purchase.is_refund_chargeback_fee_waived = false
          refunded_purchase.save!

          # A few purchases so that the user's balance goes over $10 and is therefore payable
          p4 = create(:purchase, link: @product_2, price_cents: @product_2.price_cents, purchase_state: "in_progress")
          p4.update_balance_and_mark_successful!
          p5 = create(:purchase, link: @product_2, price_cents: @product_2.price_cents, purchase_state: "in_progress")
          p5.update_balance_and_mark_successful!
          p6 = create(:purchase, link: @product_2, price_cents: @product_2.price_cents, purchase_state: "in_progress")
          p6.update_balance_and_mark_successful!
        end

        Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [@user], from_admin: true)

        revenue_by_link = Payment.last.revenue_by_link
        expect(revenue_by_link.count).to eq 2
        expect(revenue_by_link[@product_3.id]).to eq(-1123) # -$15 (refunded amount) + $2.25 (affiliate commission) + $1.77 (returned fee)
        expect(revenue_by_link[@product_2.id]).to eq(4986) # 3 new sales: 3 * (20 - (20 * 0.129 + 50 + 30))
      end

      it "deducts the refund amount - fee amount if the refund happened in this period but the original purchase did not (fees waived)" do
        refunded_purchase = nil
        travel_to(Date.today - 20) do
          refunded_purchase = create(:purchase_in_progress, link: @product_3, chargeable: create(:chargeable), affiliate: @affiliate)
          refunded_purchase.process!
          refunded_purchase.update_balance_and_mark_successful!
        end

        Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 14, PayoutProcessorType::PAYPAL, [@user], from_admin: true)
        payment = Payment.last
        PaypalPayoutProcessor.handle_paypal_event("payment_date" => payment.created_at.strftime("%T+%b+%d,+%Y+%Z"),
                                                  "receiver_email_0" => payment.user.payment_address,
                                                  "masspay_txn_id_0" => "sometxn1",
                                                  "status_0" => "Completed",
                                                  "unique_id_0" => payment.id,
                                                  "mc_fee_0" => "2.99                            ")

        travel_to(Date.today - 10) do
          refunded_purchase.reload.refund_and_save!(refunded_purchase.seller.id, amount_cents: 1500)

          # A few purchases so that the user's balance goes over $10 and is therefore payable
          p4 = create(:purchase, link: @product_2, price_cents: @product_2.price_cents, purchase_state: "in_progress")
          p4.update_balance_and_mark_successful!
          p5 = create(:purchase, link: @product_2, price_cents: @product_2.price_cents, purchase_state: "in_progress")
          p5.update_balance_and_mark_successful!
          p6 = create(:purchase, link: @product_2, price_cents: @product_2.price_cents, purchase_state: "in_progress")
          p6.update_balance_and_mark_successful!
        end

        Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [@user], from_admin: true)

        revenue_by_link = Payment.last.revenue_by_link
        expect(revenue_by_link.count).to eq 2
        expect(revenue_by_link[@product_3.id]).to eq(-1123) # -$15 (refunded amount) + $2.25 (affiliate commission) + $1.77 (returned fee)
        expect(revenue_by_link[@product_2.id]).to eq(4986) # # 3 new sales: 3 * (20 - (20 * 0.129 + 50 + 30))
      end

      it "deducts the refund amount - refunded fee amount - refunded affiliate amount if the partial refunds and the original purchase both happened in this period (fees waived)" do
        travel_to(Date.today - 2) do
          partially_refunded_purchase = create(:purchase_in_progress, link: @product_3, chargeable: create(:chargeable), affiliate: @affiliate)
          partially_refunded_purchase.process!
          partially_refunded_purchase.update_balance_and_mark_successful!
          partially_refunded_purchase.reload.refund_and_save!(partially_refunded_purchase.seller.id, amount_cents: 1000)
          partially_refunded_purchase.reload.refund_and_save!(partially_refunded_purchase.seller.id, amount_cents: 200)
        end

        Payouts.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [@user], from_admin: true)

        revenue_by_link = Payment.last.revenue_by_link
        expect(revenue_by_link.count).to eq 1
        expect(revenue_by_link[@product_3.id]).to eq(1255) # $30 (purchase price) - $12 (refunded amount) - $2.14 (fees) - $2.7 (affiliate commission on remaining $18)
      end
    end
  end
end
