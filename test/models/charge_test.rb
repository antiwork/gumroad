# frozen_string_literal: true

require "test_helper"

class ChargeTest < ActiveSupport::TestCase
  self.described_class = Charge
  self.rspec_metadata = { vcr: true }



  context_ Charge, :vcr do
    include StripeChargesHelper

  context_ "validations" do
  test "validates presence of required attributes" do
        charge = described_class.new

        expect(charge).to be_invalid
        expect(charge.errors.messages).to eq(
          order: ["must exist"],
          seller: ["must exist"],
        )
      end
    end

  context_ "#statement_description" do
  test "returns the name of the seller" do
        seller = create(:user, name: "US Seller")
        expect(create(:charge, seller:).statement_description).to eq("US Seller")
      end

  test "returns the username of the seller if name is not present" do
        seller = create(:user, username: "seller1")
        expect(create(:charge, seller:).statement_description).to eq("seller1")

        seller = create(:user, username: nil)
        expect(create(:charge, seller:).statement_description).to eq(seller.external_id)
      end
    end

  context_ "#shipping_cents" do
      let(:charge) { create(:charge) }

      before do
        charge.purchases << create(:purchase, shipping_cents: 499)
        charge.purchases << create(:purchase, shipping_cents: 1099)
      end

  test "sums shipping_cents from all purchases" do
        expect(charge.shipping_cents).to eq(1598)
      end
    end

  context_ "#has_invoice?" do
      let(:charge) { create(:charge) }

      before do
        charge.purchases << create(:free_purchase)
        charge.purchases << create(:free_trial_membership_purchase)
      end

  test "returns false when nothing is charged" do
        expect(charge.has_invoice?).to be(false)
      end

  context_ "when there is at least one purchase with a cost" do
        before do
          charge.purchases << create(:purchase)
        end

  test "returns true" do
          expect(charge.has_invoice?).to be(true)
        end
      end
    end

  context_ "#taxable?" do
      let(:purchase) { create(:purchase) }
      let(:charge) { create(:charge, purchases: [purchase]) }

  context_ "when the purchase is not taxable" do
  test "returns false" do
          expect(charge.taxable?).to be(false)
        end
      end

  context_ "when a purchase is taxable" do
        let(:taxable_purchase) { create(:purchase, was_purchase_taxable: true) }

        before do
          charge.purchases << taxable_purchase
        end

  test "returns true" do
          expect(charge.taxable?).to be(true)
        end
      end
    end

  context_ "#multi_item_charge?" do
  context_ "with a single purchase" do
        let(:charge) { create(:charge, purchases: [create(:purchase)]) }

  test "returns false" do
          expect(charge.multi_item_charge?).to be(false)
        end
      end

  context_ "with multiple purchases" do
        let(:charge) { create(:charge, purchases: [create(:purchase), create(:purchase)]) }

  test "returns true" do
          expect(charge.multi_item_charge?).to be(true)
        end
      end
    end

  context_ "#require_shipping?" do
      let(:purchase) { create(:purchase) }
      let(:charge) { create(:charge, purchases: [purchase]) }

  context_ "when the product is not physical" do
  test "returns false" do
          expect(charge.require_shipping?).to be(false)
        end
      end

  context_ "when a second purchase is for a physical product" do
        let(:physical_product) { create(:product, :is_physical) }
        let(:physical_purchase) { create(:physical_purchase, link: physical_product) }

        before do
          charge.purchases << physical_purchase
        end

  test "returns true" do
          expect(charge.require_shipping?).to be(true)
        end
      end
    end

  context_ "is_direct_to_australian_customer?" do
      let(:purchase) { create(:purchase) }
      let(:charge) { create(:charge, purchases: [purchase]) }

  context_ "when the product is not physical" do
  test "returns false" do
          expect(charge.is_direct_to_australian_customer?).to be(false)
        end
      end

  context_ "when a second purchase is for a physical product" do
        let(:physical_product) { create(:product, :is_physical) }
        let(:physical_purchase) { create(:physical_purchase, link: physical_product) }

        before do
          charge.purchases << physical_purchase
        end

  context_ "when the country is not Australia" do
  test "returns true" do
            expect(charge.is_direct_to_australian_customer?).to be(false)
          end
        end

  context_ "when country is Australia" do
          before do
            physical_purchase.update!(country: Compliance::Countries::AUS.common_name)
          end

  test "returns true" do
            expect(charge.is_direct_to_australian_customer?).to be(true)
          end
        end
      end
    end

  context_ "#taxed_by_gumroad?" do
      let(:purchase) { create(:purchase) }
      let(:charge) { create(:charge, purchases: [purchase]) }

  context_ "when the purchase doesn't have tax" do
  test "returns false" do
          expect(charge.taxed_by_gumroad?).to be(false)
        end
      end

  context_ "when the purchase has tax" do
        before do
          purchase.update!(gumroad_tax_cents: 100, was_purchase_taxable: true)
        end

  test "returns true" do
          expect(charge.taxed_by_gumroad?).to be(true)
        end
      end
    end

  context_ "#external_id_for_invoice" do
      let(:purchase) { create(:purchase) }
      let(:charge) { create(:charge, purchases: [purchase]) }

  test "returns the external_id of the purchase" do
        expect(charge.external_id_for_invoice).to eq(purchase.external_id)
      end
    end

  context_ "#external_id_numeric_for_invoice" do
      let(:purchase) { create(:purchase) }
      let(:charge) { create(:charge, purchases: [purchase]) }

  test "returns the external_id_numeric of the purchase" do
        expect(charge.external_id_numeric_for_invoice).to eq(purchase.external_id_numeric.to_s)
      end
    end

  context_ "#refund_gumroad_taxes!" do
      let(:user) { create(:user) }
      let(:note) { "sample note" }
      let(:business_vat_id) { "VAT12345" }
      let(:free_purchase) { create(:free_purchase) }
      let(:purchase_without_tax) { create(:purchase) }
      let(:purchase_with_tax) { create(:purchase, gumroad_tax_cents: 100, was_purchase_taxable: true) }
      let(:charge) { create(:charge, purchases: [free_purchase, purchase_without_tax, purchase_with_tax]) }

  test "calls refund_gumroad_taxes! on eligible purchases" do
        expect_any_instance_of(Purchase).to receive(:refund_gumroad_taxes!).once
        charge.refund_gumroad_taxes!(refunding_user_id: user.id, note: note, business_vat_id: business_vat_id)
      end
    end

  context_ "Purchase attributes" do
      let(:failed_purchase) { create(:failed_purchase) }
      let(:free_purchase) { create(:free_purchase, country: "France") }
      let(:paid_purchase) { create(:purchase, country: "France") }
      let(:taxable_purchase) { create(:purchase, was_purchase_taxable: true, country: "France") }
      let(:business_purchase) do
        purchase = create(:purchase, country: "France")
        purchase.update!(purchase_sales_tax_info: PurchaseSalesTaxInfo.new(business_vat_id: "VAT12345"))
        purchase
      end
      let(:charge) { create(:charge, purchases: [free_purchase, paid_purchase, taxable_purchase, business_purchase]) }

  test "returns the correct purchase attributes" do
        expect(charge.send(:purchase_as_chargeable)).to eq(free_purchase)
        expect(charge.full_name).to eq(free_purchase.full_name)
        expect(charge.purchaser).to eq(free_purchase.purchaser)

        expect(charge.send(:purchase_with_tax_as_chargeable)).to eq(taxable_purchase)
        expect(charge.tax_label_with_creator_tax_info).to eq(taxable_purchase.tax_label_with_creator_tax_info)
        expect(charge.purchase_sales_tax_info).to eq(business_purchase.purchase_sales_tax_info)

        expect(charge.send(:purchase_with_shipping_as_chargeable)).to eq(nil)
        expect(charge.send(:purchase_with_address_as_chargeable)).to eq(free_purchase)
        expect(charge.street_address).to eq(nil)
        expect(charge.city).to eq(nil)
        expect(charge.state).to eq(nil)
        expect(charge.zip_code).to eq(nil)
        expect(charge.country).to eq("France")
        expect(charge.state_or_from_ip_address).to eq(free_purchase.state_or_from_ip_address)
        expect(charge.country_or_ip_country).to eq(free_purchase.country_or_ip_country)
      end

  context_ "with physical purchase" do
        let(:physical_product) { create(:product, :is_physical) }
        let(:physical_purchase) { create(:physical_purchase, link: physical_product) }
        let(:charge) { create(:charge, purchases: [free_purchase, paid_purchase, taxable_purchase, physical_purchase]) }

  test "returns the correct purchase attributes" do
          expect(charge.send(:purchase_as_chargeable)).to eq(free_purchase)
          expect(charge.full_name).to eq(free_purchase.full_name)
          expect(charge.purchaser).to eq(free_purchase.purchaser)

          expect(charge.send(:purchase_with_tax_as_chargeable)).to eq(taxable_purchase)
          expect(charge.tax_label_with_creator_tax_info).to eq(taxable_purchase.tax_label_with_creator_tax_info)
          expect(charge.purchase_sales_tax_info).to eq(taxable_purchase.purchase_sales_tax_info)

          expect(charge.send(:purchase_with_shipping_as_chargeable)).to eq(physical_purchase)
          expect(charge.send(:purchase_with_address_as_chargeable)).to eq(physical_purchase)
          expect(charge.street_address).to eq(physical_purchase.street_address)
          expect(charge.city).to eq(physical_purchase.city)
          expect(charge.state).to eq(physical_purchase.state)
          expect(charge.zip_code).to eq(physical_purchase.zip_code)
          expect(charge.country).to eq(physical_purchase.country)
          expect(charge.state_or_from_ip_address).to eq(physical_purchase.state_or_from_ip_address)
          expect(charge.country_or_ip_country).to eq(physical_purchase.country_or_ip_country)
        end
      end
    end

  context_ "#upload_invoice_pdf" do
      let(:purchase) { create(:purchase) }
      let(:charge) { create(:charge, purchases: [purchase, create(:purchase)]) }

      before(:each) do
        @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/purchase-invoice-spec-#{SecureRandom.hex(18)}")

        s3_bucket_double = double
        allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).with(INVOICES_S3_BUCKET).and_return(s3_bucket_double)

        expect(s3_bucket_double).to receive_message_chain(:object).and_return(@s3_object)
      end

  test "writes the passed file to S3 and returns the S3 object" do
        file = File.open(Rails.root.join("spec", "support", "fixtures", "smaller.png"))

        result = charge.upload_invoice_pdf(file)
        expect(result).to be(@s3_object)
        expect(result.content_length).to eq(file.size)
      end
    end

  context_ "#purchase_as_chargeable" do
      let(:purchase) { create(:failed_purchase) }
      let(:test_purchase) { create(:test_purchase) }
      let(:paid_purchase) { create(:purchase) }
      let(:charge) { create(:charge, purchases: [purchase, test_purchase, paid_purchase]) }

  test "returns the first successful purchase" do
        expect(charge.send(:purchase_as_chargeable)).to eq(test_purchase)
      end
    end

  context_ "#purchase_with_shipping_as_chargeable" do
      let(:purchase) { create(:failed_purchase) }
      let(:free_purchase) { create(:free_purchase) }
      let(:charge) { create(:charge, purchases: [purchase, free_purchase]) }

  context_ "without a successful physical purchase" do
  test "returns nil" do
          expect(charge.send(:purchase_with_shipping_as_chargeable)).to be_nil
        end
      end

  context_ "with a successful physical purchase" do
        let(:physical_product) { create(:product, :is_physical) }
        let(:physical_purchase) { create(:physical_purchase, link: physical_product) }

        before do
          charge.purchases << physical_purchase
        end

  test "returns the physical purchase" do
          expect(charge.send(:purchase_with_shipping_as_chargeable)).to eq(physical_purchase)
        end
      end
    end

  context_ "#update_charge_details_from_processor!" do
      let(:charge) { create(:charge) }
      let(:stripe_charge) do
        stripe_payment_intent = create_stripe_payment_intent(
            StripePaymentMethodHelper.success_charge_disputed.to_stripejs_payment_method_id,
            currency: "usd",
            amount: 10_00
        )
        stripe_payment_intent.confirm
        stripe_charge = Stripe::Charge.retrieve(id: stripe_payment_intent.latest_charge, expand: %w[balance_transaction])

        StripeCharge.new(stripe_charge, stripe_charge.balance_transaction, nil, nil, nil)
      end

  test "saves the charge details from processor charge" do
        charge.update_charge_details_from_processor!(stripe_charge)

        expect(charge.reload.processor).to eq(StripeChargeProcessor.charge_processor_id)
        expect(charge.processor_transaction_id).to eq(stripe_charge.id)
        expect(charge.payment_method_fingerprint).to eq(stripe_charge.card_fingerprint)
        expect(charge.processor_fee_cents).to eq(stripe_charge.fee)
        expect(charge.processor_fee_currency).to eq(stripe_charge.fee_currency)
      end
    end

  context_ "#purchases_requiring_stamping" do
      let(:seller) { create(:named_seller) }
      let(:product_one) { create(:product, user: seller, name: "Product One") }
      let(:purchase_one) { create(:purchase, link: product_one, seller: seller) }
      let(:product_two) { create(:product, user: seller, name: "Product Two") }
      let(:purchase_two) { create(:purchase, link: product_two, seller: seller) }
      let(:charge) { create(:charge, purchases: [purchase_one, purchase_two], seller: seller) }
      let(:order) { charge.order }

      before do
        charge.order.purchases << purchase_one
        charge.order.purchases << purchase_two
      end

  context_ "without stampable PDFs" do
  test "returns an empty array" do
          expect(charge.purchases_requiring_stamping).to eq([])
        end
      end

  context_ "when a product has stampable PDF" do
        before do
          product_one.product_files << create(:readable_document, pdf_stamp_enabled: true)
        end

  context_ "without a URL redirect for purchase" do
  test "returns an empty array" do
            expect(charge.purchases_requiring_stamping).to eq([])
          end
        end

  context_ "with a URL redirect for purchase" do
          before do
            purchase_one.create_url_redirect!
          end

  test "returns the purchase" do
            expect(charge.purchases_requiring_stamping).to eq([purchase_one])
          end
        end
      end
    end

  context_ "#charged_using_stripe_connect_account?" do
      let(:charge) { create(:charge) }

  context_ "when the merchant account is using a stripe connect account" do
        before do
          allow_any_instance_of(MerchantAccount).to receive(:is_a_stripe_connect_account?).and_return(true)
        end

  test "returns true" do
          expect(charge.charged_using_stripe_connect_account?).to be(true)
        end
      end

  context_ "when the merchant account is not using a stripe connect account" do
        before do
          allow_any_instance_of(MerchantAccount).to receive(:is_a_stripe_connect_account?).and_return(false)
        end

  test "returns false" do
          expect(charge.charged_using_stripe_connect_account?).to be(false)
        end
      end
    end

  context_ "#buyer_blocked?" do
      let(:purchase) { create(:purchase) }
      let(:charge) { create(:charge, purchases: [purchase]) }

      before do
        allow_any_instance_of(Purchase).to receive(:buyer_blocked?).and_return("buyer_blocked!")
      end

  test "returns true" do
        expect(charge.buyer_blocked?).to eq("buyer_blocked!")
      end
    end

  context_ "#block_buyer!" do
      let(:admin) { create(:admin_user) }
      let(:purchase) { create(:purchase) }
      let(:charge) { create(:charge, purchases: [purchase]) }

  test "calls block_buyer! on the purchase" do
        expect_any_instance_of(Purchase).to receive(:block_buyer!).with(blocking_user_id: admin.id, comment_content: "Comment")
        charge.block_buyer!(blocking_user_id: admin.id, comment_content: "Comment")
      end
    end

  context_ "#refund_for_fraud_and_block_buyer!" do
      let(:admin) { create(:admin_user) }
      let(:purchase_one) { create(:purchase) }
      let(:purchase_two) { create(:purchase) }
      let(:charge) { create(:charge, purchases: [purchase_one, purchase_two]) }

  test "calls refund_for_fraud for each purchase and block_buyer! once" do
        refund_count = 0
        allow_any_instance_of(Purchase).to receive(:refund_for_fraud!) { refund_count += 1 }
        expect_any_instance_of(Purchase).to receive(:block_buyer!).once.with(blocking_user_id: admin.id, comment_content: nil)
        charge.refund_for_fraud_and_block_buyer!(admin.id)
        expect(refund_count).to eq(2)
      end

  test "does not block the buyer if a refund fails" do
        allow(purchase_one).to receive(:refund_for_fraud!).with(admin.id).and_return(false)
        expect(purchase_two).not_to receive(:refund_for_fraud!)
        expect_any_instance_of(Purchase).not_to receive(:block_buyer!)

        expect(charge.refund_for_fraud_and_block_buyer!(admin.id)).to be(false)
      end
    end

  context_ "#first_purchase_for_subscription" do
      let(:purchase) { create(:purchase) }
      let(:charge) { create(:charge, purchases: [purchase]) }

  context_ "without a subscription purchase" do
  test "returns nil" do
          expect(charge.first_purchase_for_subscription).to be_nil
        end
      end

  context_ "with a subscription purchase" do
        let(:subscription_purchase) { create(:membership_purchase) }

        before do
          charge.purchases << subscription_purchase
        end

  test "returns the subscription purchase" do
          expect(charge.first_purchase_for_subscription).to eq(subscription_purchase)
        end
      end
    end

  context_ "#receipt_email_info" do
      let(:purchase) { create(:purchase) }
      let(:charge) { create(:charge, purchases: [purchase, create(:purchase)]) }

  context_ "without email info records" do
  test "returns nil" do
          expect(charge.receipt_email_info).to be_nil
        end
      end

  context_ "with email info records" do
        let!(:email_info) do
          create(
            :customer_email_info,
            purchase_id: nil,
            email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
            email_info_charge_attributes: { charge_id: charge.id }
          )
        end

  test "returns email_info from charge" do
          expect(charge.receipt_email_info).to eq(email_info)
        end
      end
    end
  end
end
