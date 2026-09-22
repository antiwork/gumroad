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
end
