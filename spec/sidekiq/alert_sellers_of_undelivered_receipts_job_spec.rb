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
      .with(seller.id, [purchase.id], 1)
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
      .with(seller.id, [first.id, second.id], 2).once
  end

  # The record is per buyer, so a second run over the same rows must find nothing to report. Without
  # it the sweep re-emails every seller in the window whenever the cursor is reset or replayed.
  it "does not report the same buyer twice" do
    undelivered_purchase
    described_class.new.perform

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
    allow(ContactingCreatorMailer).to receive(:undelivered_receipts).with(seller.id, [first.id], 1).and_raise(StandardError)
    expect(ErrorNotifier).to receive(:notify)

    expect { described_class.new.perform }
      .to have_enqueued_mail(ContactingCreatorMailer, :undelivered_receipts)
      .with(other_seller.id, [second.id], 1)
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
