# frozen_string_literal: true

require "spec_helper"

describe AlertSellersOfUndeliveredReceiptsJob do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  def undelivered_purchase(state: "sent", sent_at: 3.days.ago)
    purchase = create(:purchase, seller:, link: product)
    create(:customer_email_info, purchase:, state:, sent_at:)
    purchase
  end

  before do
    $redis.del(RedisKey.undelivered_receipt_sweep_cursor)
    $redis.set(RedisKey.undelivered_receipt_sweep_cursor, 0)
  end

  it "emails the seller about a buyer with no confirmed receipt" do
    purchase = undelivered_purchase

    expect { described_class.new.perform }
      .to have_enqueued_mail(ContactingCreatorMailer, :undelivered_receipts)
      .with(seller.id, [purchase.id])
  end

  it "emails nobody when every receipt was delivered" do
    purchase = create(:purchase, seller:, link: product)
    create(:customer_email_info, purchase:, state: "delivered", sent_at: 3.days.ago, delivered_at: 3.days.ago)

    expect { described_class.new.perform }
      .not_to have_enqueued_mail(ContactingCreatorMailer, :undelivered_receipts)
  end

  it "groups a seller's buyers into one email" do
    first = undelivered_purchase
    second = undelivered_purchase

    expect { described_class.new.perform }
      .to have_enqueued_mail(ContactingCreatorMailer, :undelivered_receipts)
      .with(seller.id, [first.id, second.id]).once
  end

  # The record is per buyer and is written by the mailer once the message is delivered, so a second
  # run over the same rows must find nothing to report. Without it the sweep re-emails every seller in
  # the window whenever the cursor is reset or replayed.
  it "does not report the same buyer twice" do
    purchase = undelivered_purchase
    described_class.new.perform
    UndeliveredReceiptNotifier.record_sent([purchase.id])

    $redis.set(RedisKey.undelivered_receipt_sweep_cursor, 0)

    expect { described_class.new.perform }
      .not_to have_enqueued_mail(ContactingCreatorMailer, :undelivered_receipts)
  end

  it "advances the cursor past the rows it judged" do
    undelivered_purchase
    described_class.new.perform

    expect($redis.get(RedisKey.undelivered_receipt_sweep_cursor).to_i).to eq(EmailInfo.maximum(:id))
  end

  # Advancing past a row too young to judge would decide its case by never looking at it again.
  it "leaves the cursor behind a row still inside the settle grace" do
    undelivered_purchase(sent_at: 1.hour.ago)

    described_class.new.perform

    expect($redis.get(RedisKey.undelivered_receipt_sweep_cursor).to_i).to eq(0)
  end

  # `partition` let a settled row later in the same batch move the cursor past an earlier unsettled
  # one, and the next run queries after the cursor — the skipped row was never reconsidered.
  it "leaves the cursor behind an unsettled row that a later settled row follows" do
    young = undelivered_purchase(sent_at: 1.hour.ago)
    undelivered_purchase(sent_at: 3.days.ago)

    described_class.new.perform

    cursor = $redis.get(RedisKey.undelivered_receipt_sweep_cursor).to_i
    expect(cursor).to be < young.reload.receipt_email_info.id
  end

  it "reports the buyer that an earlier unsettled row had blocked, once it settles" do
    young = undelivered_purchase(sent_at: 1.hour.ago)
    later = undelivered_purchase(sent_at: 3.days.ago)
    described_class.new.perform

    young.receipt_email_info.update!(sent_at: 3.days.ago)

    expect { described_class.new.perform }
      .to have_enqueued_mail(ContactingCreatorMailer, :undelivered_receipts)
      .with(seller.id, [young.id, later.id])
  end

  # Truncating here let ten recovered buyers suppress a digest an eleventh still needed, while the job
  # marked every one of them notified. The mailer re-judges the full set and cuts the list itself.
  it "hands the mailer every affected buyer, untruncated" do
    purchases = Array.new(UndeliveredReceiptNotifier::MAX_LISTED_PER_SELLER + 1) { undelivered_purchase }

    expect { described_class.new.perform }
      .to have_enqueued_mail(ContactingCreatorMailer, :undelivered_receipts)
      .with(seller.id, purchases.map(&:id))
  end

  # Nothing may be marked notified by the sweep itself: the mailer claims at render and settles after
  # delivery, so a suppressed or failed send leaves the buyer reportable tomorrow.
  it "does not record a buyer as notified before the mail is delivered" do
    purchase = undelivered_purchase

    described_class.new.perform

    expect($redis.exists?(RedisKey.undelivered_receipt_notified(purchase.id))).to be false
  end

  it "skips a suspended seller" do
    undelivered_purchase
    seller.update!(user_risk_state: "suspended_for_tos_violation")

    expect { described_class.new.perform }
      .not_to have_enqueued_mail(ContactingCreatorMailer, :undelivered_receipts)
  end

  # Each seller's notice is independent: nothing re-enqueues the ones skipped, because the cursor
  # advances past their rows either way.
  it "still notifies the remaining sellers when one seller's enqueue fails" do
    other_seller = create(:user)
    other_product = create(:product, user: other_seller)
    first = undelivered_purchase
    second = create(:purchase, seller: other_seller, link: other_product)
    create(:customer_email_info, purchase: second, state: "sent", sent_at: 3.days.ago)

    allow(ContactingCreatorMailer).to receive(:undelivered_receipts).and_call_original
    allow(ContactingCreatorMailer).to receive(:undelivered_receipts).with(seller.id, [first.id]).and_raise(StandardError)
    expect(ErrorNotifier).to receive(:notify)

    expect { described_class.new.perform }
      .to have_enqueued_mail(ContactingCreatorMailer, :undelivered_receipts)
      .with(other_seller.id, [second.id])
  end

  # A missing cursor means no safe start: resuming from zero would walk the whole table and re-report
  # every seller in it.
  it "does nothing when the cursor cannot be read" do
    undelivered_purchase
    allow($redis).to receive(:get).and_raise(StandardError)
    expect(ErrorNotifier).to receive(:notify)

    expect { described_class.new.perform }
      .not_to have_enqueued_mail(ContactingCreatorMailer, :undelivered_receipts)
  end
end
