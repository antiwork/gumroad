# frozen_string_literal: true

require "spec_helper"

describe Risk::StrandedBuyerRecoveryService do
  let(:buyer_email) { "stranded-buyer@example.com" }
  let(:browser_guid) { "guid-stranded-buyer" }

  # Card-proven clean history: settled, undisputed purchases on the buyer's own fingerprint, old
  # enough to count.
  let!(:history) do
    create_list(:purchase, Purchase::Blockable::MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY,
                email: buyer_email, purchase_state: "successful", created_at: 6.months.ago)
  end

  let!(:failed_purchase) do
    create(:purchase, email: buyer_email, browser_guid:, purchase_state: "failed",
                      error_code: PurchaseErrorCode::BLOCKED_BROWSER_GUID, created_at: 1.day.ago)
  end

  let!(:guid_block) { PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid) }
  let!(:email_block) { PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: buyer_email) }

  def call(dry_run: false)
    described_class.call(email: buyer_email, dry_run:)
  end

  describe "clean clear" do
    it "clears the buyer's blocks, verifies, comments and emails them" do
      result = nil
      expect do
        result = call
      end.to change { PlatformBlock.active.count }.from(2).to(0)
         .and have_enqueued_mail(CustomerLowPriorityMailer, :blocked_purchase_resolved).with(failed_purchase.id)

      expect(result.verdict).to eq(:cleared)
      expect(result.cleared.map(&:object_value)).to match_array([browser_guid, buyer_email])
      expect(result.attribution[:rule]).to eq(:single_decline_auto_block)
    end

    it "records the attribution on the buyer's account when one exists" do
      user = create(:user, email: buyer_email)

      call

      comment = user.comments.last
      expect(comment.content).to include("Stranded-buyer recovery cleared 2 platform block(s)")
      expect(comment.content).to include("single_decline_auto_block")
      expect(comment.author_id).to eq(GUMROAD_ADMIN_ID)
    end

    it "falls back to a purchase comment when no account exists" do
      call

      anchor = Purchase.where(email: buyer_email).where.not(stripe_fingerprint: nil).order(id: :desc).first
      expect(anchor.comments.last.content).to include("Stranded-buyer recovery cleared")
    end
  end

  describe "identifier harvesting" do
    # A checkout email is unauthenticated: a card tester who typed the buyer's address contributes
    # rows to the footprint, but without the buyer's proven card or account nothing they carried is
    # harvested — their guid block stays put while the buyer's own rows clear.
    it "does not harvest identifiers from same-email rows the buyer's fingerprints do not corroborate" do
      create(:purchase, email: buyer_email, purchase_state: "failed",
                        browser_guid: "guid-card-tester", stripe_fingerprint: "tester-card",
                        created_at: 2.days.ago)
      tester_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-card-tester")

      result = call

      expect(result.verdict).to eq(:cleared)
      expect(result.cleared.map(&:object_value)).to match_array([browser_guid, buyer_email])
      expect(tester_block.reload.blocked_at).to be_present
    end

    # PayPal and gifter addresses are typed-in third-party strings on a row, not the buyer's
    # identity — clearing this buyer must not deactivate a block somebody else earned.
    it "does not harvest paypal or gifter emails from the buyer's own rows" do
      failed_purchase.update!(is_gift_sender_purchase: true)
      create(:gift, gifter_purchase: failed_purchase, gifter_email: "someone-else@example.net")
      third_party_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "someone-else@example.net")

      result = call

      expect(result.verdict).to eq(:cleared)
      expect(result.cleared.map(&:object_value)).to match_array([browser_guid, buyer_email])
      expect(third_party_block.reload.blocked_at).to be_present
    end

    # Blockable#same_email_guest_purchases has the same exclusion: an email match proves nothing
    # about rows another account owns, even when that account's card history is clean.
    it "does not let a different account's same-email rows anchor innocence or contribute identifiers" do
      other_account = create(:user, email: "other-owner@example.net")
      create(:purchase, purchaser: other_account, email: buyer_email, purchase_state: "successful",
                        browser_guid: "guid-other-account", stripe_fingerprint: "other-account-card",
                        created_at: 120.days.ago)
      other_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-other-account")

      result = call

      expect(result.cleared.map(&:object_value)).not_to include("guid-other-account")
      expect(other_block.reload.blocked_at).to be_present
    end
  end

  describe "authored-block escalation" do
    it "touches nothing when any block names a different human" do
      other_admin = create(:admin_user)
      email_block.update!(blocked_by: other_admin.id)

      result = nil
      expect { result = call }.not_to change { PlatformBlock.active.count }

      expect(result.verdict).to eq(:escalate)
      expect(result.reason).to eq(:authored_block)
      # The unattended guid row is also left: an authored decision about this buyer freezes the whole set.
      expect(result.skipped.map(&:first)).to contain_exactly(email_block)
    end

    # GUMROAD_ADMIN_ID authors CONFIRMED-FRAUD blocks (chargeback count, EFW) — the shared actor id
    # marks a verdict, not stale automation, so it escalates exactly like a human's row.
    it "escalates rows the shared automation actor wrote instead of clearing them" do
      guid_block.update!(blocked_by: GUMROAD_ADMIN_ID)

      result = nil
      expect { result = call }.not_to change { PlatformBlock.active.count }

      expect(result.verdict).to eq(:escalate)
      expect(result.reason).to eq(:authored_block)
      expect(result.skipped.map(&:first)).to contain_exactly(guid_block)
    end
  end

  describe "dry run" do
    it "is the default and changes nothing" do
      result = nil
      expect do
        result = described_class.call(email: buyer_email)
      end.to not_change { PlatformBlock.active.count }
         .and not_have_enqueued_mail(CustomerLowPriorityMailer, :blocked_purchase_resolved)

      expect(result.verdict).to eq(:cleared)
      expect(result.dry_run).to be(true)
    end
  end

  describe "dirty history" do
    it "skips a buyer whose history carries a chargeback" do
      history.each { |purchase| purchase.update!(chargeback_date: 1.month.ago) }

      result = nil
      expect { result = call }.not_to change { PlatformBlock.active.count }

      expect(result.verdict).to eq(:skip)
      expect(result.reason).to eq(:no_clean_payment_history)
    end

    it "skips a buyer with no card-proven history at all" do
      Purchase.where(email: buyer_email).update_all(stripe_fingerprint: nil)

      result = call
      expect(result.verdict).to eq(:skip)
      expect(result.reason).to eq(:no_clean_payment_history)
    end

    # The scan's reject_disputed veto, re-checked here: a clean anchor card does not vouch for a
    # buyer carrying a live dispute on a DIFFERENT card — a chargeback anywhere is what blocks are for.
    it "skips a buyer with an unreversed chargeback on another card" do
      create(:purchase, email: buyer_email, purchase_state: "successful",
                        stripe_fingerprint: "disputed-other-card", chargeback_date: 1.month.ago,
                        created_at: 7.months.ago)

      result = nil
      expect { result = call }.not_to change { PlatformBlock.active.count }

      expect(result.verdict).to eq(:skip)
      expect(result.reason).to eq(:unreversed_chargeback)
    end

    it "does not veto on a chargeback that was reversed" do
      create(:purchase, email: buyer_email, purchase_state: "successful",
                        stripe_fingerprint: "reversed-other-card", chargeback_date: 1.month.ago,
                        chargeback_reversed: true, created_at: 7.months.ago)

      expect(call.verdict).to eq(:cleared)
    end
  end

  describe "velocity attribution" do
    it "skips while a card-testing velocity rule still fires on collapsed counts" do
      Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS.times do |index|
        create(:purchase, email: buyer_email, browser_guid:, purchase_state: "failed",
                          stripe_fingerprint: "distinct-card-#{index}", created_at: 1.day.ago)
      end

      result = nil
      expect { result = call }.not_to change { PlatformBlock.active.count }

      expect(result.verdict).to eq(:skip)
      expect(result.reason).to eq(:velocity_rule_still_firing)
      expect(result.attribution[:recent_distinct_cards]).to be >= Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS
    end

    # The guid rule has no window, so failures older than the 7-day watch period still arm it:
    # unexplained all-time distinct cards over threshold mean the rule re-fires on the next attempt.
    it "skips when all-time distinct failed cards the anchor does not explain still arm the guid rule" do
      Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS.times do |index|
        create(:purchase, email: buyer_email, browser_guid:, purchase_state: "failed",
                          stripe_fingerprint: "stale-card-#{index}", created_at: 30.days.ago)
      end

      result = nil
      expect { result = call }.not_to change { PlatformBlock.active.count }

      expect(result.verdict).to eq(:skip)
      expect(result.reason).to eq(:velocity_rule_still_firing)
      expect(result.attribution[:recent_distinct_cards]).to be < Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS
      expect(result.attribution[:all_time_unexplained_cards]).to be >= Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS
    end

    # One PayPal wallet mints a fresh billing-agreement token per attempt, so raw fingerprints trip
    # a four-card rule the collapsed count never would. The collapse is what lets this buyer clear.
    it "collapses PayPal wallet tokens and clears a buyer the raw count would have held" do
      Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS.times do |index|
        create(:purchase, email: buyer_email, browser_guid:, purchase_state: "failed",
                          charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                          stripe_fingerprint: "B-#{index}TOKEN", card_visual: "buyer@paypal.com",
                          created_at: 1.day.ago)
      end

      result = nil
      expect { result = call }.to change { PlatformBlock.active.count }.from(2).to(0)

      expect(result.verdict).to eq(:cleared)
      expect(result.attribution[:rule]).to eq(:paypal_wallet_inflation)
      expect(result.attribution[:paypal_collapse_applied]).to be(true)
      expect(result.attribution[:recent_raw_fingerprints]).to be > result.attribution[:recent_distinct_cards]
    end
  end

  describe "card-fingerprint blocks" do
    let(:declining_fingerprint) { "still-declining-card" }
    let!(:buyer_account) { create(:user, email: buyer_email) }

    let!(:card_block) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: declining_fingerprint)
    end

    it "leaves the card blocked while the issuer is still declining it" do
      create(:purchase, email: buyer_email, purchaser: buyer_account, purchase_state: "failed",
                        stripe_fingerprint: declining_fingerprint,
                        stripe_error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD, created_at: 2.days.ago)

      result = call

      expect(result.verdict).to eq(:cleared)
      expect(result.skipped).to contain_exactly([card_block, :card_still_declining_at_issuer])
      expect(card_block.reload.blocked_at).to be_present
      expect(PlatformBlock.active.pluck(:object_value)).to eq([declining_fingerprint])
    end

    it "clears the card once a later charge on it succeeded" do
      create(:purchase, email: buyer_email, purchaser: buyer_account, purchase_state: "failed",
                        stripe_fingerprint: declining_fingerprint,
                        stripe_error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD, created_at: 2.days.ago)
      create(:purchase, email: buyer_email, purchaser: buyer_account, purchase_state: "successful",
                        stripe_fingerprint: declining_fingerprint, created_at: 1.day.ago)

      result = call

      expect(result.verdict).to eq(:cleared)
      expect(result.cleared).to include(card_block)
      expect(PlatformBlock.active.count).to eq(0)
    end

    # A PayPal wallet's block value is card_visual (the attested payer email), not a Stripe
    # fingerprint — the withhold must recognize it or a blocked wallet clears while still declining.
    it "withholds a PayPal wallet block while the wallet is still declining" do
      create(:purchase, email: buyer_email, purchaser: buyer_account, purchase_state: "failed",
                        charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                        stripe_fingerprint: "B-WALLETTOKEN", card_visual: "buyer@paypal.com",
                        stripe_error_code: PurchaseErrorCode::CARD_DECLINED_FRAUDULENT, created_at: 2.days.ago)
      wallet_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: "buyer@paypal.com")

      result = call

      expect(result.verdict).to eq(:cleared)
      expect(result.skipped).to include([wallet_block, :card_still_declining_at_issuer])
      expect(wallet_block.reload.blocked_at).to be_present
    end
  end

  describe "verification" do
    it "raises when a cleared identifier is still actively blocked afterwards" do
      allow_any_instance_of(PlatformBlock).to receive(:unblock!) # a write that silently does nothing

      expect { call }.to raise_error(described_class::VerificationFailedError, /still active/)
    end

    it "raises instead of clearing when a block becomes authored underneath the run" do
      other_admin = create(:admin_user)
      allow_any_instance_of(PlatformBlock).to receive(:reload) do |block|
        block.update_columns(blocked_by: other_admin.id)
        block
      end

      expect { call }.to raise_error(described_class::UnsafeClearError, /names an author/)
    end

    # A fresh blocked_at between the decision snapshot and the write is a re-block by a live rule —
    # wiping it would switch enforcement off mid-attack.
    it "raises instead of clearing when a block was re-blocked underneath the run" do
      allow_any_instance_of(PlatformBlock).to receive(:reload) do |block|
        block.update_columns(blocked_at: Time.current + 1.hour)
        block
      end

      expect { call }.to raise_error(described_class::UnsafeClearError, /re-blocked/)
    end
  end

  describe "buyer notification gating" do
    it "sends nothing when the buyer has not failed a purchase in the last 60 days" do
      failed_purchase.update!(created_at: 61.days.ago)

      expect do
        call
      end.to change { PlatformBlock.active.count }.to(0)
         .and not_have_enqueued_mail(CustomerLowPriorityMailer, :blocked_purchase_resolved)
    end

    # An ordinary decline is not something this run resolved — only a failure carrying one of our
    # block error codes proves the buyer actually hit the block being cleared.
    it "sends nothing when the newest recent failure was not declined by our block" do
      # A fresh guid, or check_for_fraud stamps the row with the block code at creation.
      create(:purchase, email: buyer_email, purchase_state: "failed",
                        stripe_error_code: "card_declined_generic_decline", created_at: 12.hours.ago)

      expect do
        call
      end.to change { PlatformBlock.active.count }.to(0)
         .and not_have_enqueued_mail(CustomerLowPriorityMailer, :blocked_purchase_resolved)
    end
  end

  describe "no-ops" do
    it "reports a buyer with no active blocks" do
      PlatformBlock.active.each(&:unblock!)

      result = call
      expect(result.verdict).to eq(:noop)
      expect(result.reason).to eq(:no_active_blocks)
    end

    it "reports an unknown buyer" do
      result = described_class.call(email: "nobody@example.com", dry_run: false)
      expect(result.verdict).to eq(:noop)
      expect(result.reason).to eq(:buyer_not_found)
    end

    it "requires an identifier" do
      expect { described_class.call }.to raise_error(ArgumentError)
    end
  end

  describe "lookup by user external id" do
    it "resolves the buyer through their account" do
      user = create(:user, email: buyer_email)

      result = described_class.call(user_external_id: user.external_id, dry_run: false)

      expect(result.verdict).to eq(:cleared)
      expect(PlatformBlock.active.count).to eq(0)
    end

    it "never mixes a supplied email into the resolved user's scope, so an unrelated victim's blocks stay untouched" do
      account_owner = create(:user, email: buyer_email)
      victim_email = "victim@example.com"
      victim_guid = "guid-victim"
      create(:purchase, email: victim_email, browser_guid: victim_guid, purchase_state: "failed", created_at: 1.day.ago)
      victim_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: victim_guid)

      result = described_class.call(user_external_id: account_owner.external_id, email: victim_email, dry_run: false)

      expect(result.cleared).not_to include(victim_block)
      expect(victim_block.reload.blocked_at).to be_present
    end

    it "never clears a victim's email block directly, even though the caller supplied that email (Greptile P1)" do
      account_owner = create(:user, email: buyer_email)
      victim_email = "victim-email-block@example.com"
      victim_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: victim_email)

      result = described_class.call(user_external_id: account_owner.external_id, email: victim_email, dry_run: false)

      expect(result.cleared).not_to include(victim_block)
      expect(victim_block.reload.blocked_at).to be_present
    end
  end

  describe "shared-radius identifiers (email_domain, ip_address)" do
    it "withholds a domain block instead of auto-clearing it — one buyer's history doesn't vouch for everyone on the domain" do
      domain_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email_domain], object_value: "example.com")

      result = call

      expect(result.verdict).to eq(:cleared)
      expect(result.cleared.map(&:object_value)).to match_array([browser_guid, buyer_email])
      expect(result.skipped).to include([domain_block, :shared_identifier_needs_human_review])
      expect(domain_block.reload.blocked_at).to be_present
    end

    it "withholds an IP block instead of auto-clearing it" do
      create(:purchase, email: buyer_email, purchase_state: "successful", ip_address: "203.0.113.5", created_at: 6.months.ago)
      ip_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: "203.0.113.5", expires_in: 30.days)

      result = call

      expect(result.skipped).to include([ip_block, :shared_identifier_needs_human_review])
      expect(ip_block.reload.blocked_at).to be_present
    end
  end

  describe "atomicity of the clear batch" do
    it "rolls back every unblock! in the batch when verification fails partway through" do
      allow_any_instance_of(PlatformBlock).to receive(:unblock!) # silently does nothing -> verify! raises

      expect { call }.to raise_error(described_class::VerificationFailedError)
      expect(PlatformBlock.active.count).to eq(2) # nothing committed, not "some cleared"
    end

    it "rolls back every unblock! when a block goes human-authored mid-batch" do
      other_admin = create(:admin_user)
      allow_any_instance_of(PlatformBlock).to receive(:reload) do |block|
        block.update_columns(blocked_by: other_admin.id)
        block
      end

      expect { call }.to raise_error(described_class::UnsafeClearError)
      expect(PlatformBlock.active.count).to eq(2)
    end
  end

  describe "notification withheld alongside a still-declining card" do
    it "does not email the buyer when a retained card-fingerprint block still guarantees their retry fails" do
      buyer_account = create(:user, email: buyer_email)
      declining_fingerprint = "still-declining-card"
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: declining_fingerprint)
      create(:purchase, email: buyer_email, purchaser: buyer_account, purchase_state: "failed",
                        stripe_fingerprint: declining_fingerprint,
                        stripe_error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD, created_at: 2.days.ago)

      expect do
        call
      end.to not_have_enqueued_mail(CustomerLowPriorityMailer, :blocked_purchase_resolved)
    end
  end

  describe "notification withheld alongside a withheld shared-radius block (Greptile P1)" do
    it "does not email the buyer when an active IP block on their own checkout path is withheld for human review" do
      create(:purchase, email: buyer_email, purchase_state: "successful", ip_address: "203.0.113.5", created_at: 6.months.ago)
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: "203.0.113.5", expires_in: 30.days)

      expect do
        call
      end.to not_have_enqueued_mail(CustomerLowPriorityMailer, :blocked_purchase_resolved)
    end

    it "does not email the buyer when an active email_domain block is withheld for human review" do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email_domain], object_value: "example.com")

      expect do
        call
      end.to not_have_enqueued_mail(CustomerLowPriorityMailer, :blocked_purchase_resolved)
    end
  end
end
