# frozen_string_literal: true

require "spec_helper"

describe SendPurchaseReceiptJob do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) { create(:purchase, link: product, seller: seller) }
  let(:mail_double) { double }

  before do
    allow(mail_double).to receive(:deliver_now)
  end

  context "when the purchase is for a product with stampable PDFs" do
    before do
      allow(PdfStampingService).to receive(:stamp_for_purchase!)
      allow_any_instance_of(Link).to receive(:has_stampable_pdfs?).and_return(true)
      purchase.create_url_redirect!
    end

    it "enqueues stamping and delivers the email without waiting for the stamp" do
      expect(CustomerMailer).to receive(:receipt).with(purchase.id).and_return(mail_double)
      described_class.new.perform(purchase.id)

      expect(StampPdfForPurchaseJob).to have_enqueued_sidekiq_job(purchase.id)
      expect(PdfStampingService).not_to have_received(:stamp_for_purchase!)
      expect(mail_double).to have_received(:deliver_now)
    end

    it "does not enqueue stamping once the redirect is already stamped" do
      purchase.url_redirect.update!(is_done_pdf_stamping: true)

      expect(CustomerMailer).to receive(:receipt).with(purchase.id).and_return(mail_double)
      described_class.new.perform(purchase.id)

      expect(StampPdfForPurchaseJob.jobs).to be_empty
      expect(mail_double).to have_received(:deliver_now)
    end

    it "delivers the receipt when stamping cannot be enqueued, then raises so the stamp is retried" do
      allow(StampPdfForPurchaseJob).to receive(:perform_async).and_raise(RuntimeError, "redis down")
      expect(CustomerMailer).to receive(:receipt).with(purchase.id).and_return(mail_double)

      expect { described_class.new.perform(purchase.id) }.to raise_error(RuntimeError, "redis down")
      expect(mail_double).to have_received(:deliver_now)
    end

    it "does not send a second receipt when the enqueue retry finds the first delivery recorded" do
      CustomerEmailInfo.build_for_purchase(
        purchase_id: purchase.id,
        email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD
      ).mark_sent!

      expect(CustomerMailer).not_to receive(:receipt)
      described_class.new.perform(purchase.id)
      expect(StampPdfForPurchaseJob).to have_enqueued_sidekiq_job(purchase.id)
    end

    it "sends again when the buyer asks for another receipt after the first was recorded" do
      CustomerEmailInfo.build_for_purchase(
        purchase_id: purchase.id,
        email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD
      ).mark_sent!
      expect(CustomerMailer).to receive(:receipt).with(purchase.id).and_return(mail_double)

      described_class.new.perform(purchase.id, true)

      expect(mail_double).to have_received(:deliver_now)
    end
  end

  context "when the purchase is for a product without stampable PDFs" do
    before do
      allow(PdfStampingService).to receive(:stamp_for_purchase!)
      allow_any_instance_of(Link).to receive(:has_stampable_pdfs?).and_return(false)
    end

    it "delivers the email and doesn't stamp PDFs" do
      expect(CustomerMailer).to receive(:receipt).with(purchase.id).and_return(mail_double)
      described_class.new.perform(purchase.id)

      expect(PdfStampingService).not_to have_received(:stamp_for_purchase!)
      expect(mail_double).to have_received(:deliver_now)
    end
  end

  context "when the purchase is a bundle product purchae" do
    before do
      allow_any_instance_of(Purchase).to receive(:is_bundle_product_purchase?).and_return(true)
    end

    it "doens't deliver email" do
      expect(CustomerMailer).not_to receive(:receipt).with(purchase.id)
      described_class.new.perform(purchase.id)
    end
  end

  describe ".lock_args" do
    it "distinguishes an explicit resend from an automatic run for the same purchase" do
      auto = { "class" => described_class.name, "queue" => "critical", "args" => [purchase.id] }
      resend = { "class" => described_class.name, "queue" => "critical", "args" => [purchase.id, true] }
      auto["lock_args"] = SidekiqUniqueJobs::LockArgs.call(auto)
      resend["lock_args"] = SidekiqUniqueJobs::LockArgs.call(resend)

      expect(auto["lock_args"]).to eq([purchase.id, false])
      expect(resend["lock_args"]).to eq([purchase.id, true])
      expect(SidekiqUniqueJobs::LockDigest.call(auto)).not_to eq(SidekiqUniqueJobs::LockDigest.call(resend))
      expect(described_class.sidekiq_options["lock"]).to eq(:until_executed)
    end

    it "collapses a missing second arg with false so two automatic enqueues share a digest" do
      first = { "class" => described_class.name, "queue" => "critical", "args" => [purchase.id] }
      repeat = { "class" => described_class.name, "queue" => "critical", "args" => [purchase.id, false] }
      first["lock_args"] = SidekiqUniqueJobs::LockArgs.call(first)
      repeat["lock_args"] = SidekiqUniqueJobs::LockArgs.call(repeat)

      expect(SidekiqUniqueJobs::LockDigest.call(first)).to eq(SidekiqUniqueJobs::LockDigest.call(repeat))
    end

    context "with the unique lock enabled" do
      around do |example|
        SidekiqUniqueJobs.use_config(enabled: true) do
          Sidekiq::Testing.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
          example.run
        ensure
          Sidekiq::Testing.server_middleware { |chain| chain.remove SidekiqUniqueJobs::Middleware::Server }
        end
      end

      it "keeps a resend enqueued while an automatic run is still queued for the same purchase" do
        expect(described_class.perform_async(purchase.id)).to be_present
        expect(described_class.perform_async(purchase.id, true)).to be_present
        expect(described_class.perform_async(purchase.id, true)).to be_nil
        expect(described_class.perform_async(purchase.id)).to be_nil

        expect(described_class.jobs.size).to eq(2)
      end
    end
  end
end
