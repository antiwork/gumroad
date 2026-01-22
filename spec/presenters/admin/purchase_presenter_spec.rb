# frozen_string_literal: true

require "spec_helper"

describe Admin::PurchasePresenter do
  describe "#props" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product, seller: seller) }
    let(:presenter) { described_class.new(purchase) }

    subject(:props) { presenter.props }

    describe "database attributes" do
      describe "fields" do
        it "returns the correct field values" do
          expect(props).to match(
            formatted_display_price: purchase.formatted_display_price,
            formatted_gumroad_tax_amount: nil,
            gumroad_responsible_for_tax: purchase.gumroad_responsible_for_tax?,
            product: { external_id: product.external_id, name: product.name, long_url: product.long_url },
            seller: { email: seller.email, support_email: seller.support_email },
            email: purchase.email,
            created_at: purchase.created_at,
            updated_at: purchase.updated_at,
            purchase_state: purchase.purchase_state.capitalize,
            external_id: purchase.external_id,
            external_id_numeric: purchase.external_id_numeric,
            quantity: purchase.quantity,
            successful: purchase.successful?,
            failed: purchase.failed?,
            can_contact: purchase.can_contact?,
            deleted_at: purchase.deleted_at,
            fee_cents: purchase.fee_cents,
            tip: nil,
            gumroad_tax_cents: purchase.gumroad_tax_cents,
            formatted_seller_tax_amount: nil,
            formatted_shipping_amount: nil,
            formatted_affiliate_credit_amount: nil,
            formatted_total_transaction_amount: purchase.formatted_total_transaction_amount,
            charge_processor_id: purchase.charge_processor_id&.capitalize,
            stripe_transaction: {
              id: purchase.stripe_transaction_id,
              search_url: ChargeProcessor.transaction_url_for_admin(purchase.charge_processor_id, purchase.stripe_transaction_id, purchase.charged_using_gumroad_merchant_account?),
            },
            merchant_account: {
              external_id: purchase.merchant_account.external_id,
              charge_processor_id: purchase.merchant_account.charge_processor_id.capitalize,
              holder_of_funds: purchase.merchant_account.holder_of_funds.capitalize,
            },
            refund_policy: nil,
            stripe_refunded: purchase.stripe_refunded?,
            stripe_partially_refunded: purchase.stripe_partially_refunded?,
            chargedback: purchase.chargedback?,
            chargeback_reversed: purchase.chargeback_reversed?,
            error_code: nil,
            last_chargebacked_purchase: nil,
            variants_list: purchase.variants_list,
            refunds: [],
            product_purchases: [],
            card: {
              type: purchase.card_type.upcase,
              visual: match(/\A\d+\z/),
              country: purchase.card_country,
              fingerprint_search_url: StripeChargeProcessor.fingerprint_search_url(purchase.stripe_fingerprint),
            },
            ip_address: purchase.ip_address,
            ip_country: purchase.ip_country,
            is_preorder_authorization: purchase.is_preorder_authorization,
            subscription: nil,
            email_info: nil,
            is_bundle_purchase: purchase.is_bundle_purchase,
            url_redirect: nil,
            offer_code: nil,
            street_address: purchase.street_address,
            full_name: purchase.full_name,
            city: purchase.city,
            state: purchase.state,
            zip_code: purchase.zip_code,
            country: purchase.country,
            is_gift_sender_purchase: purchase.is_gift_sender_purchase,
            custom_fields: purchase.custom_fields,
            license: nil,
            affiliate_email: nil,
            gift: nil,
            can_force_update: purchase.can_force_update?,
            stripe_fingerprint: purchase.stripe_fingerprint,
            is_free_trial_purchase: purchase.is_free_trial_purchase?,
            buyer_blocked: purchase.buyer_blocked?,
            is_deleted_by_buyer: purchase.is_deleted_by_buyer?,
            comments_count: purchase.comments.count,
          )
        end
      end

      context "when purchase has a tip" do
        let(:tip) { create(:tip, value_usd_cents: 500) }
        let(:purchase) { create(:purchase, link: product, seller: seller, tip: tip) }

        it "returns the tip amount in cents" do
          expect(props[:tip]).to eq(500)
        end
      end
    end
  end
end
