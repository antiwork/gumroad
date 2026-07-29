# frozen_string_literal: true

require "spec_helper"

describe Onetime::ClearMistakenBuyerBlocks do
  let(:buyer_email) { "loyal-buyer@example.com" }

  # A buyer the old rule would have blocked wrongly: three settled, undisputed purchases behind
  # them, then one renewal declined with "lost card", which blocked everything about them. The old
  # rule wrote its blocks inside the failure transition, so they carry the purchase's own timestamp.
  def block_everything_for(purchase)
    travel_to(purchase.created_at) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: purchase.browser_guid)
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: purchase.email)
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: purchase.ip_address, expires_in: 6.months)
    end
  end

  let!(:history) do
    create_list(:purchase, Purchase::Blockable::MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY,
                email: buyer_email, purchase_state: "successful", created_at: 6.months.ago)
  end

  let!(:failed_purchase) do
    create(:purchase, email: buyer_email, purchase_state: "failed", stripe_error_code: "card_declined_lost_card")
  end

  before { block_everything_for(failed_purchase) }

  it "clears the automated blocks that hold a buyer with clean history" do
    expect { described_class.new(dry_run: false).process }.to change { PlatformBlock.active.count }.from(3).to(0)
  end

  it "reports what it cleared" do
    result = described_class.new(dry_run: false).process

    expect(result.length).to eq(1)
    expect(result.first[:purchase_id]).to eq(failed_purchase.id)
    expect(result.first[:error_code]).to eq("card_declined_lost_card")
    expect(result.first[:blocks].map(&:last)).to match_array([failed_purchase.browser_guid, failed_purchase.ip_address, buyer_email])
  end

  it "changes nothing by default, because clearing has to be asked for" do
    expect { described_class.new.process }.not_to change { PlatformBlock.active.count }
  end

  it "leaves blocks an admin created alone" do
    admin = create(:admin_user)
    PlatformBlock.active.each { |block| block.update!(blocked_by: admin.id) }

    expect { described_class.new(dry_run: false).process }.not_to change { PlatformBlock.active.count }
  end

  it "leaves a buyer without clean history blocked" do
    history.each { |purchase| purchase.update!(chargeback_date: 1.month.ago) }

    expect { described_class.new(dry_run: false).process }.not_to change { PlatformBlock.active.count }
  end

  it "leaves blocks from a non-fraud decline alone" do
    failed_purchase.update!(stripe_error_code: "card_declined_insufficient_funds")

    expect { described_class.new(dry_run: false).process }.not_to change { PlatformBlock.active.count }
  end

  it "leaves a block of a different type that happens to share a value" do
    PlatformBlock.active.find_by(object_type: PlatformBlock::TYPES[:email]).unblock!
    travel_to(failed_purchase.created_at) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: buyer_email)
    end

    described_class.new(dry_run: false).process

    expect(PlatformBlock.active.pluck(:object_type, :object_value)).to eq([[PlatformBlock::TYPES[:charge_processor_fingerprint], buyer_email]])
  end

  it "leaves a block that was created long after the decline, which a different rule wrote" do
    PlatformBlock.active.find_each { |block| block.update!(created_at: failed_purchase.created_at + 1.day) }

    expect { described_class.new(dry_run: false).process }.not_to change { PlatformBlock.active.count }
  end

  # A charge needing Strong Customer Authentication stays in progress until the buyer finishes it or
  # FailAbandonedPurchaseWorker gives up, so the blocks carry a timestamp minutes after the purchase
  # was created. A sweep anchored on created_at alone would report this buyer cleared and leave every
  # one of their blocks in place.
  it "clears blocks written minutes later, when the charge failed after an authentication step" do
    delayed = failed_purchase.created_at + ChargeProcessor::TIME_TO_COMPLETE_SCA
    PlatformBlock.active.find_each { |block| block.update!(created_at: delayed) }

    expect { described_class.new(dry_run: false).process }.to change { PlatformBlock.active.count }.from(3).to(0)
  end

  # Within that wider search window, a row from another code path still has to be left alone: the old
  # rule wrote all of its rows in one transition, so anything minutes away from the rest is not ours.
  it "leaves a lone block written minutes apart from the rest inside the same window" do
    velocity_block = PlatformBlock.active.find_by(object_type: PlatformBlock::TYPES[:ip_address])
    velocity_block.update!(created_at: failed_purchase.created_at + 10.minutes)

    described_class.new(dry_run: false).process

    expect(PlatformBlock.active.pluck(:id)).to eq([velocity_block.id])
  end

  # The old rule blocked "the buyer's most recent card" as of the moment it ran. Asking today's code
  # for that value returns whichever card the buyer has used since, so the row actually written would
  # go unnoticed and the buyer would stay unable to pay with the older card.
  it "clears the card that was current when the block was written, not the buyer's latest card" do
    subscriber_email = "subscriber@example.com"
    old_card = "fingerprint-of-the-card-that-was-blocked"
    create_list(:purchase, Purchase::Blockable::MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY,
                email: subscriber_email, purchase_state: "successful",
                stripe_fingerprint: old_card, created_at: 6.months.ago)
    # A renewal with no card fingerprint of its own, so the block came from the buyer's recent card.
    original = create(:membership_purchase, email: subscriber_email)
    renewal = create(:purchase, link: original.link, subscription: original.subscription,
                                email: subscriber_email, purchase_state: "failed",
                                stripe_error_code: "card_declined_lost_card", stripe_fingerprint: nil,
                                stripe_transaction_id: nil, charge_processor_id: nil, price_cents: 0)
    travel_to(renewal.created_at) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: old_card)
    end
    # The buyer moved on to another card afterwards, so "their most recent card" today is this one.
    create(:purchase, email: subscriber_email, purchase_state: "successful",
                      stripe_fingerprint: "fingerprint-of-a-newer-card", created_at: 1.day.ago)

    described_class.new(dry_run: false).process

    expect(PlatformBlock.active.where(object_value: old_card)).to be_empty
  end
end
