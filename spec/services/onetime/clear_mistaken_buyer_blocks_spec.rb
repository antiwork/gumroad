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
    travel_to(failed_purchase.created_at) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: buyer_email)
    end

    described_class.new(dry_run: false).process

    expect(PlatformBlock.active.pluck(:object_type, :object_value)).to eq([[PlatformBlock::TYPES[:charge_processor_fingerprint], buyer_email]])
  end

  it "leaves a block that was written long after the decline, which a different rule wrote" do
    PlatformBlock.active.find_each { |block| block.update!(blocked_at: failed_purchase.created_at + 1.day) }

    expect { described_class.new(dry_run: false).process }.not_to change { PlatformBlock.active.count }
  end

  # A charge needing Strong Customer Authentication stays in progress until the buyer finishes it or
  # FailAbandonedPurchaseWorker gives up, so the blocks carry a timestamp minutes after the purchase
  # was created. A sweep anchored on the purchase's own creation would report this buyer cleared and leave every
  # one of their blocks in place.
  it "clears blocks written minutes later, when the charge failed after an authentication step" do
    delayed = failed_purchase.created_at + ChargeProcessor::TIME_TO_COMPLETE_SCA
    PlatformBlock.active.find_each { |block| block.update!(blocked_at: delayed) }

    expect { described_class.new(dry_run: false).process }.to change { PlatformBlock.active.count }.from(3).to(0)
  end

  # Within that wider search window, a row from another code path still has to be left alone: the old
  # rule wrote all of its rows in one transition, so anything minutes away from the rest is not ours.
  it "leaves a lone block written minutes apart from the rest inside the same window" do
    velocity_block = PlatformBlock.active.find_by(object_type: PlatformBlock::TYPES[:ip_address])
    velocity_block.update!(blocked_at: failed_purchase.created_at + 10.minutes)

    described_class.new(dry_run: false).process

    expect(PlatformBlock.active.pluck(:id)).to eq([velocity_block.id])
  end

  # PlatformBlock.add! reuses the row for a (type, value) pair rather than inserting a second one, so
  # created_at is when we first ever heard of an identifier and blocked_at is when this block was
  # written. Every identifier that was blocked once before — a six-month IP block that expired, an
  # email block support lifted — carries an ancient created_at, and a sweep reading created_at skips
  # the row while reporting the buyer cleared.
  it "clears a re-used block row whose first insert long predates the decline" do
    PlatformBlock.active.find_each { |block| block.update!(created_at: 3.years.ago) }

    expect { described_class.new(dry_run: false).process }.to change { PlatformBlock.active.count }.from(3).to(0)
  end

  # The same confusion in the other direction, which is the dangerous one: the bug wrote a row long
  # ago, a card-testing rule re-blocked that same row last month, and the row still carries its
  # original created_at. Reading created_at makes last month's live enforcement look like part of the
  # old burst and clears it.
  it "leaves a row the bug wrote and something else re-blocked long afterwards" do
    PlatformBlock.active.find_each do |block|
      block.update!(created_at: failed_purchase.created_at, blocked_at: 1.month.from_now)
    end

    expect { described_class.new(dry_run: false).process }.not_to change { PlatformBlock.active.count }
  end

  # BlockSuspendedAccountIpWorker blocks the sign-in IP of every suspended account, unattended and so
  # with no blocked_by, for six months. A buyer sharing that address — carrier NAT, an office, a VPN
  # exit — must not have that block cleared just because their own decline happened at the same
  # moment. Unlike the velocity rules, this one cannot be reconstructed from the purchase, so the
  # burst has to prove it came from block_buyer! by containing an email or a card.
  it "leaves an IP-only block written by another automation at the same moment" do
    PlatformBlock.active.where.not(object_type: PlatformBlock::TYPES[:ip_address]).find_each(&:unblock!)

    expect { described_class.new(dry_run: false).process }.not_to change { PlatformBlock.active.count }
  end

  # The old rule blocked "the buyer's most recent card" as of the moment it ran. Asking today's code
  # for that value returns whichever card the buyer has used since, so the row actually written would
  # go unnoticed and the buyer would stay unable to pay with the older card.
  it "clears the card that was current when the block was written, not the buyer's latest card" do
    subscriber_email = "subscriber@example.com"
    declined_card = "fingerprint-of-the-card-that-declined"
    old_card = "fingerprint-of-the-card-that-was-blocked"
    create_list(:purchase, Purchase::Blockable::MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY,
                email: subscriber_email, purchase_state: "successful",
                stripe_fingerprint: declined_card, created_at: 6.months.ago)
    # The card on record when the renewal failed, which is the one the old rule blocked.
    create(:purchase, email: subscriber_email, purchase_state: "successful",
                      stripe_fingerprint: old_card, created_at: 2.months.ago)
    original = create(:membership_purchase, email: subscriber_email)
    renewal = create(:purchase, link: original.link, subscription: original.subscription,
                                email: subscriber_email, purchase_state: "failed",
                                stripe_error_code: "card_declined_lost_card",
                                stripe_fingerprint: declined_card,
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

  # A charge held for authentication fails minutes after it was created, so by the time the old rule
  # asked for "the buyer's most recent card" the buyer may have started another purchase — and that
  # is the card it blocked. Reconstructing only the card that existed when this purchase started
  # would miss that row and report the buyer cleared while their card stayed blocked.
  it "clears the card the buyer started using while the charge waited for authentication" do
    subscriber_email = "sca-subscriber@example.com"
    declined_card = "fingerprint-of-the-card-that-declined"
    later_card = "fingerprint-of-the-card-used-during-authentication"
    create_list(:purchase, Purchase::Blockable::MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY,
                email: subscriber_email, purchase_state: "successful",
                stripe_fingerprint: declined_card, created_at: 6.months.ago)
    original = create(:membership_purchase, email: subscriber_email)
    renewal = create(:purchase, link: original.link, subscription: original.subscription,
                                email: subscriber_email, purchase_state: "failed",
                                stripe_error_code: "card_declined_lost_card",
                                stripe_fingerprint: declined_card,
                                stripe_transaction_id: nil, charge_processor_id: nil, price_cents: 0)
    create(:purchase, email: subscriber_email, purchase_state: "successful",
                      stripe_fingerprint: later_card, created_at: renewal.created_at + 5.minutes)
    travel_to(renewal.created_at + 10.minutes) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: later_card)
    end

    described_class.new(dry_run: false).process

    expect(PlatformBlock.active.where(object_value: later_card)).to be_empty
  end

  # A block row is unique per type and value, so when a card-testing velocity rule fires in the same
  # transition as the mistaken block, both rules mean the same row. Clearing it would switch velocity
  # enforcement off for that identifier, so anything a velocity rule would have blocked is left alone
  # even when the buyer's own payment history is clean.
  describe "blocks a card-testing rule also wanted" do
    # Distinct failed cards, enough of them to trip a velocity rule, that are not themselves
    # candidates for this cleanup (their decline code is not one of the fraud-related ones).
    def create_failed_card_attempts(count:, created_at:, fingerprint_prefix: "card-tester-fingerprint", **attributes)
      count.times do |index|
        create(:purchase, purchase_state: "failed", stripe_error_code: "card_declined_insufficient_funds",
                          stripe_fingerprint: "#{fingerprint_prefix}-#{index}", created_at:, **attributes)
      end
    end

    it "leaves every block in place when the buyer's email tripped the velocity rule" do
      create_failed_card_attempts(count: Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS - 1,
                                  created_at: 1.hour.ago, email: buyer_email)

      expect { described_class.new(dry_run: false).process }.not_to change { PlatformBlock.active.count }
    end

    it "keeps the browser block when enough cards failed on that browser, and clears the rest" do
      create_failed_card_attempts(count: Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS - 1,
                                  created_at: 30.days.ago, browser_guid: failed_purchase.browser_guid)

      described_class.new(dry_run: false).process

      expect(PlatformBlock.active.pluck(:object_type, :object_value))
        .to eq([[PlatformBlock::TYPES[:browser_guid], failed_purchase.browser_guid]])
    end

    it "keeps the IP address block when enough cards failed from that address, and clears the rest" do
      create_failed_card_attempts(count: Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS - 1,
                                  created_at: 12.hours.ago, ip_address: failed_purchase.ip_address)

      described_class.new(dry_run: false).process

      expect(PlatformBlock.active.pluck(:object_type, :object_value))
        .to eq([[PlatformBlock::TYPES[:ip_address], failed_purchase.ip_address]])
    end

    it "clears normally when the failed cards are too old for any velocity window" do
      create_failed_card_attempts(count: Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS - 1,
                                  created_at: 30.days.ago, ip_address: failed_purchase.ip_address)

      expect { described_class.new(dry_run: false).process }.to change { PlatformBlock.active.count }.from(3).to(0)
    end

    # The browser reconstruction has to filter the same rows the live rule filters: counting
    # failures the live rule ignores retains exactly the outage-manufactured blocks this cleanup
    # exists to clear.
    it "clears a browser block that only processor-outage failures supported" do
      Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS.times do |index|
        # update_column: creating against the already-blocked guid overwrites error_code with
        # "blocked_browser_guid", which is not the row shape a processor outage writes.
        create(:purchase, purchase_state: "failed",
                          stripe_fingerprint: "outage-fingerprint-#{index}", created_at: 1.day.ago,
                          browser_guid: failed_purchase.browser_guid)
          .update_column(:error_code, PurchaseErrorCode::STRIPE_UNAVAILABLE)
      end

      expect { described_class.new(dry_run: false).process }.to change { PlatformBlock.active.count }.from(3).to(0)
    end

    # ban_fraudulent_buyer_browser_guid! counts qualifying failures for a browser over ALL time,
    # with no window at all. A reconstruction bounded by this purchase's possible_failure_window
    # misses failures that land after it, so it can clear a browser block the live rule's lifetime
    # count still wants. Regression for the P1 Greptile flagged on gp1701's PR: fails against a
    # window-bounded reconstruction because the fourth qualifying failure lands after window.end.
    it "keeps the browser block when a later failure is what trips the live lifetime threshold" do
      create_failed_card_attempts(count: Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS - 2,
                                  created_at: 30.days.ago, browser_guid: failed_purchase.browser_guid)
      create_failed_card_attempts(count: 1, fingerprint_prefix: "later-fingerprint",
                                  created_at: ChargeProcessor::TIME_TO_COMPLETE_SCA.from_now + 1.hour,
                                  browser_guid: failed_purchase.browser_guid)

      described_class.new(dry_run: false).process

      expect(PlatformBlock.active.pluck(:object_type, :object_value))
        .to eq([[PlatformBlock::TYPES[:browser_guid], failed_purchase.browser_guid]])
    end
  end

  # Most buyers here checked out as guests, so the purchase has no account attached and the
  # reconstruction query above looks up cards by `purchaser_id = <nil> or email = <theirs>`. In SQL
  # a comparison against NULL is never true, so on a guest that first condition matches nothing and
  # the lookup is the email alone — it does NOT quietly widen to every other guest on the platform.
  # That is easy to misread, and getting it wrong would be serious: a stranger's card block could
  # become a clearable pair and be lifted while the fraud rule that wrote it still means it. This
  # spec pins the behaviour so a later change to the query cannot make the misreading true.
  it "never reconstructs a card from an unrelated guest's purchase" do
    expect(failed_purchase.purchaser_id).to be_nil

    strangers_card = "unrelated-guest-card"
    create(:purchase, email: "stranger@example.com", purchase_state: "successful",
                      stripe_fingerprint: strangers_card, created_at: failed_purchase.created_at)
    travel_to(failed_purchase.created_at) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: strangers_card)
    end

    described_class.new(dry_run: false).process

    expect(PlatformBlock.active.pluck(:object_type, :object_value))
      .to eq([[PlatformBlock::TYPES[:charge_processor_fingerprint], strangers_card]])
  end
end
