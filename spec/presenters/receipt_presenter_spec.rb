# frozen_string_literal: true

require "spec_helper"
require "shared_examples/receipt_presenter_concern"

describe ReceiptPresenter do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) do
    create(
      :purchase,
      link: product,
      seller:,
      price_cents: 1_499,
      created_at: DateTime.parse("January 1, 2023")
    )
  end

  let(:presenter) { described_class.new(chargeable, for_email: true) }

  describe "For Purchase" do
    let(:chargeable) { purchase }

    describe "#charge_info" do
      it "returns a ChargeInfo object" do
        expect(presenter.charge_info).to be_a(ReceiptPresenter::ChargeInfo)
        expect(presenter.charge_info.send(:chargeable)).to eq(chargeable)
      end
    end

    describe "#payment_info" do
      it "returns a PaymentInfo object" do
        expect(presenter.payment_info).to be_a(ReceiptPresenter::PaymentInfo)
        expect(presenter.payment_info.send(:chargeable)).to eq(chargeable)
      end

      it "includes sales tax breakdown for Canada", :vcr do
        product = create(:product, price_cents: 200_00, native_type: "digital")

        purchase1 = create(:purchase_in_progress, link: product, was_product_recommended: true, recommended_by: "search", country: "Canada", state: "AB", ip_country: "Canada")
        purchase2 = create(:purchase_in_progress, link: product, was_product_recommended: true, recommended_by: "search", country: "Canada", state: "BC", ip_country: "Canada")
        purchase3 = create(:purchase_in_progress, link: product, was_product_recommended: true, recommended_by: "search", country: "Canada", state: "QC", ip_country: "Canada")

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end

        presenter = described_class.new(purchase1.reload, for_email: true)
        expect(presenter.payment_info.today_payment_attributes).to include({ label: "GST/HST", value: "$10" })
        expect(presenter.payment_info.today_payment_attributes).not_to include(hash_including(label: "PST"))
        expect(presenter.payment_info.today_payment_attributes).not_to include(hash_including(label: "QST"))
        expect(presenter.payment_info.today_payment_attributes).not_to include(hash_including(label: "Sales tax"))

        presenter = described_class.new(purchase2.reload, for_email: true)
        expect(presenter.payment_info.today_payment_attributes).to include({ label: "GST/HST", value: "$10" })
        expect(presenter.payment_info.today_payment_attributes).to include({ label: "PST", value: "$14" })
        expect(presenter.payment_info.today_payment_attributes).not_to include(hash_including(label: "QST"))
        expect(presenter.payment_info.today_payment_attributes).not_to include(hash_including(label: "Sales tax"))

        presenter = described_class.new(purchase3.reload, for_email: true)
        expect(presenter.payment_info.today_payment_attributes).to include({ label: "GST/HST", value: "$10" })
        expect(presenter.payment_info.today_payment_attributes).not_to include(hash_including(label: "PST"))
        expect(presenter.payment_info.today_payment_attributes).to include({ label: "QST", value: "$19.95" })
        expect(presenter.payment_info.today_payment_attributes).not_to include(hash_including(label: "Sales tax"))
      end
    end

    describe "#shipping_info" do
      it "returns a ShippingInfo object" do
        expect(presenter.shipping_info).to be_a(ReceiptPresenter::ShippingInfo)
        expect(presenter.shipping_info.send(:chargeable)).to eq(chargeable)
      end
    end

    describe "#items_infos" do
      it "returns an array" do
        expect(ReceiptPresenter::ItemInfo).to receive(:new).with(chargeable, presentment_currency: anything).and_call_original
        purchases = presenter.items_infos
        expect(purchases.size).to eq(1)
        expect(purchases.first).to be_a(ReceiptPresenter::ItemInfo)
      end
    end

    describe "#recommended_products_info" do
      it "returns a RecommendedProductsInfo object" do
        expect(presenter.recommended_products_info).to be_a(ReceiptPresenter::RecommendedProductsInfo)
        expect(presenter.recommended_products_info.send(:chargeable)).to eq(chargeable)
      end
    end

    describe "#mail_subject" do
      it "returns mail subject" do
        expect(presenter.mail_subject).to eq("You bought The Works of Edgar Gumstein!")
      end
    end

    describe "#footer_info" do
      it "returns a FooterInfo object" do
        expect(presenter.footer_info).to be_a(ReceiptPresenter::FooterInfo)
        expect(presenter.footer_info.send(:chargeable)).to eq(chargeable)
      end
    end
  end

  describe "For Charge" do
    let(:charge) { create(:charge, purchases: [purchase]) }
    let(:chargeable) { charge }

    describe "#charge_info" do
      it "returns a ChargeInfo object" do
        expect(presenter.charge_info).to be_a(ReceiptPresenter::ChargeInfo)
        expect(presenter.charge_info.send(:chargeable)).to eq(chargeable)
      end
    end

    describe "#payment_info" do
      it "returns a PaymentInfo object" do
        expect(presenter.payment_info).to be_a(ReceiptPresenter::PaymentInfo)
        expect(presenter.payment_info.send(:chargeable)).to eq(chargeable)
      end

      it "includes sales tax breakdown for Canada", :vcr do
        product = create(:product, price_cents: 200_00, native_type: "digital")

        purchase1 = create(:purchase_in_progress, link: product, was_product_recommended: true, recommended_by: "search", country: "Canada", state: "AB", ip_country: "Canada")
        charge1 = create(:charge)
        charge1.purchases << purchase1
        purchase2 = create(:purchase_in_progress, link: product, was_product_recommended: true, recommended_by: "search", country: "Canada", state: "BC", ip_country: "Canada")
        charge2 = create(:charge)
        charge2.purchases << purchase2
        purchase3 = create(:purchase_in_progress, link: product, was_product_recommended: true, recommended_by: "search", country: "Canada", state: "QC", ip_country: "Canada")
        charge3 = create(:charge)
        charge3.purchases << purchase3
        order = create(:order)
        order.charges << [charge1, charge2, charge3]
        order.purchases << [purchase1, purchase2, purchase3]

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end

        presenter = described_class.new(charge1.reload, for_email: true)
        expect(presenter.payment_info.today_payment_attributes).to include({ label: "GST/HST", value: "$10" })
        expect(presenter.payment_info.today_payment_attributes).not_to include(hash_including(label: "PST"))
        expect(presenter.payment_info.today_payment_attributes).not_to include(hash_including(label: "QST"))
        expect(presenter.payment_info.today_payment_attributes).not_to include(hash_including(label: "Sales tax"))

        presenter = described_class.new(charge2.reload, for_email: true)
        expect(presenter.payment_info.today_payment_attributes).to include({ label: "GST/HST", value: "$10" })
        expect(presenter.payment_info.today_payment_attributes).to include({ label: "PST", value: "$14" })
        expect(presenter.payment_info.today_payment_attributes).not_to include(hash_including(label: "QST"))
        expect(presenter.payment_info.today_payment_attributes).not_to include(hash_including(label: "Sales tax"))

        presenter = described_class.new(charge3.reload, for_email: true)
        expect(presenter.payment_info.today_payment_attributes).to include({ label: "GST/HST", value: "$10" })
        expect(presenter.payment_info.today_payment_attributes).not_to include(hash_including(label: "PST"))
        expect(presenter.payment_info.today_payment_attributes).to include({ label: "QST", value: "$19.95" })
        expect(presenter.payment_info.today_payment_attributes).not_to include(hash_including(label: "Sales tax"))
      end
    end

    describe "#shipping_info" do
      it "returns a ShippingInfo object" do
        expect(presenter.shipping_info).to be_a(ReceiptPresenter::ShippingInfo)
        expect(presenter.shipping_info.send(:chargeable)).to eq(chargeable)
      end
    end

    describe "#items_infos" do
      it "returns an array" do
        expect(ReceiptPresenter::ItemInfo).to receive(:new).with(purchase, presentment_currency: anything).and_call_original
        purchases = presenter.items_infos
        expect(purchases.size).to eq(1)
        expect(purchases.first).to be_a(ReceiptPresenter::ItemInfo)
      end
    end

    describe "#recommended_products_info" do
      it "returns a RecommendedProductsInfo object" do
        expect(presenter.recommended_products_info).to be_a(ReceiptPresenter::RecommendedProductsInfo)
        expect(presenter.recommended_products_info.send(:chargeable)).to eq(chargeable)
      end
    end

    describe "#mail_subject" do
      it "returns mail subject" do
        expect(presenter.mail_subject).to eq("You bought The Works of Edgar Gumstein!")
      end
    end

    describe "#footer_info" do
      it "returns a FooterInfo object" do
        expect(presenter.footer_info).to be_a(ReceiptPresenter::FooterInfo)
        expect(presenter.footer_info.send(:chargeable)).to eq(chargeable)
      end
    end

    describe "#giftee_manage_subscription" do
      it "returns a GifteeManageSubscription object" do
        expect(presenter.giftee_manage_subscription).to be_a(ReceiptPresenter::GifteeManageSubscription)
        expect(presenter.giftee_manage_subscription.send(:chargeable)).to eq(chargeable)
      end
    end

    describe "#presentment_currency" do
      let(:purchase_two) { create(:purchase, link: product, seller:, price_cents: 999) }
      let(:purchase_three) { create(:purchase, link: product, seller:, price_cents: 499) }
      let(:charge) { create(:charge, purchases: [purchase, purchase_two, purchase_three]) }

      # Whether a receipt can be stated in the buyer's currency depends on every purchase's
      # refunds, so asking the question is not free. It is answered once for the document
      # and handed to every section, including each item line — otherwise a three-item
      # receipt would read all three purchases' refunds once per section plus once per line.
      it "asks each purchase once, no matter how many sections and item lines are rendered" do
        purchases = [purchase, purchase_two, purchase_three]
        allow(charge).to receive(:successful_purchases).and_return(purchases)
        allow(charge).to receive(:unbundled_purchases).and_return(purchases)
        asked = Hash.new(0)
        purchases.each do |purchase_on_charge|
          allow(purchase_on_charge).to receive(:buyer_presentment_display?).and_wrap_original do |original|
            asked[purchase_on_charge.id] += 1
            original.call
          end
        end

        presenter.charge_info.formatted_total_transaction_amount
        presenter.payment_info.today_payment_attributes
        presenter.items_infos.each(&:props)

        expect(asked.values.sum).to be_positive
        expect(asked.values).to all(be <= 1)
      end
    end
  end
end
