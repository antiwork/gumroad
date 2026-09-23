# frozen_string_literal: true

require "spec_helper"

describe DeliverFilesReadyNotificationJob do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) { create(:purchase, link: product, seller: seller) }

  it "sends once when the stamp is done and the click's request is still set" do
    purchase.create_url_redirect!
    purchase.url_redirect.update!(is_done_pdf_stamping: true)
    PdfStampingService.request_buyer_notification!(purchase.id)

    expect do
      described_class.new.perform(purchase.id)
    end.to have_enqueued_mail(CustomerMailer, :files_ready_for_download).with(purchase.id)

    expect(PdfStampingService.buyer_notification_requested?(purchase.id)).to be(false)

    expect do
      described_class.new.perform(purchase.id)
    end.not_to have_enqueued_mail(CustomerMailer, :files_ready_for_download)
  end

  it "waits instead of emailing while the stamp is still missing" do
    purchase.create_url_redirect!
    create(:readable_document, link: product, pdf_stamp_enabled: true)
    PdfStampingService.request_buyer_notification!(purchase.id)

    expect do
      described_class.new.perform(purchase.id)
    end.not_to have_enqueued_mail(CustomerMailer, :files_ready_for_download)

    expect(described_class).to have_enqueued_sidekiq_job(purchase.id, 1)
    expect(PdfStampingService.buyer_notification_requested?(purchase.id)).to be(true)
  end

  it "does not email just because an older stamp already set the done bit" do
    redirect = purchase.create_url_redirect!
    redirect.update!(is_done_pdf_stamping: true)
    create(:readable_document, link: product, pdf_stamp_enabled: true)
    PdfStampingService.request_buyer_notification!(purchase.id)

    expect do
      described_class.new.perform(purchase.id)
    end.not_to have_enqueued_mail(CustomerMailer, :files_ready_for_download)

    expect(described_class).to have_enqueued_sidekiq_job(purchase.id, 1)
  end

  it "locks on the purchase, not the wait counter" do
    first = { "class" => described_class.name, "queue" => "critical", "args" => [purchase.id] }
    later = { "class" => described_class.name, "queue" => "critical", "args" => [purchase.id, 1] }
    first["lock_args"] = SidekiqUniqueJobs::LockArgs.call(first)
    later["lock_args"] = SidekiqUniqueJobs::LockArgs.call(later)

    expect(first["lock_args"]).to eq([purchase.id])
    expect(later["lock_args"]).to eq([purchase.id])
    expect(SidekiqUniqueJobs::LockDigest.call(first)).to eq(SidekiqUniqueJobs::LockDigest.call(later))
    expect(described_class.sidekiq_options["lock"]).to eq(:until_executing)
    expect(described_class.sidekiq_options["on_conflict"]).to eq(:log)
    expect(described_class.sidekiq_options["lock_ttl"]).to eq(described_class::LOCK_TTL.to_i)
    expect(described_class::LOCK_TTL).to be > described_class::WAIT
    expect(described_class::LOCK_TTL).to be < described_class::MAX_WAITS * described_class::WAIT
  end

  # Unique jobs are off in test. This is the click-amplification the lock exists to stop.
  context "with the unique lock enabled" do
    around do |example|
      SidekiqUniqueJobs.use_config(enabled: true) do
        Sidekiq::Testing.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
        example.run
      ensure
        Sidekiq::Testing.server_middleware { |chain| chain.remove SidekiqUniqueJobs::Middleware::Server }
      end
    end

    it "keeps one scheduled follower per purchase and still reschedules that chain" do
      purchase.create_url_redirect!
      create(:readable_document, link: product, pdf_stamp_enabled: true)
      PdfStampingService.request_buyer_notification!(purchase.id)
      other = create(:purchase, link: product, seller:)

      expect(described_class.perform_in(5.seconds, purchase.id)).to be_present
      expect(described_class.perform_in(5.seconds, purchase.id)).to be_nil
      expect(described_class.perform_in(5.seconds, other.id)).to be_present
      expect(described_class.jobs.size).to eq(2)

      described_class.perform_one

      expect(described_class).to have_enqueued_sidekiq_job(purchase.id, 1)
      expect(described_class.jobs.size).to eq(2)
      expect(described_class.perform_in(5.seconds, purchase.id)).to be_nil
    end

    it "drops a second download click while the first follower is still scheduled" do
      purchase.create_url_redirect!

      PdfStampingService.enqueue_buyer_download_stamp!(purchase.id)
      PdfStampingService.enqueue_buyer_download_stamp!(purchase.id)

      expect(described_class.jobs.size).to eq(1)
    end
  end
end
