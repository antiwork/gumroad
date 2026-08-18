# frozen_string_literal: true

require "spec_helper"

describe SendChargeReceiptJob do
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
    allow(PdfStampingService).to receive(:stamp_for_purchase!)
    allow(CustomerMailer).to receive_message_chain(:receipt, :deliver_now)
  end

  it "locks by charge id only" do
    expect(described_class.lock_args([123])).to eq([123])
    expect(described_class.lock_args([123, 1])).to eq([123])
  end

  it "uses the same runtime lock across the default and critical queues" do
    without_attempt = { "class" => described_class.name, "queue" => "default", "args" => [charge.id] }
    with_attempt = { "class" => described_class.name, "queue" => "critical", "args" => [charge.id, 1] }
    without_attempt["lock_args"] = SidekiqUniqueJobs::LockArgs.call(without_attempt)
    with_attempt["lock_args"] = SidekiqUniqueJobs::LockArgs.call(with_attempt)

    expect(without_attempt["lock_args"]).to eq([charge.id])
    expect(with_attempt["lock_args"]).to eq([charge.id])
    expect(SidekiqUniqueJobs::LockDigest.call(without_attempt)).to eq(SidekiqUniqueJobs::LockDigest.call(with_attempt))
    expect(described_class.sidekiq_options["lock"]).to eq(:while_executing)
    expect(described_class.sidekiq_options["lock_timeout"]).to eq(2)
    expect(described_class.sidekiq_options["unique_across_queues"]).to be(true)
    expect(described_class.sidekiq_options["on_conflict"]).to eq({ "server" => :raise })
  end

  context "when a purchase is still in_progress (free+paid race, gp#2025)" do
    before do
      allow(SendChargeReceiptJob).to receive(:perform_in)
    end

    it "defers sending, re-enqueues with a delay, and does not mark the charge sent" do
      purchase_one.update!(purchase_state: "in_progress")

      described_class.new.perform(charge.id)

      expect(SendChargeReceiptJob).to have_received(:perform_in).with(10.seconds, charge.id, 1)
      expect(CustomerMailer).not_to have_received(:receipt)
      expect(charge.reload.receipt_sent?).to be(false)
    end

    it "deferring escalates through the retry delays until the budget is exhausted" do
      purchase_one.update!(purchase_state: "in_progress")

      described_class.new.perform(charge.id, 3)

      expect(SendChargeReceiptJob).to have_received(:perform_in).with(5.minutes, charge.id, 4)
      expect(CustomerMailer).not_to have_received(:receipt)
    end

    it "falls through and sends with what has settled once the retry budget is spent" do
      purchase_one.update!(purchase_state: "in_progress")

      described_class.new.perform(charge.id, described_class::RETRY_DELAYS.size)

      expect(SendChargeReceiptJob).not_to have_received(:perform_in)
      expect(CustomerMailer).to have_received(:receipt).with(nil, charge.id)
      expect(charge.reload.receipt_sent?).to be(true)
    end

    it "stops deferring once the slow purchase settles and sends split receipts" do
      purchase_one.update!(purchase_state: "in_progress")

      described_class.new.perform(charge.id)
      expect(CustomerMailer).not_to have_received(:receipt)

      purchase_one.update!(purchase_state: "successful")
      described_class.new.perform(charge.id)

      expect(CustomerMailer).to have_received(:receipt).with(purchase_one.id, single_purchase: true)
      expect(CustomerMailer).to have_received(:receipt).with(purchase_two.id, single_purchase: true)
      expect(charge.reload.receipt_sent?).to be(true)
    end
  end

  context "with all purchases ready" do
    context "for a single-item order" do
      let(:charge) { create(:charge, purchases: [purchase_one], seller: seller) }

      it "delivers one combined receipt and updates the charge without stamping" do
        described_class.new.perform(charge.id)

        expect(PdfStampingService).not_to have_received(:stamp_for_purchase!)
        expect(CustomerMailer).to have_received(:receipt).with(nil, charge.id)
        expect(charge.reload.receipt_sent?).to be(true)
      end

      it "does not resend a delivered combined receipt when auto-invoice enqueue fails" do
        delivery = double
        allow(delivery).to receive(:deliver_now) do
          email_info = CustomerEmailInfo.build_for_charge(
            charge_id: charge.id,
            email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
          )
          email_info.sent_at = Time.current
          email_info.save!
        end
        allow(CustomerMailer).to receive(:receipt).with(nil, charge.id).and_return(delivery)
        allow(AutoInvoiceEligibility).to receive(:eligible?).and_return(true)
        invoice_attempts = 0
        allow(SendAutoInvoiceEmailJob).to receive(:perform_async) do
          invoice_attempts += 1
          raise "invoice enqueue failed" if invoice_attempts == 1
        end

        expect { described_class.new.perform(charge.id) }.to raise_error("invoice enqueue failed")
        expect(charge.reload.receipt_email_infos.one?).to be(true)

        described_class.new.perform(charge.id)

        expect(CustomerMailer).to have_received(:receipt).with(nil, charge.id).once
        expect(invoice_attempts).to eq(2)
        expect(charge.reload.receipt_sent?).to be(true)
      end
    end

    context "for a two-item order" do
      it "delivers one receipt per purchase instead of a combined receipt" do
        described_class.new.perform(charge.id)

        expect(PdfStampingService).not_to have_received(:stamp_for_purchase!)
        expect(CustomerMailer).to have_received(:receipt).with(purchase_one.id, single_purchase: true)
        expect(CustomerMailer).to have_received(:receipt).with(purchase_two.id, single_purchase: true)
        expect(CustomerMailer).not_to have_received(:receipt).with(nil, charge.id)
        expect(charge.reload.receipt_sent?).to be(true)
      end

      it "skips a purchase whose receipt already went out on a retry" do
        create(:customer_email_info, purchase_id: purchase_one.id, email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD)

        described_class.new.perform(charge.id)

        expect(CustomerMailer).not_to have_received(:receipt).with(purchase_one.id, single_purchase: true)
        expect(CustomerMailer).to have_received(:receipt).with(purchase_two.id, single_purchase: true)
        expect(charge.reload.receipt_sent?).to be(true)
      end

      it "keeps a historical combined receipt when the charge is not marked sent" do
        create(
          :customer_email_info,
          purchase: nil,
          email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
          email_info_charge_attributes: { charge_id: charge.id },
        )

        described_class.new.perform(charge.id)

        expect(CustomerMailer).not_to have_received(:receipt)
        expect(charge.reload.receipt_sent?).to be(true)
      end

      it "keeps the first purchase's sent marker and does not resend it, even when the second delivery raises" do
        # Each successful delivery commits its marker outside the later charge transaction.
        call_count = 0
        allow(CustomerMailer).to receive(:receipt) do |purchase_id, **|
          call_count += 1
          raise "delivery failed" if call_count == 2
          create(:customer_email_info, purchase_id:, email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD)
          double(deliver_now: true)
        end

        expect { described_class.new.perform(charge.id) }.to raise_error("delivery failed")
        expect(charge.reload.receipt_sent?).to be(false)

        first_sent_purchase_id = CustomerEmailInfo.where(email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD).sole.purchase_id

        described_class.new.perform(charge.id)

        expect(CustomerMailer).to have_received(:receipt).with(first_sent_purchase_id, single_purchase: true).once
        expect(charge.reload.receipt_sent?).to be(true)
      end
    end

    context "for a bundle with two product rows" do
      let(:bundle) { create(:product, user: seller, is_bundle: true) }
      let(:bundle_purchase) { create(:purchase, link: bundle, seller:, is_bundle_purchase: true) }
      let(:charge) { create(:charge, purchases: [bundle_purchase], seller:) }

      before do
        create(:bundle_product_purchase, bundle_purchase:, product_purchase: purchase_one)
        create(:bundle_product_purchase, bundle_purchase:, product_purchase: purchase_two)
      end

      it "delivers the paid bundle receipt instead of splitting its access rows" do
        expect(charge.unbundled_purchases.size).to eq(2)
        expect(charge.successful_purchases).to contain_exactly(bundle_purchase)

        described_class.new.perform(charge.id)

        expect(CustomerMailer).to have_received(:receipt).with(nil, charge.id)
        expect(CustomerMailer).not_to have_received(:receipt).with(purchase_one.id, single_purchase: true)
        expect(CustomerMailer).not_to have_received(:receipt).with(purchase_two.id, single_purchase: true)
      end
    end
  end

  context "when the charge receipt has already been sent" do
    before do
      charge.update!(receipt_sent: true)
    end

    it "does nothing" do
      described_class.new.perform(charge.id)
      expect(PdfStampingService).not_to have_received(:stamp_for_purchase!)
      expect(CustomerMailer).not_to have_received(:receipt)
    end
  end

  context "when a purchase requires stamping" do
    before do
      allow_any_instance_of(Charge).to receive(:purchases_requiring_stamping).and_return([purchase_one])
    end

    it "stamps the PDFs and delivers a receipt per purchase" do
      described_class.new.perform(charge.id)

      expect(PdfStampingService).to have_received(:stamp_for_purchase!).exactly(:once)
      expect(PdfStampingService).to have_received(:stamp_for_purchase!).with(purchase_one)
      expect(CustomerMailer).to have_received(:receipt).with(purchase_one.id, single_purchase: true)
      expect(CustomerMailer).to have_received(:receipt).with(purchase_two.id, single_purchase: true)
      expect(charge.reload.receipt_sent?).to be(true)
    end

    context "when stamping fails" do
      before do
        allow(PdfStampingService).to receive(:stamp_for_purchase!).and_raise(PdfStampingService::Error)
      end

      it "doesn't deliver the email and raises an error" do
        expect(CustomerMailer).not_to receive(:receipt)
        expect { described_class.new.perform(charge.id) }.to raise_error(PdfStampingService::Error)
        expect(charge.reload.receipt_sent?).to be(false)
      end
    end
  end
end
