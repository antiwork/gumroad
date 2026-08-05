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

    it "clears rows the automation actor itself wrote" do
      guid_block.update!(blocked_by: GUMROAD_ADMIN_ID)

      expect { call }.to change { PlatformBlock.active.count }.from(2).to(0)
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

  describe "human-authored escalation" do
    it "touches nothing when any block names a different human" do
      other_admin = create(:admin_user)
      email_block.update!(blocked_by: other_admin.id)

      result = nil
      expect { result = call }.not_to change { PlatformBlock.active.count }

      expect(result.verdict).to eq(:escalate)
      expect(result.reason).to eq(:human_authored_block)
      # The unattended guid row is also left: a human decision about this buyer freezes the whole set.
      expect(result.skipped.map(&:first)).to contain_exactly(email_block)
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

    let!(:card_block) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: declining_fingerprint)
    end

    it "leaves the card blocked while the issuer is still declining it" do
      create(:purchase, email: buyer_email, purchase_state: "failed",
                        stripe_fingerprint: declining_fingerprint,
                        stripe_error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD, created_at: 2.days.ago)

      result = call

      expect(result.verdict).to eq(:cleared)
      expect(result.skipped).to contain_exactly([card_block, :card_still_declining_at_issuer])
      expect(card_block.reload.blocked_at).to be_present
      expect(PlatformBlock.active.pluck(:object_value)).to eq([declining_fingerprint])
    end

    it "clears the card once a later charge on it succeeded" do
      create(:purchase, email: buyer_email, purchase_state: "failed",
                        stripe_fingerprint: declining_fingerprint,
                        stripe_error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD, created_at: 2.days.ago)
      create(:purchase, email: buyer_email, purchase_state: "successful",
                        stripe_fingerprint: declining_fingerprint, created_at: 1.day.ago)

      result = call

      expect(result.verdict).to eq(:cleared)
      expect(result.cleared).to include(card_block)
      expect(PlatformBlock.active.count).to eq(0)
    end
  end

  describe "verification" do
    it "raises when a cleared identifier is still actively blocked afterwards" do
      allow_any_instance_of(PlatformBlock).to receive(:unblock!) # a write that silently does nothing

      expect { call }.to raise_error(described_class::VerificationFailedError, /still active/)
    end

    it "raises instead of clearing when a block becomes human-authored underneath the run" do
      other_admin = create(:admin_user)
      allow_any_instance_of(PlatformBlock).to receive(:reload) do |block|
        block.update_columns(blocked_by: other_admin.id)
        block
      end

      expect { call }.to raise_error(described_class::UnsafeClearError, /human-authored/)
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
  end
end
