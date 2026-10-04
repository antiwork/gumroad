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

    # An attacker's own card is clean under THEIR OWN email, not the victim's — but a checkout
    # email is unauthenticated, so they can type the victim's address at a single guest checkout.
    # buyer_has_clean_payment_history? checks the fingerprint globally, blind to whose email the
    # settled rows carry, so that fabricated row would otherwise self-corroborate off the
    # attacker's own history and let recovery harvest (and unblock) the attacker's guid.
    it "does not let an attacker's own clean card history corroborate a guest row typed with the victim's email" do
      attacker_fingerprint = "attacker-own-card"
      create_list(:purchase, Purchase::Blockable::MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY,
                  email: "attacker@example.net", stripe_fingerprint: attacker_fingerprint,
                  purchase_state: "successful", created_at: 6.months.ago)
      create(:purchase, email: buyer_email, purchase_state: "failed",
                        browser_guid: "guid-attacker", stripe_fingerprint: attacker_fingerprint,
                        created_at: 2.days.ago)
      attacker_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-attacker")

      result = call

      expect(result.cleared.map(&:object_value)).not_to include("guid-attacker")
      expect(attacker_block.reload.blocked_at).to be_present
    end

    # A logged-in buyer's checkout `email` is a typed field, not their authenticated identity —
    # they can set it to anyone. Only the account's own email should ever be harvested from an
    # account-owned row (Greptile P1: fails against the pre-fix code, which pushed the raw
    # checkout email for every row in buyer_purchases, account-owned or not).
    it "does not harvest an unrelated checkout email typed on the buyer's own account-owned purchase" do
      account = create(:user, email: buyer_email)
      history.each { _1.update!(purchaser: account) }
      failed_purchase.update!(purchaser: account)
      create(:purchase, purchaser: account, email: "unrelated-victim@example.net",
                        stripe_fingerprint: "account-owner-own-card",
                        purchase_state: "successful", created_at: 3.months.ago)
      unrelated_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "unrelated-victim@example.net")

      result = call

      expect(result.verdict).to eq(:cleared)
      expect(result.cleared.map(&:object_value)).not_to include("unrelated-victim@example.net")
      expect(unrelated_block.reload.blocked_at).to be_present
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

    it "finds the proving card even when a blocked buyer has cycled through more than 10 newer cards" do
      11.times do |i|
        create(:purchase, email: buyer_email, purchase_state: "successful", stripe_fingerprint: "newer-card-#{i}", created_at: 1.day.ago)
      end

      result = call
      expect(result.verdict).to eq(:cleared)
    end

    # account_purchases proves identity via purchaser_id, not email — but that's a proxy for WHO
    # the row belongs to, not a waiver on HOW MANY settled rows the fingerprint needs. A single
    # fresh account purchase must not anchor innocence on its own; it still has to clear the same
    # min-3/60-day bar as a guest row, just counted by account instead of email.
    it "does not let a single fresh account purchase skip the min-count/age bar" do
      user = create(:user, email: buyer_email)
      history.each { |purchase| purchase.update!(purchaser_id: nil, email: "someone-else@example.net") }
      Purchase.where(email: buyer_email).update_all(stripe_fingerprint: nil)
      create(:purchase, purchaser: user, email: buyer_email, purchase_state: "successful",
                        stripe_fingerprint: "one-fresh-account-purchase", created_at: 1.day.ago)

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

    it "does not veto on a PayPal-processor chargeback" do
      paypal = create(:purchase, email: buyer_email, purchase_state: "successful",
                                 stripe_fingerprint: "paypal-other-card", chargeback_date: 1.month.ago,
                                 created_at: 7.months.ago)
      paypal.update_column(:charge_processor_id, PaypalChargeProcessor.charge_processor_id)

      expect(call.verdict).to eq(:cleared)
    end

    it "does not veto on a chargeback that was reversed" do
      create(:purchase, email: buyer_email, purchase_state: "successful",
                        stripe_fingerprint: "reversed-other-card", chargeback_date: 1.month.ago,
                        chargeback_reversed: true, created_at: 7.months.ago)

      expect(call.verdict).to eq(:cleared)
    end

    # A dispute on an unrelated request email must not veto (or fail to veto) the resolved buyer's
    # OWN recovery — once user_external_id resolves an identity, only that identity's chargeback
    # history counts, mirroring the identifier_emails/candidate_purchases isolation above.
    # Mutation-verified: fails against the pre-fix scope that ORs in the raw request @email.
    it "does not veto on an unrelated request email's chargeback once user resolves" do
      user = create(:user, email: buyer_email)
      history.each { |purchase| purchase.update!(purchaser_id: user.id) }
      failed_purchase.update!(purchaser_id: user.id)

      create(:purchase, email: "unrelated-victim@example.com", purchase_state: "successful",
                        stripe_fingerprint: "victim-card", chargeback_date: 1.month.ago,
                        created_at: 7.months.ago)

      result = Risk::StrandedBuyerRecoveryService.call(
        user_external_id: user.external_id, email: "unrelated-victim@example.com", dry_run: false
      )

      expect(result.verdict).to eq(:cleared)
    end

    it "still vetoes on the resolved user's OWN chargeback even when a different request email is supplied" do
      user = create(:user, email: buyer_email)
      history.each { |purchase| purchase.update!(purchaser_id: user.id) }
      failed_purchase.update!(purchaser_id: user.id)
      create(:purchase, purchaser_id: user.id, purchase_state: "successful",
                        stripe_fingerprint: "disputed-other-card", chargeback_date: 1.month.ago,
                        created_at: 7.months.ago)

      result = Risk::StrandedBuyerRecoveryService.call(
        user_external_id: user.external_id, email: "unrelated-victim@example.com", dry_run: false
      )

      expect(result.verdict).to eq(:skip)
      expect(result.reason).to eq(:unreversed_chargeback)
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

  describe "candidate purchase lookup" do
    let(:user) { create(:user, email: buyer_email) }

    def candidate_purchases_for(user)
      described_class.new(user_external_id: user.external_id).send(:candidate_purchases)
    end

    def purchase_queries(&block)
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?("FROM `purchases`") }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
      queries
    end

    it "reads the account and guest halves in one statement instead of with an OR" do
      queries = purchase_queries { candidate_purchases_for(user) }

      expect(queries.size).to eq(1)
      expect(queries.first).to include("UNION ALL")
      expect(queries.first).not_to match(/purchaser_id`? = '?\d+'? OR\b/i)
    end

    it "keeps the newest rows across both halves, up to the limit" do
      stub_const("Purchase::Blockable::MAX_SIBLING_PURCHASES_FOR_UNBLOCK", 3)
      account_older = create(:purchase, purchaser: user, email: "checkout@example.com")
      guest_newer = create(:purchase, email: buyer_email)
      account_newest = create(:purchase, purchaser: user, email: "checkout@example.com")
      create(:purchase, email: buyer_email, purchaser: create(:user))

      newest_three = (history + [failed_purchase, account_older, guest_newer, account_newest]).max_by(3, &:id)
      expect(candidate_purchases_for(user)).to eq(newest_three)
    end

    it "does not treat a missing account email as a match for email-less guest rows" do
      user.update_column(:email, nil)
      emailless_guest = create(:purchase)
      emailless_guest.update_columns(email: nil, purchaser_id: nil)

      expect(candidate_purchases_for(user)).not_to include(emailless_guest)
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
  end

  describe "cross-type value matching for GUID/IP enforcement" do
    # Checkout enforcement (Purchase::Risk#check_for_past_blocked_guids/#check_for_past_fraudulent_ips)
    # and DecliningPlatformBlocks both match GUID/IP values by object_value alone, so a row stored
    # under an unexpected object_type still declines checkout. Recovery has to see it too.
    it "resolves and clears a browser_guid value stored under a different object_type" do
      guid_block.unblock!
      mistyped_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: browser_guid)

      result = call
      expect(result.verdict).to eq(:cleared)
      expect(result.cleared).to include(mistyped_block)
      expect(mistyped_block.reload.blocked_at).to be_nil
    end

    it "resolves an IP value stored under a different object_type, still withheld for human review" do
      ip = "203.0.113.9"
      failed_purchase.update!(ip_address: ip, error_code: PurchaseErrorCode::BLOCKED_IP_ADDRESS)
      mistyped_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: ip)

      result = call
      expect(mistyped_block.reload.blocked_at).to be_present
      expect(result.skipped.map(&:first)).to include(mistyped_block)
    end
  end

  it "requires an identifier" do
    expect { described_class.call }.to raise_error(ArgumentError)
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

  # Checkout also declines on the account IPs of every address on the row
  # (Purchase::Risk#check_for_past_fraudulent_ips). Recovery reports those as withheld — never
  # clearable, never part of the gates — so a buyer still held there is not told to retry.
  describe "account IPs checkout matches" do
    let(:account_ip) { "203.0.113.77" }
    let(:clean_request_ip) { "192.0.2.50" }
    let!(:buyer_account) { create(:user, email: buyer_email, current_sign_in_ip: nil, last_sign_in_ip: account_ip, account_created_ip: nil) }

    before do
      failed_purchase.update!(ip_address: clean_request_ip, error_code: PurchaseErrorCode::BLOCKED_IP_ADDRESS)
    end

    def block_account_ip(value = account_ip, object_type: :ip_address)
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[object_type], object_value: value, expires_in: 6.months)
    end

    it "reports a sole account-IP hold instead of no_active_blocks, and sends no retry mail" do
      guid_block.unblock!
      email_block.unblock!
      ip_block = block_account_ip

      result = nil
      expect { result = call }.to not_have_enqueued_mail(CustomerLowPriorityMailer, :blocked_purchase_resolved)

      expect(result.verdict).to eq(:noop)
      expect(result.reason).to eq(:nothing_clearable)
      expect(result.cleared).to be_empty
      expect(result.skipped).to contain_exactly([ip_block, :shared_identifier_needs_human_review])
      expect(ip_block.reload.blocked_at).to be_present
    end

    it "clears exactly the same rows on a mixed hold, reports the account IP, and sends no resolved mail" do
      ip_block = block_account_ip

      result = nil
      expect { result = call }.to not_have_enqueued_mail(CustomerLowPriorityMailer, :blocked_purchase_resolved)

      expect(result.verdict).to eq(:cleared)
      expect(result.cleared).to contain_exactly(guid_block, email_block)
      expect(result.skipped).to contain_exactly([ip_block, :shared_identifier_needs_human_review])
      expect(ip_block.reload.blocked_at).to be_present
      expect(guid_block.reload.blocked_at).to be_nil
    end

    %i[current_sign_in_ip last_sign_in_ip account_created_ip].each do |column|
      it "finds a hold on the account's #{column}" do
        buyer_account.update!(column => "203.0.113.#{column.length}")
        ip_block = block_account_ip(buyer_account.public_send(column))

        expect(call.skipped).to include([ip_block, :shared_identifier_needs_human_review])
      end
    end

    it "keeps an account IP stored under an unexpected object_type withheld" do
      mistyped = block_account_ip(object_type: :browser_guid)

      result = call

      expect(result.cleared).to contain_exactly(guid_block, email_block)
      expect(result.skipped).to include([mistyped, :shared_identifier_needs_human_review])
      expect(mistyped.reload.blocked_at).to be_present
    end

    it "ignores an expired account-IP block and still emails the recovered buyer" do
      block_account_ip.update!(expires_at: 1.minute.ago)

      result = nil
      expect { result = call }.to have_enqueued_mail(CustomerLowPriorityMailer, :blocked_purchase_resolved).with(failed_purchase.id)

      expect(result.skipped).to be_empty
    end

    it "does not report the seller's own IP, which checkout never declines the buyer on" do
      seller_ip = "198.51.100.40"
      failed_purchase.seller.update!(current_sign_in_ip: seller_ip)
      block_account_ip(seller_ip)

      expect(call.skipped).to be_empty
    end

    it "reports an address the buyer's account shares with the seller" do
      failed_purchase.seller.update!(current_sign_in_ip: account_ip)
      ip_block = block_account_ip

      expect(call.skipped).to include([ip_block, :shared_identifier_needs_human_review])
    end

    # A typed gifter/PayPal address explains why checkout declined, but it is not the buyer's
    # identity: its account IP is reported, and nothing of that person's becomes clearable.
    it "reports a typed third-party address's account IP without clearing anything of theirs" do
      third_party = create(:user, email: "gift-recipient-owner@example.net", current_sign_in_ip: "203.0.113.200",
                                  last_sign_in_ip: nil, account_created_ip: nil)
      failed_purchase.update!(is_gift_sender_purchase: true)
      create(:gift, gifter_purchase: failed_purchase, gifter_email: third_party.email)
      third_party_ip_block = block_account_ip(third_party.current_sign_in_ip)
      third_party_email_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: third_party.email)

      result = nil
      expect { result = call }.to not_have_enqueued_mail(CustomerLowPriorityMailer, :blocked_purchase_resolved)

      expect(result.cleared).to contain_exactly(guid_block, email_block)
      expect(result.skipped).to contain_exactly([third_party_ip_block, :shared_identifier_needs_human_review])
      expect(third_party_email_block.reload.blocked_at).to be_present
      expect(third_party_ip_block.reload.blocked_at).to be_present
    end

    it "reports a PayPal address's account IP from the blocked checkout" do
      paypal_owner = create(:user, email: "wallet-owner@example.net", current_sign_in_ip: "203.0.113.201",
                                   last_sign_in_ip: nil, account_created_ip: nil)
      failed_purchase.update_columns(charge_processor_id: PaypalChargeProcessor.charge_processor_id, card_visual: paypal_owner.email)
      ip_block = block_account_ip(paypal_owner.current_sign_in_ip)

      expect(call.skipped).to include([ip_block, :shared_identifier_needs_human_review])
    end

    describe "an account-IP value that also matches a known block" do
      # A browser guid is client-supplied, so a proven guid can carry an IP string. Checkout still
      # declines on that row by IP value, so it stays withheld whatever type it is stored under.
      it "withholds a browser_guid row whose value is an account IP, clearing nothing else new" do
        failed_purchase.update!(browser_guid: account_ip)
        overlap = block_account_ip(object_type: :browser_guid)

        result = nil
        expect { result = call }.to not_have_enqueued_mail(CustomerLowPriorityMailer, :blocked_purchase_resolved)

        expect(result.verdict).to eq(:cleared)
        expect(result.cleared).to contain_exactly(email_block)
        expect(result.skipped).to contain_exactly([overlap, :shared_identifier_needs_human_review])
        expect(overlap.reload.blocked_at).to be_present
        expect(guid_block.reload.blocked_at).to be_present
      end

      it "keeps an authored overlapping row as authored, listed once" do
        failed_purchase.update!(browser_guid: account_ip)
        overlap = block_account_ip(object_type: :browser_guid)
        overlap.update!(blocked_by: create(:admin_user).id)

        result = nil
        expect { result = call }.not_to change { PlatformBlock.active.count }

        expect(result.verdict).to eq(:escalate)
        expect(result.reason).to eq(:authored_block)
        expect(result.skipped).to contain_exactly([overlap, :authored])
      end

      it "lists a request-IP row that is also an account IP once" do
        failed_purchase.update!(ip_address: account_ip)
        ip_block = block_account_ip

        result = call

        expect(result.cleared).to contain_exactly(guid_block, email_block)
        expect(result.skipped).to contain_exactly([ip_block, :shared_identifier_needs_human_review])
      end
    end

    describe "existing gates still decide the verdict" do
      it "escalates an authored block and still names the account-IP hold" do
        email_block.update!(blocked_by: create(:admin_user).id)
        ip_block = block_account_ip

        result = nil
        expect { result = call }.not_to change { PlatformBlock.active.count }

        expect(result.verdict).to eq(:escalate)
        expect(result.reason).to eq(:authored_block)
        expect(result.skipped).to contain_exactly([email_block, :authored], [ip_block, :shared_identifier_needs_human_review])
      end

      it "does not treat an authored account-IP hold as an authored block about this buyer" do
        ip_block = block_account_ip
        ip_block.update!(blocked_by: create(:admin_user).id)

        result = call

        expect(result.verdict).to eq(:cleared)
        expect(result.cleared).to contain_exactly(guid_block, email_block)
        expect(result.skipped).to contain_exactly([ip_block, :shared_identifier_needs_human_review])
      end

      it "skips on missing clean history even when only an account IP holds the buyer" do
        guid_block.unblock!
        email_block.unblock!
        history.each { |purchase| purchase.update!(chargeback_date: 1.month.ago) }
        ip_block = block_account_ip

        result = call

        expect(result.verdict).to eq(:skip)
        expect(result.reason).to eq(:no_clean_payment_history)
        expect(result.skipped).to contain_exactly([ip_block, :shared_identifier_needs_human_review])
      end

      it "skips on an unreversed chargeback and still names the account-IP hold" do
        create(:purchase, email: buyer_email, stripe_fingerprint: "other-card", chargeback_date: 1.week.ago, created_at: 3.months.ago)
        ip_block = block_account_ip

        result = nil
        expect { result = call }.not_to change { PlatformBlock.active.count }

        expect(result.reason).to eq(:unreversed_chargeback)
        expect(result.skipped).to contain_exactly([ip_block, :shared_identifier_needs_human_review])
      end

      it "skips while a velocity rule still fires and still names the account-IP hold" do
        Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS.times do |index|
          create(:purchase, email: buyer_email, browser_guid:, purchase_state: "failed", stripe_fingerprint: "tester-#{index}",
                            charge_processor_id: StripeChargeProcessor.charge_processor_id, created_at: 1.day.ago)
        end
        ip_block = block_account_ip

        result = nil
        expect { result = call }.not_to change { PlatformBlock.active.count }

        expect(result.reason).to eq(:velocity_rule_still_firing)
        expect(result.skipped).to contain_exactly([ip_block, :shared_identifier_needs_human_review])
      end
    end
  end

  # An IP-blocked checkout never reaches the processor, so its row has no fingerprint and nothing
  # corroborates it. Its typed addresses still decide which accounts checkout reads IPs from.
  describe "account IPs reached from a fingerprintless guest failure" do
    let(:wallet_owner) do
      create(:user, email: "wallet-owner@example.net", current_sign_in_ip: "203.0.113.150", last_sign_in_ip: nil, account_created_ip: nil)
    end
    let!(:wallet_owner_ip_block) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: wallet_owner.current_sign_in_ip, expires_in: 6.months)
    end
    let!(:wallet_owner_email_block) { PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: wallet_owner.email) }

    def fingerprintless_ip_failure(**attrs)
      create(:purchase, email: buyer_email, purchase_state: "failed", error_code: PurchaseErrorCode::BLOCKED_IP_ADDRESS,
                        ip_address: "192.0.2.51", browser_guid: "guid-uncorroborated", stripe_fingerprint: nil,
                        stripe_transaction_id: nil, merchant_account: nil, created_at: 1.hour.ago, **attrs)
    end

    it "reports the PayPal owner's account IP for a sole hold, clearing nothing" do
      guid_block.unblock!
      email_block.unblock!
      fingerprintless_ip_failure(charge_processor_id: PaypalChargeProcessor.charge_processor_id, card_visual: wallet_owner.email)

      result = nil
      expect { result = call }.to not_change { PlatformBlock.active.count }
        .and not_have_enqueued_mail(CustomerLowPriorityMailer, :blocked_purchase_resolved)

      expect(result.verdict).to eq(:noop)
      expect(result.reason).to eq(:nothing_clearable)
      expect(result.skipped).to contain_exactly([wallet_owner_ip_block, :shared_identifier_needs_human_review])
    end

    it "reports a gifter's account IP and clears exactly the buyer's own rows" do
      failure = fingerprintless_ip_failure(is_gift_sender_purchase: true)
      create(:gift, gifter_purchase: failure, gifter_email: wallet_owner.email)

      result = nil
      expect { result = call }.to not_have_enqueued_mail(CustomerLowPriorityMailer, :blocked_purchase_resolved)

      expect(result.cleared).to contain_exactly(guid_block, email_block)
      expect(result.skipped).to contain_exactly([wallet_owner_ip_block, :shared_identifier_needs_human_review])
      expect(wallet_owner_email_block.reload.blocked_at).to be_present
    end
  end

  # Free purchases and renewals skip the IP check (Purchase::Risk#check_for_past_fraudulent_ips), so a
  # buyer whose only blocked attempts were exempt is not held by an account IP once the rest clears.
  describe "account IPs behind blocked checkouts that skip the IP check" do
    let(:account_ip) { "203.0.113.90" }
    let!(:buyer_account) { create(:user, email: buyer_email, current_sign_in_ip: account_ip, last_sign_in_ip: nil, account_created_ip: nil) }
    let!(:account_ip_block) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: account_ip, expires_in: 6.months)
    end

    before do
      # The paid failure becomes an ordinary decline, so only the exempt attempt below hit a block.
      failed_purchase.update!(error_code: nil)
    end

    # Written after create, since the purchase's own before_create checks would reject or re-code the
    # row: a free row on a paid product fails as price_cents_too_low, and a paid row needs a
    # fingerprint, which a checkout blocked before the charge never gets.
    def blocked(purchase, guid: browser_guid)
      purchase.tap do
        _1.update_columns(browser_guid: guid, stripe_fingerprint: nil, purchase_state: "failed", error_code: PurchaseErrorCode::BLOCKED_BROWSER_GUID)
      end
    end

    def free_guid_failure(guid: browser_guid)
      blocked(create(:free_purchase, email: buyer_email, purchaser: buyer_account, created_at: 1.hour.ago), guid:)
    end

    # Paid, so the renewal is exempt only as a recurring charge, not also as a free purchase.
    def renewal_guid_failure
      product = create(:membership_product_with_preset_tiered_pricing)
      tier = product.tier_category.variants.first
      original = create(:membership_purchase, link: product, tier:, price_cents: 300, email: buyer_email, created_at: 3.months.ago)
      blocked(create(:purchase, link: product, subscription: original.subscription, variant_attributes: [tier], price_cents: 300,
                                email: buyer_email, purchaser: buyer_account, created_at: 1.hour.ago))
    end

    [["a free purchase", :free_guid_failure], ["a real renewal", :renewal_guid_failure]].each do |label, builder|
      [["active", -> { }], ["expired", -> { account_ip_block.update!(expires_at: 1.minute.ago) }]].each do |state, setup|
        it "recovers a buyer whose only blocked attempt was #{label}, with the account-IP block #{state}" do
          instance_exec(&setup)
          failure = send(builder)
          expect(failure.free_purchase?).to be(builder == :free_guid_failure)
          expect(failure.is_recurring_subscription_charge).to be(builder == :renewal_guid_failure)

          result = nil
          expect { result = call }.to have_enqueued_mail(CustomerLowPriorityMailer, :blocked_purchase_resolved).with(failure.id)

          expect(result.verdict).to eq(:cleared)
          expect(result.cleared).to contain_exactly(guid_block, email_block)
          expect(result.skipped).to be_empty
          expect(account_ip_block.reload.blocked_at).to be_present
        end
      end
    end

    it "still reports the account IP when a paid blocked checkout ran the IP check alongside an exempt one" do
      failed_purchase.update!(error_code: PurchaseErrorCode::BLOCKED_IP_ADDRESS, ip_address: "192.0.2.53")
      free_guid_failure

      result = nil
      expect { result = call }.to not_have_enqueued_mail(CustomerLowPriorityMailer, :blocked_purchase_resolved)

      expect(result.cleared).to contain_exactly(guid_block, email_block)
      expect(result.skipped).to contain_exactly([account_ip_block, :shared_identifier_needs_human_review])
    end

    # Classification is not scoped to IP-checked attempts. The guid check runs on free purchases and
    # matches any row by value, so when the exempt attempt's guid equals the account IP, both rows on
    # that value still hold its retry and stay withheld.
    it "keeps rows valued as the account IP withheld when an exempt attempt's guid carries that value" do
      free_guid_failure(guid: account_ip)
      overlap = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: account_ip)

      result = nil
      expect { result = call }.to not_have_enqueued_mail(CustomerLowPriorityMailer, :blocked_purchase_resolved)

      expect(result.cleared).to contain_exactly(guid_block, email_block)
      expect(result.skipped).to contain_exactly([overlap, :shared_identifier_needs_human_review],
                                                [account_ip_block, :shared_identifier_needs_human_review])
      expect(overlap.reload.blocked_at).to be_present
    end
  end
end
