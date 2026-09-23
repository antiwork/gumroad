# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe PdfStampingService, "concurrent files-ready requests" do
  self.use_transactional_tests = false

  let!(:seller) { create(:named_seller) }
  let!(:product) { create(:product, user: seller) }
  let!(:purchase) { create(:purchase, link: product, seller:) }
  let!(:url_redirect) { purchase.create_url_redirect! }

  after do
    UrlRedirect.where(id: url_redirect.id).delete_all
    Event.where(purchase_id: purchase.id).delete_all
    Purchase.where(id: purchase.id).delete_all
    Price.where(link_id: product.id).delete_all
    product.destroy!
    Affiliate.where(affiliate_user_id: seller.id).delete_all
    RefundPolicy.where(seller_id: seller.id).delete_all
    seller.destroy!
  end

  it "keeps a later click pending while a sender holds the redirect until mail enqueue" do
    described_class.request_buyer_notification!(purchase.id)
    sending = Queue.new
    release = Queue.new
    click_started = Queue.new
    click_done = Queue.new
    mail = double(deliver_later: true)
    deliveries = 0
    allow(CustomerMailer).to receive(:files_ready_for_download).and_return(mail)
    allow(mail).to receive(:deliver_later) do
      deliveries += 1
      if deliveries == 1
        sending << true
        release.pop
      end
    end

    sender = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.deliver_files_ready_notification!(purchase.id)
      end
    end
    Timeout.timeout(10) { sending.pop }
    click = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        click_started << true
        described_class.request_buyer_notification!(purchase.id)
        click_done << true
      end
    end
    Timeout.timeout(10) { click_started.pop }
    expect(click.join(0.2)).to be_nil
    expect(click_done).to be_empty
    release << true
    Timeout.timeout(10) { sender.value; click.value }
    expect(described_class.buyer_notification_requested?(purchase.id)).to be(true)
    expect(described_class.deliver_files_ready_notification!(purchase.id)).to be(true)
    expect(described_class.buyer_notification_requested?(purchase.id)).to be(false)
  ensure
    release&.push(true)
    [sender, click].compact.each do |worker|
      next if worker.join(1)
      worker.kill
    end
  end

  it "retains the request when mail enqueue raises" do
    described_class.request_buyer_notification!(purchase.id)
    mail = double
    allow(CustomerMailer).to receive(:files_ready_for_download).and_return(mail)
    allow(mail).to receive(:deliver_later).and_raise("enqueue failed")

    expect { described_class.deliver_files_ready_notification!(purchase.id) }.to raise_error("enqueue failed")
    expect(described_class.buyer_notification_requested?(purchase.id)).to be(true)
    expect(url_redirect.reload.files_ready_notification_enqueued?).to be(false)
  end
end
