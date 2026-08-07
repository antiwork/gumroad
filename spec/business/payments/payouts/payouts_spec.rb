# frozen_string_literal: true

require "spec_helper"

describe Payouts do
  # A wording the broad "can this seller see an explanation of a terminal PayPal block" check
  # recognises. It matches any note containing one of the seller-facing rejection reasons, current or
  # historical, so this is one example of that shape rather than the only string that works.
  #
  # Deliberately NOT the explanation of any particular rejection: the date is not one a real note
  # carries, which is what the narrower "is this the explanation of THIS rejection" check keys on.
  # Use seller_blocked_by_paypal_reading_the_explanation when the seller has to be reading the
  # genuine explanation of the rejection blocking them.
  def terminal_paypal_explanation_note_content
    "Your payout on July 1st, 2026 could not be sent because " \
      "#{Payment::FailureReason::TERMINAL_PAYPAL_FAILURE_SELLER_REASONS.fetch("PAYPAL 3148")}. " \
      "Add a bank account in your payout settings."
  end

  # A seller under a live terminal PayPal rejection — no bank account, no Stripe Connect route, and
  # a failed payout to the address on file — who is currently reading the explanation of it.
  #
  # The note is generated from the rejection itself rather than hand-written, because the payout walk
  # decides whether the seller still needs telling by asking whether the note on their page explains
  # that specific rejection (its payout date plus its restriction). A hand-typed date would make this
  # seller look unexplained and every example built on it would silently exercise the restore path.
  def seller_blocked_by_paypal_reading_the_explanation
    seller = create(:compliant_user, payment_address: "stuck@example.com")
    create(:user_compliance_info, user: seller)
    create(:balance, user: seller, amount_cents: 100_00, date: Date.today - 3)
    rejection = create(:payment_failed, user: seller, payment_address: "stuck@example.com",
                                        failure_reason: "PAYPAL 3148", txn_id: nil, processor_fee_cents: nil)
    seller.add_payout_note(content: rejection.terminal_paypal_failure_seller_note, seller_visible: true)
    seller
  end

  describe "is_user_payable" do
    let(:payout_date) { Date.today - 1 }

    it "returns false for creators with paused payouts" do
      creator = create(:user, payment_address: "payme@example.com", payouts_paused_internally: true)
      create(:balance, user: creator, amount_cents: 100_001, date: 3.days.ago)

      expect(described_class.is_user_payable(creator, payout_date)).to be(false)
    end

    describe "risk state" do
      def expect_processors_not_called
        PayoutProcessorType.all.each do |payout_processor_type|
          expect(PayoutProcessorType.get(payout_processor_type)).not_to receive(:is_user_payable)
        end
      end

      it "returns false for creators suspended for TOS violation" do
        expect_processors_not_called
        creator = create(:user, payment_address: "payme@example.com", user_risk_state: "suspended_for_tos_violation")
        create(:balance, user: creator, amount_cents: 100_001, date: Date.today - 3)

        expect(described_class.is_user_payable(creator, payout_date)).to be(false)
      end

      it "returns false for creators suspended for fraud" do
        expect_processors_not_called
        creator = create(:user, payment_address: "payme@example.com", user_risk_state: "suspended_for_fraud")
        create(:balance, user: creator, amount_cents: 100_001, date: Date.today - 3)

        expect(described_class.is_user_payable(creator, payout_date)).to be(false)
      end

      it "returns true for creators that are compliant" do
        creator = create(:singaporean_user_with_compliance_info, payment_address: "payme@example.com", user_risk_state: "compliant")
        create(:balance, user: creator, amount_cents: 100_001, date: Date.today - 3)

        expect(described_class.is_user_payable(creator, payout_date)).to be(true)
      end

      it "returns true for compliant creators who have a PayPal account connected", :vcr do
        creator = create(:singaporean_user_with_compliance_info, payment_address: "", user_risk_state: "compliant")
        create(:merchant_account_paypal, user: creator, charge_processor_merchant_id: "B66YJBBNCRW6L")
        create(:balance, user: creator, amount_cents: 100_001, date: Date.today - 3)

        expect(described_class.is_user_payable(creator, payout_date)).to be(true)
      end

      it "returns false for accounts not reviewed" do
        expect_processors_not_called
        creator = create(:user, payment_address: "payme@example.com", user_risk_state: "not_reviewed")
        create(:balance, user: creator, amount_cents: 100_001, date: Date.today - 3)

        expect(described_class.is_user_payable(creator, payout_date)).to be(false)
      end

      it "returns false for accounts on probation" do
        expect_processors_not_called
        creator = create(:user, payment_address: "payme@example.com", user_risk_state: "on_probation")
        create(:balance, user: creator, amount_cents: 100_001, date: Date.today - 3)

        expect(described_class.is_user_payable(creator, payout_date)).to be(false)
      end

      it "returns false for accounts flagged for terms violation" do
        expect_processors_not_called
        creator = create(:user, payment_address: "payme@example.com", user_risk_state: "flagged_for_tos_violation")
        create(:balance, user: creator, amount_cents: 100_001, date: Date.today - 3)

        expect(described_class.is_user_payable(creator, payout_date)).to be(false)
      end

      it "returns false for accounts flagged for fraud" do
        expect_processors_not_called
        creator = create(:user, payment_address: "payme@example.com", user_risk_state: "flagged_for_fraud")
        create(:balance, user: creator, amount_cents: 100_001, date: Date.today - 3)

        expect(described_class.is_user_payable(creator, payout_date)).to be(false)
      end

      describe "non-compliant user from admin" do
        let(:payout_date) { Date.today }
        let(:user) { create(:tos_user, payment_address: "bob1@example.com") }

        before do
          create(:balance, user: user, amount_cents: 100_01, date: payout_date - 3)
          create(:user_compliance_info, user:)
        end

        it "returns true" do
          expect(described_class.is_user_payable(user, payout_date, from_admin: true)).to eq(true)
        end
      end
    end

    describe "unpaid balance" do
      let(:payout_date) { Date.today }
      let(:u1) { create(:singaporean_user_with_compliance_info, user_risk_state: "compliant", payment_address: "bob1@example.com") }
      let(:u1b1) { create(:balance, user: u1, amount_cents: 49_99, date: payout_date - 3) }
      let(:u1b2) { create(:balance, user: u1, amount_cents: 50_01, date: payout_date - 2) }

      describe "enough money in balance to meet minimum" do
        before { u1b1 && u1b2 }

        it "considers the user payable" do
          expect(described_class.is_user_payable(u1, payout_date)).to eq(true)
        end
      end

      describe "not enough money in balance to meet minimum" do
        before { u1b1 }

        describe "no other paid balances for the same payout date" do
          it "considers the user NOT payable" do
            expect(described_class.is_user_payable(u1, payout_date)).to eq(false)
          end
        end

        describe "paid balances for the same payout date" do
          let(:u1p1) { create(:payment_completed, user: u1, payout_period_end_date: payout_date, amount_cents: 50_01) }

          before { u1b1 && u1p1 }

          it "considers the user payable" do
            expect(described_class.is_user_payable(u1, payout_date)).to eq(true)
          end
        end

        describe "returned balances for the same payout date" do
          let(:u1p1) { create(:payment_returned, user: u1, payout_period_end_date: payout_date, amount_cents: 50_01) }

          before { u1p1 }

          it "considers the user NOT payable" do
            expect(described_class.is_user_payable(u1, payout_date)).to eq(false)
          end
        end
      end
    end

    describe "below the minimum payout amount held by a processor" do
      let(:payout_date) { Date.today }
      let(:seller) { create(:singaporean_user_with_compliance_info, user_risk_state: "compliant", payment_address: "bob1@example.com") }

      before do
        create(:balance, user: seller, amount_cents: 50_00, date: payout_date - 2)
        allow(PaypalPayoutProcessor).to receive(:is_user_payable).and_return(true)
        allow(StripePayoutProcessor).to receive(:is_user_payable).and_return(true)
        allow_any_instance_of(User).to receive(:unpaid_balance_cents_up_to_date_held_by_gumroad).and_return(0)
      end

      it "considers the user NOT payable from admin without bypass_minimum_payout" do
        expect(described_class.is_user_payable(seller, payout_date, from_admin: true)).to eq(false)
      end

      it "considers the user payable from admin with bypass_minimum_payout" do
        expect(described_class.is_user_payable(seller, payout_date, from_admin: true, bypass_minimum_payout: true)).to eq(true)
      end

      it "ignores bypass_minimum_payout when the request is not from admin" do
        expect(described_class.is_user_payable(seller, payout_date, bypass_minimum_payout: true)).to eq(false)
      end

      it "does not add a skipped-below-minimum note when the payout is forced from admin" do
        expect do
          described_class.is_user_payable(seller, payout_date, from_admin: true, bypass_minimum_payout: true, add_comment: true)
        end.not_to change { seller.comments.with_type_payout_note.count }
      end

      it "still rejects a forced payout when the balance is not positive" do
        allow_any_instance_of(User).to receive(:unpaid_balance_cents_up_to_date).and_return(0)
        allow_any_instance_of(User).to receive(:paid_payments_cents_for_date).and_return(0)
        expect(described_class.is_user_payable(seller, payout_date, from_admin: true, bypass_minimum_payout: true)).to eq(false)
      end
    end

    describe "instant payouts" do
      let(:seller) { create(:compliant_user) }

      before do
        allow(StripePayoutProcessor).to receive(:is_user_payable).and_return(true)
        create(:balance, user: seller, amount_cents: 100_00, date: payout_date - 3)
      end

      it "returns true when instant payouts are supported and the user has an eligible balance" do
        allow_any_instance_of(User).to receive(:instant_payouts_supported?).and_return(true)
        expect(described_class.is_user_payable(seller, payout_date, payout_type: Payouts::PAYOUT_TYPE_INSTANT)).to be(true)
      end

      it "returns false when instant payouts are not supported" do
        allow_any_instance_of(User).to receive(:instant_payouts_supported?).and_return(false)
        expect(described_class.is_user_payable(seller, payout_date, payout_type: Payouts::PAYOUT_TYPE_INSTANT)).to be(false)
      end

      it "calls the stripe payout processor with only the instantly payable balance amount" do
        allow_any_instance_of(User).to receive(:instant_payouts_supported?).and_return(true)
        allow_any_instance_of(User).to receive(:instantly_payable_unpaid_balance_cents_up_to_date).and_return(100_00)
        allow_any_instance_of(User).to receive(:unpaid_balance_cents_up_to_date).and_return(200_00)
        expect(StripePayoutProcessor).to receive(:is_user_payable).with(seller, 100_00, add_comment: false, from_admin: false, payout_type: anything)
        described_class.is_user_payable(seller, payout_date, payout_type: Payouts::PAYOUT_TYPE_INSTANT)
      end

      it "shows the ineligible-for-instant-payouts note to a seller with nothing else to read" do
        allow_any_instance_of(User).to receive(:instant_payouts_supported?).and_return(false)

        described_class.is_user_payable(seller, payout_date, payout_type: Payouts::PAYOUT_TYPE_INSTANT, add_comment: true)

        expect(PayoutNoteVisibility.seller_visible?(seller.comments.with_type_payout_note.last)).to eq(true)
      end

      # This note repeats on every daily run, so for a seller whose PayPal account can never receive
      # the money it would bury the one note telling them why — the same burial the weekly pause
      # note is suppressed for. Instant payouts are not what stopped their money.
      it "does not let the ineligible-for-instant-payouts note bury a terminal PayPal explanation" do
        allow_any_instance_of(User).to receive(:instant_payouts_supported?).and_return(false)
        blocked_seller = seller_blocked_by_paypal_reading_the_explanation

        described_class.is_user_payable(blocked_seller, payout_date, payout_type: Payouts::PAYOUT_TYPE_INSTANT, add_comment: true)

        skipped_note = blocked_seller.comments.with_type_payout_note.last
        expect(skipped_note.content).to include("not eligible for instant payouts")
        expect(PayoutNoteVisibility.seller_visible?(skipped_note)).to eq(false)
        expect(blocked_seller.reload.latest_seller_visible_payout_note.content)
          .to include("payments cannot be received in the country on that account's address")
      end

      # Every daily run adds a row whether or not the seller sees it, and the note lookups only scan
      # back 25 notes — so repeating the hidden note would push the explanation out of that window,
      # at which point this note would go back to being written visible and re-bury the explanation
      # the suppression exists to protect.
      it "does not write a second hidden ineligible-for-instant-payouts note on the next run" do
        allow_any_instance_of(User).to receive(:instant_payouts_supported?).and_return(false)
        blocked_seller = seller_blocked_by_paypal_reading_the_explanation

        described_class.is_user_payable(blocked_seller, payout_date, payout_type: Payouts::PAYOUT_TYPE_INSTANT, add_comment: true)

        expect do
          described_class.is_user_payable(blocked_seller, payout_date, payout_type: Payouts::PAYOUT_TYPE_INSTANT, add_comment: true)
        end.to_not change { blocked_seller.comments.with_type_payout_note.count }

        expect(blocked_seller.reload.latest_seller_visible_payout_note.content)
          .to include("payments cannot be received in the country on that account's address")
      end

      # A seller who has since fixed their PayPal account still carries the old explanation as their
      # newest visible note. Hiding today's note from them would leave that stale explanation as the
      # only thing they can read, so the suppression is tied to the live block, not to the wording.
      it "shows the ineligible-for-instant-payouts note when the PayPal block is no longer live" do
        allow_any_instance_of(User).to receive(:instant_payouts_supported?).and_return(false)
        recovered_seller = create(:compliant_user)
        create(:ach_account, user: recovered_seller)
        create(:balance, user: recovered_seller, amount_cents: 100_00, date: payout_date - 3)
        recovered_seller.add_payout_note(content: terminal_paypal_explanation_note_content, seller_visible: true)

        described_class.is_user_payable(recovered_seller, payout_date, payout_type: Payouts::PAYOUT_TYPE_INSTANT, add_comment: true)

        skipped_note = recovered_seller.comments.with_type_payout_note.last
        expect(skipped_note.content).to include("not eligible for instant payouts")
        expect(PayoutNoteVisibility.seller_visible?(skipped_note)).to eq(true)
      end
    end

    describe "sellers under 18" do
      let(:payout_date) { Date.today }

      # A US seller who is 15 today, with enough balance and a working payout route, so the ONLY
      # thing that can make them unpayable is the legal-guardian requirement. Age comes from the
      # birthday because that is what the requirement reads; a fixed date would age out of the
      # 13-17 window and quietly turn every example here into an adult-seller example.
      def minor_seller(country: "United States", guardian: nil)
        seller = create(:compliant_user, payment_address: "minor@example.com")
        create(:balance, user: seller, amount_cents: 200_00, date: payout_date - 3)
        create(:user_compliance_info, user: seller, country:, birthday: 15.years.ago.to_date, guardian:)
        seller
      end

      it "does not pay out a minor with no guardian" do
        seller = minor_seller

        expect(described_class.is_user_payable(seller, payout_date)).to be(false)
      end

      it "pays out a minor whose guardian details are complete" do
        seller = create(:compliant_user, payment_address: "minor@example.com")
        create(:balance, user: seller, amount_cents: 200_00, date: payout_date - 3)
        guardian = create(:guardian, user: seller)
        create(:user_compliance_info, user: seller, birthday: 15.years.ago.to_date, guardian:)

        expect(described_class.is_user_payable(seller, payout_date)).to be(true)
      end

      # The distinction the whole gate turns on: a guardian ROW is not a satisfied requirement. An
      # incomplete guardian is exactly the state our payment partner refuses to verify, so treating
      # its presence as enough would pay out against an account that is still unverified.
      it "does not pay out a minor whose guardian is missing their tax identifier" do
        seller = create(:compliant_user, payment_address: "minor@example.com")
        create(:balance, user: seller, amount_cents: 200_00, date: payout_date - 3)
        guardian = create(:guardian, user: seller, individual_tax_id: nil)
        create(:user_compliance_info, user: seller, birthday: 15.years.ago.to_date, guardian:)

        expect(described_class.is_user_payable(seller, payout_date)).to be(false)
      end

      it "does not pay out a minor whose guardian has not accepted our payment partner's terms" do
        seller = create(:compliant_user, payment_address: "minor@example.com")
        create(:balance, user: seller, amount_cents: 200_00, date: payout_date - 3)
        guardian = create(:guardian, user: seller, stripe_tos_accepted: false, stripe_tos_accepted_at: nil, stripe_tos_ip: nil)
        create(:user_compliance_info, user: seller, birthday: 15.years.ago.to_date, guardian:)

        expect(described_class.is_user_payable(seller, payout_date)).to be(false)
      end

      it "does not pay out a minor in a country with no guardian path, even with a complete guardian" do
        seller = create(:compliant_user, payment_address: "minor@example.com")
        create(:balance, user: seller, amount_cents: 200_00, date: payout_date - 3)
        guardian = create(:guardian, user: seller)
        create(:user_compliance_info, user: seller, country: "Brazil", state: "SP", zip_code: "01000-000",
                                      birthday: 15.years.ago.to_date, guardian:)

        expect(described_class.is_user_payable(seller, payout_date)).to be(false)
      end

      it "pays out an adult seller with no guardian" do
        seller = create(:compliant_user, payment_address: "adult@example.com")
        create(:balance, user: seller, amount_cents: 200_00, date: payout_date - 3)
        create(:user_compliance_info, user: seller, birthday: 30.years.ago.to_date)

        expect(described_class.is_user_payable(seller, payout_date)).to be(true)
      end

      # Support releasing a balance by hand has already made this judgement, the same as every other
      # gate in this method.
      it "pays out a minor with no guardian when the payout comes from admin" do
        seller = minor_seller

        expect(described_class.is_user_payable(seller, payout_date, from_admin: true)).to be(true)
      end

      # There is no Gumroad-managed account for a guardian to go on, the payout settings page offers
      # these sellers no form, and Stripe verifies the account under its own agreement with them. So
      # blocking here would strand them with nothing to do — the one outcome this gate must not
      # cause, and the reason the presenter exempts the same sellers.
      it "pays out a minor with no guardian who is paid through their own connected Stripe account" do
        seller = minor_seller
        allow(seller).to receive(:has_stripe_account_connected?).and_return(true)
        allow(seller).to receive(:stripe_connect_account).and_return(
          double(is_a_brazilian_stripe_connect_account?: false)
        )

        expect(described_class.is_user_payable(seller, payout_date)).to be(true)
      end

      # The guardian gate sits ahead of the others, so folding the seller's OWN details into it
      # would blame the guardian for a missing tax id and, because the note does not repeat,
      # permanently withhold the one naming the field they are actually missing.
      it "does not blame the guardian when the seller's own details are what is incomplete" do
        seller = create(:compliant_user, payment_address: "minor@example.com")
        create(:balance, user: seller, amount_cents: 200_00, date: payout_date - 3)
        guardian = create(:guardian, user: seller)
        compliance_info = create(:user_compliance_info, user: seller, birthday: 15.years.ago.to_date, guardian:)
        compliance_info.update_columns(individual_tax_id: nil)

        described_class.is_user_payable(seller.reload, payout_date, add_comment: true)

        expect(seller.comments.with_type_payout_note.last&.content.to_s)
          .not_to include("sellers under 18 need a legal guardian")
      end

      describe "the note the seller reads" do
        it "tells a minor to add a guardian, visibly" do
          seller = minor_seller

          described_class.is_user_payable(seller, payout_date, add_comment: true)

          note = seller.comments.with_type_payout_note.last
          expect(note.content).to include("sellers under 18 need a legal guardian")
          expect(note.content).to include("Add your guardian's details in your payout settings")
          expect(PayoutNoteVisibility.seller_visible?(note)).to be(true)
        end

        it "tells a minor with no guardian path that payouts start at 18, and does not ask for a guardian" do
          seller = minor_seller(country: "Brazil")

          described_class.is_user_payable(seller, payout_date, add_comment: true)

          note = seller.comments.with_type_payout_note.last
          expect(note.content).to include("cannot verify a seller under 18 in your country")
          expect(note.content).to include("Payouts will start once you turn 18")
          expect(note.content).not_to include("Add your guardian's details")
          expect(PayoutNoteVisibility.seller_visible?(note)).to be(true)
        end

        it "writes no note when add_comment is false" do
          seller = minor_seller

          expect do
            described_class.is_user_payable(seller, payout_date, add_comment: false)
          end.not_to change { seller.comments.with_type_payout_note.count }
        end

        # Otherwise a seller on daily payouts buries their own note within a month: the Payouts
        # banner only scans back PayoutNoteVisibility::MAX_NOTES_SCANNED notes, so the one thing
        # telling them what to do scrolls out of the window and the page goes silent.
        it "does not repeat the note on the next payout run" do
          seller = minor_seller

          described_class.is_user_payable(seller, payout_date, add_comment: true)

          expect do
            described_class.is_user_payable(seller, payout_date, add_comment: true)
          end.not_to change { seller.comments.with_type_payout_note.count }
        end

        # The two wordings say different things about what the seller can do, so a stale one must not
        # suppress the other. This is why the dedupe keys on one pattern per wording rather than one
        # pattern covering both.
        it "writes the unsupported-country note over an existing add-a-guardian note" do
          seller = minor_seller

          described_class.is_user_payable(seller, payout_date, add_comment: true)
          seller.alive_user_compliance_info.update_columns(country: "Brazil", state: "SP", zip_code: "01000-000")

          described_class.is_user_payable(seller.reload, payout_date, add_comment: true)

          expect(seller.comments.with_type_payout_note.last.content).to include("cannot verify a seller under 18 in your country")
        end
      end
    end

    describe "instant payouts with settling funds" do
      let(:settling_seller) { create(:compliant_user) }

      before do
        allow(settling_seller).to receive(:instant_payouts_supported?).and_return(true)
        allow(settling_seller).to receive(:instantly_payable_unpaid_balance_cents_up_to_date).and_return(0)
        allow(settling_seller).to receive(:unpaid_balance_cents_up_to_date).and_return(200_00)
      end

      it "returns false and adds a settling funds note when add_comment is true" do
        expect(described_class.is_user_payable(settling_seller, payout_date, payout_type: Payouts::PAYOUT_TYPE_INSTANT, add_comment: true)).to be(false)

        date = Time.current.to_fs(:formatted_date_full_month)
        expect(settling_seller.comments.with_type_payout_note.last.content).to eq(
          "Instant Payout on #{date} was skipped because funds are still settling. This should resolve within 1-2 days."
        )
      end

      it "returns false without adding a note when add_comment is false" do
        expect do
          described_class.is_user_payable(settling_seller, payout_date, payout_type: Payouts::PAYOUT_TYPE_INSTANT, add_comment: false)
        end.not_to change { settling_seller.comments.with_type_payout_note.count }
      end
    end

    describe "payout processor logic" do
      let(:u1) { create(:compliant_user) }

      before do
        create(:balance, user: u1, amount_cents: 49_99, date: payout_date - 2)
        create(:balance, user: u1, amount_cents: 50_01, date: payout_date - 1)
      end

      describe "no payout processor type specified" do
        it "asks all payout processors" do
          expect(PaypalPayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything)
          expect(StripePayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything)
          described_class.is_user_payable(u1, payout_date)
        end

        describe "all processors say no" do
          before do
            allow(PaypalPayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything).and_return(false)
            allow(StripePayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything).and_return(false)
          end

          it "considers the user NOT payable" do
            expect(described_class.is_user_payable(u1, payout_date)).to eq(false)
          end
        end

        describe "one processor says yes, rest say no" do
          before do
            allow(PaypalPayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything).and_return(false)
            allow(StripePayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything).and_return(true)
          end

          it "considers the user payable" do
            expect(described_class.is_user_payable(u1, payout_date)).to eq(true)
          end
        end

        describe "all processors say yes" do
          before do
            allow(PaypalPayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything).and_return(true)
            allow(StripePayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything).and_return(true)
          end

          it "considers the user payable" do
            expect(described_class.is_user_payable(u1, payout_date)).to eq(true)
          end
        end
      end

      describe "a payout processor type specified" do
        let(:payout_processor_type) { PayoutProcessorType::STRIPE }

        it "asks only that payout processors" do
          expect(PaypalPayoutProcessor).to_not receive(:is_user_payable).with(u1, 100_00, add_comment: anything, payout_type: anything)
          expect(StripePayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything)
          described_class.is_user_payable(u1, payout_date, processor_type: payout_processor_type)
        end

        describe "processor says no" do
          before do
            allow(StripePayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything).and_return(false)
          end

          it "considers the user NOT payable" do
            expect(described_class.is_user_payable(u1, payout_date, processor_type: payout_processor_type)).to eq(false)
          end
        end

        describe "processor says yes" do
          before do
            allow(StripePayoutProcessor).to receive(:is_user_payable).with(u1, 100_00, add_comment: false, from_admin: false, payout_type: anything).and_return(true)
          end

          it "considers the user payable" do
            expect(described_class.is_user_payable(u1, payout_date, processor_type: payout_processor_type)).to eq(true)
          end
        end
      end
    end
  end

  describe "create_payments_for_balances_up_to_date" do
    let(:payout_date) { Date.yesterday }
    let(:payout_processor_type) { PayoutProcessorType::PAYPAL }

    it "hands every holding-balance seller to a slice job" do
      create(:user, unpaid_balance_cents: 0)
      u2 = create(:user, unpaid_balance_cents: 1)
      u3 = create(:user, unpaid_balance_cents: 10)
      u4 = create(:user, unpaid_balance_cents: 1000)

      expect(PerformPayoutsForUserSliceWorker).to receive(:perform_in)
        .with(0, payout_processor_type, payout_date.to_s, [u2.id, u3.id, u4.id], nil)

      described_class.create_payments_for_balances_up_to_date(payout_date, payout_processor_type)
    end

    it "fans the cohort out to one job per bounded slice, staggered, instead of walking it inline" do
      # Regression test for gumroad-private#1021 and #1284: checking eligibility for the
      # whole ~195k-seller cohort inside one job took about two hours, which is longer than
      # a worker lives, so the job was recycled and restarted from the beginning until it
      # was buried in the dead set with the cohort unpaid. Each slice must therefore get its
      # own job, so a recycle costs one slice instead of the whole run.
      stub_const("Payouts::USER_LOOKUP_BATCH_SIZE", 2)
      users = create_list(:user, 5, unpaid_balance_cents: 100)

      enqueued_ids = []
      delays = []
      expect(PerformPayoutsForUserSliceWorker).to receive(:perform_in).exactly(3).times do |delay, processor, date_string, user_ids, bank_account_type|
        expect(processor).to eq(payout_processor_type)
        expect(date_string).to eq(payout_date.to_s)
        expect(bank_account_type).to be_nil
        delays << delay
        enqueued_ids.concat(user_ids)
      end

      described_class.create_payments_for_balances_up_to_date(payout_date, payout_processor_type)

      expect(enqueued_ids).to match_array(users.map(&:id))
      # Staggered so the whole cohort's payout jobs don't hit the processors at once.
      expect(delays).to eq([0, Payouts::SLICE_ENQUEUE_STAGGER, 2 * Payouts::SLICE_ENQUEUE_STAGGER])
    end

    it "does not evaluate eligibility itself, so the orchestrator stays short-lived" do
      create(:user, unpaid_balance_cents: 100)
      allow(PerformPayoutsForUserSliceWorker).to receive(:perform_in)

      expect(described_class).not_to receive(:create_payments_for_balances_up_to_date_for_users)

      described_class.create_payments_for_balances_up_to_date(payout_date, payout_processor_type)
    end
  end

  describe "create_payments_for_balances_up_to_date_for_user_ids" do
    let(:payout_date) { Date.yesterday }

    it "evaluates the given sellers and enqueues their payouts asynchronously" do
      users = create_list(:user, 2, unpaid_balance_cents: 100)

      expect(described_class).to receive(:create_payments_for_balances_up_to_date_for_users) do |date, processor, relation, **kwargs|
        expect(date).to eq(payout_date)
        expect(processor).to eq(PayoutProcessorType::PAYPAL)
        expect(relation).to match_array(users)
        expect(kwargs[:perform_async]).to eq(true)
        expect(kwargs[:bank_account_type]).to be_nil
      end

      described_class.create_payments_for_balances_up_to_date_for_user_ids(payout_date, PayoutProcessorType::PAYPAL, users.map(&:id))
    end

    it "limits the Friday Stripe run to sellers with an active Stripe Connect account" do
      u1 = create(:user, unpaid_balance_cents: 200) # Has balance and a Stripe account but no Stripe Connect account
      u2 = create(:user, unpaid_balance_cents: 100) # Has balance and an active Stripe Connect account
      u3 = create(:user, unpaid_balance_cents: 1000) # Has balance and an inactive Stripe Connect account
      u4 = create(:user, unpaid_balance_cents: 1000) # Has balance but no Stripe or Stripe Connect account

      create(:merchant_account, charge_processor_merchant_id: "stripe_u1", user: u1)
      create(:merchant_account_stripe_connect, charge_processor_merchant_id: "stripe_connect_u2", user: u2)
      create(:merchant_account_stripe_connect, charge_processor_merchant_id: "stripe_connect_u3", user: u3, deleted_at: Time.current)

      expect(described_class).to receive(:create_payments_for_balances_up_to_date_for_users) do |_date, _processor, relation, **_kwargs|
        expect(relation.to_a).to eq([u2])
      end

      described_class.create_payments_for_balances_up_to_date_for_user_ids(payout_date, PayoutProcessorType::STRIPE, [u1, u2, u3, u4].map(&:id))
    end

    it "does not apply the Stripe Connect filter to a bank-account-type run" do
      # Bank-account-type runs pay Gumroad-managed Stripe accounts, which have no Stripe
      # Connect merchant account — filtering on one would pay nobody.
      user = create(:user, unpaid_balance_cents: 100)

      expect(described_class).to receive(:create_payments_for_balances_up_to_date_for_users).with(payout_date, PayoutProcessorType::STRIPE, [user], perform_async: true, bank_account_type: "AchAccount")

      described_class.create_payments_for_balances_up_to_date_for_user_ids(payout_date, PayoutProcessorType::STRIPE, [user.id], bank_account_type: "AchAccount")
    end
  end

  describe "create_instant_payouts_for_balances_up_to_date" do
    let(:payout_date) { Date.yesterday }

    it "calls create_instant_payouts_for_balances_up_to_date_for_users with all users holding balance with a payout frequency of daily" do
      create(:user, unpaid_balance_cents: 0, payout_frequency: User::PayoutSchedule::WEEKLY)
      create(:user, unpaid_balance_cents: 100, payout_frequency: User::PayoutSchedule::WEEKLY)
      create(:user, unpaid_balance_cents: 0, payout_frequency: User::PayoutSchedule::DAILY)
      u4 = create(:user, unpaid_balance_cents: 100, payout_frequency: User::PayoutSchedule::DAILY)

      expect(described_class).to receive(:create_instant_payouts_for_balances_up_to_date_for_users).with(payout_date, [u4], perform_async: true, add_comment: true)

      described_class.create_instant_payouts_for_balances_up_to_date(payout_date)
    end
  end

  describe "create_instant_payouts_for_balances_up_to_date_for_users" do
    let(:payout_date) { Date.yesterday }

    context "when the seller does not support instant payouts" do
      it "does not create payments" do
        creator = create(:user_with_compliance_info)
        allow_any_instance_of(User).to receive(:instant_payouts_supported?).and_return(false)

        expect do
          described_class.create_instant_payouts_for_balances_up_to_date_for_users(payout_date, [creator])
        end.to_not change { Payment.count }
      end
    end

    context "when the seller is payable" do
      # Daily-scheduled payouts must always be enqueued as instant payouts. That is what
      # makes the daily fee identical to the manual instant payout fee: both paths go
      # through StripePayoutProcessor#prepare_payment_and_set_amount, which deducts
      # StripePayoutProcessor::INSTANT_PAYOUT_FEE_PERCENT for PAYOUT_TYPE_INSTANT payments.
      it "enqueues the payout as an instant payout so the instant payout fee applies" do
        creator = create(:user_with_compliance_info)
        allow(described_class).to receive(:is_user_payable).and_return(true)

        expect(StripePayoutProcessor).to receive(:enqueue_payments).with(
          [creator.id], payout_date.to_s, payout_type: Payouts::PAYOUT_TYPE_INSTANT
        )

        described_class.create_instant_payouts_for_balances_up_to_date_for_users(payout_date, [creator], perform_async: true)
      end
    end
  end

  describe ".create_payment" do
    let(:payout_date) { Date.today - 1 }
    let(:user) { create(:user) }
    let!(:merchant_account) { create(:merchant_account, user:) }

    before do
      create(:ach_account, user:)
      create(:balance, user:, merchant_account:, date: payout_date - 1, amount_cents: 10_00)
    end

    it "marks the payment as processing when preparation succeeds" do
      allow(StripePayoutProcessor).to receive(:is_balance_payable).and_return(true)
      allow(StripePayoutProcessor).to receive(:prepare_payment_and_set_amount) do |payment, balances|
        payment.currency = Currency::USD
        payment.amount_cents = balances.sum(&:holding_amount_cents)
        []
      end

      payment, payment_errors = described_class.create_payment(payout_date.to_s, PayoutProcessorType::STRIPE, user)

      expect(payment.state).to eq("processing")
      expect(payment_errors).to eq([])
    end

    it "does not attempt to mark the payment as processing when the processor failed it during preparation" do
      # The Stripe payout processor marks the payment as failed inside prepare_payment_and_set_amount
      # when, for example, the user has no valid merchant account or a balance's holding currency does
      # not match the payout destination. Attempting to mark such a payment as processing raises
      # StateMachines::InvalidTransition (failed → processing is not a valid transition).
      error_message = "Cannot process payout: no valid merchant account found for user."
      allow(StripePayoutProcessor).to receive(:is_balance_payable).and_return(true)
      allow(StripePayoutProcessor).to receive(:prepare_payment_and_set_amount) do |payment, _balances|
        payment.currency = Currency::USD
        payment.amount_cents = 0
        payment.mark_failed!
        [error_message]
      end

      expect do
        payment, payment_errors = described_class.create_payment(payout_date.to_s, PayoutProcessorType::STRIPE, user)

        expect(payment.state).to eq("failed")
        expect(payment_errors).to eq([error_message])
      end.not_to raise_error
    end

    it "skips a balance that left unpaid between selection and lock instead of raising" do
      allow(StripePayoutProcessor).to receive(:is_balance_payable).and_return(true)
      balance = user.balances.sole
      expect(balance).to be_unpaid

      # Simulate the concurrent loser: it selected this row while unpaid, then the winner
      # marked it processing before the loser's with_lock ran. unpaid_balances_up_to_date
      # would normally omit processing rows, so stub the stale selection the loser still holds.
      balance.mark_processing!
      allow(user).to receive(:unpaid_balances_up_to_date).with(payout_date).and_return(Balance.where(id: balance.id))

      # Without the unpaid? guard, mark_processing! raises StateMachines::InvalidTransition.
      marked = nil
      expect do
        marked = described_class.send(:mark_balances_processing, payout_date, PayoutProcessorType::STRIPE, user)
      end.not_to raise_error

      expect(marked).to eq([])
      expect(balance.reload).to be_processing
    end

    it "marks only still-unpaid balances when a concurrent winner took part of the selection" do
      allow(StripePayoutProcessor).to receive(:is_balance_payable).and_return(true)
      first = user.balances.sole
      second = create(:balance, user:, merchant_account:, date: payout_date - 2, amount_cents: 5_00)
      expect(first).to be_unpaid
      expect(second).to be_unpaid

      # Stale selection holds both ids as unpaid in memory; the winner already claimed `first`.
      first.mark_processing!
      allow(user).to receive(:unpaid_balances_up_to_date).with(payout_date).and_return(
        Balance.where(id: [first.id, second.id]).order(:id)
      )

      marked = nil
      expect do
        marked = described_class.send(:mark_balances_processing, payout_date, PayoutProcessorType::STRIPE, user)
      end.not_to raise_error

      expect(marked.map(&:id)).to eq([second.id])
      expect(first.reload).to be_processing
      expect(second.reload).to be_processing
    end
  end

  describe ".create_payments_for_balances_up_to_date_for_bank_account_types" do
    let(:payout_date) { Date.today - 1 }
    let(:payout_processor_type) { PayoutProcessorType::STRIPE }

    let(:u0_0) do
      create(:user, unpaid_balance_cents: 0)
    end
    let(:u0_1) do
      user = create(:user, unpaid_balance_cents: 0)
      create(:ach_account, user:)
      user
    end
    let(:u0_2) do
      user = create(:user, unpaid_balance_cents: 0)
      create(:australian_bank_account, user:)
      user
    end
    before { u0_0 && u0_1 && u0_2 }

    let(:u1_0) do
      create(:user, unpaid_balance_cents: 10_00)
    end
    let(:u1_1) do
      user = create(:user, unpaid_balance_cents: 10_00)
      create(:ach_account, user:)
      user
    end
    let(:u1_2) do
      user = create(:user, unpaid_balance_cents: 10_00)
      create(:australian_bank_account, user:)
      user
    end
    before { u1_0 && u1_1 && u1_2 }

    let(:u2_0) do
      create(:user, unpaid_balance_cents: 100_00)
    end
    let(:u2_1) do
      user = create(:user, unpaid_balance_cents: 100_00)
      create(:ach_account, user:)
      user
    end
    let(:u2_2) do
      user = create(:user, unpaid_balance_cents: 100_00)
      create(:australian_bank_account, user:).mark_deleted!
      create(:australian_bank_account, user:)
      user
    end
    before { u2_0 && u2_1 && u2_2 }

    let(:u3_0) do
      user = create(:user, unpaid_balance_cents: 100_00)
      create(:canadian_bank_account, user:)
      user
    end
    before { u3_0 }

    it "enqueues a slice job for the users holding balance once for every bank account type" do
      slices = []
      allow(PerformPayoutsForUserSliceWorker).to receive(:perform_in) do |_delay, processor, date_string, user_ids, bank_account_type|
        expect(processor).to eq(payout_processor_type)
        expect(date_string).to eq(payout_date.to_s)
        slices << [bank_account_type, user_ids]
      end

      described_class.create_payments_for_balances_up_to_date_for_bank_account_types(payout_date, payout_processor_type, [AustralianBankAccount.name, CanadianBankAccount.name])

      expect(slices).to match_array([
                                      ["AustralianBankAccount", [u1_2.id, u2_2.id]],
                                      ["CanadianBankAccount", [u3_0.id]],
                                    ])
    end

    it "looks up bank accounts in chunks of holding-balance user ids" do
      stub_const("Payouts::BANK_ACCOUNT_LOOKUP_BATCH_SIZE", 1)

      expect(PerformPayoutsForUserSliceWorker).to receive(:perform_in)
        .with(0, payout_processor_type, payout_date.to_s, [u1_2.id, u2_2.id], "AustralianBankAccount")

      expect(BankAccount).to receive(:alive).at_least(:twice).and_call_original

      described_class.create_payments_for_balances_up_to_date_for_bank_account_types(payout_date, payout_processor_type, [AustralianBankAccount.name])
    end

    it "selects the same users when the holding-balance ids are materialized in multiple batches" do
      stub_const("Payouts::HOLDING_BALANCE_ID_BATCH_SIZE", 1)

      expect(PerformPayoutsForUserSliceWorker).to receive(:perform_in)
        .with(0, payout_processor_type, payout_date.to_s, [u1_2.id, u2_2.id], "AustralianBankAccount")

      described_class.create_payments_for_balances_up_to_date_for_bank_account_types(payout_date, payout_processor_type, [AustralianBankAccount.name])
    end

    it "hands the matched users to slice jobs in id-bounded batches so a large cohort cannot force a full-table scan" do
      stub_const("Payouts::USER_LOOKUP_BATCH_SIZE", 1)

      enqueued_slices = []
      allow(PerformPayoutsForUserSliceWorker).to receive(:perform_in) do |_delay, _processor, _date_string, user_ids, _bank_account_type|
        enqueued_slices << user_ids
      end

      described_class.create_payments_for_balances_up_to_date_for_bank_account_types(payout_date, payout_processor_type, [AustralianBankAccount.name])

      # One slice per user at a batch size of 1: no single lookup ever exceeds the cap,
      # and the union across slices is still the full Australian cohort.
      expect(enqueued_slices.size).to eq(2)
      expect(enqueued_slices.map(&:size)).to all(be <= 1)
      expect(enqueued_slices.flatten).to match_array([u1_2.id, u2_2.id])
    end
  end

  describe ".holding_balance_user_ids" do
    let!(:zero_balance_user) { create(:user, unpaid_balance_cents: 0) }
    let!(:below_minimum_user) { create(:user, unpaid_balance_cents: 10_00) }
    let!(:above_minimum_user) { create(:user, unpaid_balance_cents: 100_00) }
    let!(:multiple_balances_user) do
      user = create(:user)
      create(:balance, user:, amount_cents: 60_00, date: Date.today - 3)
      create(:balance, user:, amount_cents: -20_00, date: Date.today - 2)
      user
    end
    let!(:negative_net_balance_user) do
      user = create(:user)
      create(:balance, user:, amount_cents: 10_00, date: Date.today - 3)
      create(:balance, user:, amount_cents: -30_00, date: Date.today - 2)
      user
    end
    let!(:paid_balance_user) do
      user = create(:user)
      create(:balance, user:, amount_cents: 500_00, date: Date.today - 3, state: "paid")
      user
    end
    let!(:mixed_bank_type_user) do
      user = create(:user, unpaid_balance_cents: 200_00)
      create(:ach_account, user:)
      create(:australian_bank_account, user:)
      user
    end

    it "returns exactly the same user set as the single-statement User.holding_balance query" do
      expect(described_class.holding_balance_user_ids.sort).to eq(User.holding_balance.ids.sort)
      expect(described_class.holding_balance_user_ids).to match_array(
        [below_minimum_user.id, above_minimum_user.id, multiple_balances_user.id, mixed_bank_type_user.id]
      )
    end

    it "returns the same user set when materialized across multiple batches" do
      stub_const("Payouts::HOLDING_BALANCE_ID_BATCH_SIZE", 1)

      expect(described_class.holding_balance_user_ids.sort).to eq(User.holding_balance.ids.sort)
    end

    it "never splits a user's balance aggregation across batches" do
      stub_const("Payouts::HOLDING_BALANCE_ID_BATCH_SIZE", 1)

      # negative_net_balance_user has a positive row and a larger negative row; a
      # per-row (rather than per-user) batching bug would surface them as holding
      # a balance.
      expect(described_class.holding_balance_user_ids).not_to include(negative_net_balance_user.id)
      expect(described_class.holding_balance_user_ids).to include(multiple_balances_user.id)
    end
  end

  describe "create_payments_for_balances_up_to_date_for_users" do
    context "when the seller is on a non-Friday payout rail" do
      # The per-user gate in this method compares the batch's payout period against the seller's
      # own next_payout_date. Moving that date onto the seller's rail weekday must not make the
      # very job that pays them skip them, so assert the seller is still paid on their own day.
      it "still pays a seller whose projected date is their rail's weekday" do
        travel_to(Time.local(2026, 7, 28, 12)) do # Tuesday, the cross-border run's day
          creator = create(:user_with_compliance_info)
          create(:merchant_account, user: creator, charge_processor_merchant_id: "acct_railweekdaytest")
          create(:philippines_bank_account, user: creator, stripe_bank_account_id: "ba_bankaccountid")
          create(:balance, user: creator, amount_cents: 100_001, date: 20.days.ago)

          expect(creator.next_payout_date).to eq Date.new(2026, 7, 28)

          expect do
            described_class.create_payments_for_balances_up_to_date_for_users(
              User::PayoutSchedule.next_scheduled_payout_end_date, PayoutProcessorType::STRIPE, [creator]
            )
          end.to change { Payment.count }.by(1)
        end
      end

      it "still pays a seller when the batch is run after their rail's weekday has passed" do
        # A payout batch is scheduled by the cycle, but it can run later in the same week — a
        # slice job that died on Tuesday is retried on Wednesday, for instance. The batch's
        # payout period is fixed when it is enqueued, so the seller must still be paid; a gate
        # comparing that period against the seller's own Tuesday would read the retry as
        # belonging to next week and quietly pay nobody.
        creator = create(:user_with_compliance_info)
        create(:merchant_account, user: creator, charge_processor_merchant_id: "acct_railretrytest")
        create(:philippines_bank_account, user: creator, stripe_bank_account_id: "ba_bankaccountid")
        create(:balance, user: creator, amount_cents: 100_001, date: Date.new(2026, 7, 8))

        payout_period_end_date = travel_to(Time.local(2026, 7, 28, 12)) do # Tuesday, the run's day
          User::PayoutSchedule.next_scheduled_payout_end_date
        end

        travel_to(Time.local(2026, 7, 29, 12)) do # Wednesday, the day after
          expect do
            described_class.create_payments_for_balances_up_to_date_for_users(
              payout_period_end_date, PayoutProcessorType::STRIPE, [creator]
            )
          end.to change { Payment.count }.by(1)
        end
      end
    end

    context "when payouts are paused for the seller" do
      it "does not create payments" do
        creator = create(:user_with_compliance_info, payouts_paused_internally: true)
        create(:merchant_account, user: creator)
        create(:ach_account, user: creator, stripe_bank_account_id: "ba_bankaccountid")
        create(:balance, user: creator, amount_cents: 100_001, date: 20.days.ago)

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(10.days.ago, PayoutProcessorType::STRIPE, [creator])
        end.to_not change { Payment.count }
      end
    end

    describe "attempting to payout for today" do
      it "raises an argument error" do
        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today, PayoutProcessorType::PAYPAL, [])
        end.to raise_error(ArgumentError)
      end
    end

    describe "attempting to payout for a future date" do
      it "raises an argument error" do
        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today + 10, PayoutProcessorType::PAYPAL, [])
        end.to raise_error(ArgumentError)
      end
    end

    describe "payout schedule" do
      let(:seller) { create(:compliant_user, payment_address: "seller@example.com") }
      let(:payout_date) { Date.today - 1 }

      # Pinned because these examples only hold Wed-Fri. From Saturday through Tuesday the
      # balance below lands inside the upcoming Friday cycle's period, so it clears the minimum,
      # the cycle stays put, and the gate in .create_payments_for_balances_up_to_date_for_users
      # accepts where these examples expect a reject.
      before do
        travel_to(Time.utc(2026, 8, 5, 12))
        create(:balance, user: seller, date: payout_date - 3, amount_cents: 1000_00)
        create(:user_compliance_info, user: seller)
      end

      it "does not create payments if the seller's payout cycle is past this payout date" do
        # The gate reads #next_payout_cycle_date, not the seller's own rail day.
        allow(seller).to receive(:next_payout_cycle_date).and_return(payout_date + 2.weeks)

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(payout_date, PayoutProcessorType::PAYPAL, [seller])
        end.not_to change { Payment.count }
      end

      it "creates payments when retrying even though the cycle has moved past this payout date" do
        # The real requeue shape: a payment row already exists for the period, failed or not.
        # What puts the cycle past this payout date here is the balance being too new for the
        # coming Friday's period, not this row — the row's own advance needs cycle == today.
        create(:payment, user: seller, payout_period_end_date: payout_date, state: "processing")
                .mark_failed!(Payment::FailureReason::PROCESSOR_RATE_LIMITED)
        expect(payout_date + User::PayoutSchedule::PAYOUT_DELAY_DAYS).to be < seller.reload.next_payout_cycle_date

        expect(PaypalPayoutProcessor).to receive(:enqueue_payments).with([seller.id], payout_date.to_s)

        described_class.create_payments_for_balances_up_to_date_for_users(payout_date, PayoutProcessorType::PAYPAL, [seller], perform_async: true, retrying: true)
      end

      it "skips the seller when not retrying and the cycle has moved past this payout date" do
        create(:payment, user: seller, payout_period_end_date: payout_date, state: "processing")
                .mark_failed!(Payment::FailureReason::PROCESSOR_RATE_LIMITED)
        expect(payout_date + User::PayoutSchedule::PAYOUT_DELAY_DAYS).to be < seller.reload.next_payout_cycle_date

        expect(PaypalPayoutProcessor).to receive(:enqueue_payments).with([], payout_date.to_s)

        described_class.create_payments_for_balances_up_to_date_for_users(payout_date, PayoutProcessorType::PAYPAL, [seller], perform_async: true)
      end
    end

    describe "payout skipped notes" do
      it "adds a comment if payout is skipped due to low balance", :vcr do
        payout_time = Date.today.in_time_zone("UTC").beginning_of_week(:friday).change(hour: 10)
        travel_to payout_time + 1.day

        seller = create(:compliant_user, payment_address: "seller@gr.co")
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 99_00)
        seller2 = create(:compliant_user, payment_address: "seller@gr.co")
        create(:user_compliance_info, user: seller2)
        create(:balance, user: seller2, date: Date.today - 3, amount_cents: 100_00)
        seller3 = create(:compliant_user, payment_address: "seller@gr.co")
        create(:user_compliance_info, user: seller3)
        expect(seller3.unpaid_balance_cents).to eq(0)

        expect do
          expect do
            expect do
              described_class.create_payments_for_balances_up_to_date_for_users(payout_time.to_date, PayoutProcessorType::PAYPAL, [seller, seller2])
            end.to change { seller.comments.with_type_payout_note.count }.by(1)
          end.not_to change { seller2.comments.count }
        end.not_to change { seller3.comments.count }

        date = Time.current.to_fs(:formatted_date_full_month)
        content = "Your payout on #{date} was skipped because your balance of $99 was below the $100 minimum. You'll be paid out automatically once your balance reaches $100."
        expect(seller.comments.with_type_payout_note.last.content).to eq(content)
      end

      it "adds a comment if payout is skipped because the account is under review" do
        seller = create(:user, payment_address: "seller@example.com")
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 1000_00)

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [seller])
        end.to change { seller.comments.with_type_payout_note.count }.by(1)

        date = Time.current.to_fs(:formatted_date_full_month)
        content = "Payout on #{date} was skipped because the account was under review."
        expect(seller.comments.with_type_payout_note.count).to eq 1
        expect(seller.comments.with_type_payout_note.last.content).to eq(content)
      end

      it "adds a below-minimum comment instead of an under-review one when a not-reviewed account is below the payout minimum" do
        seller = create(:user, payment_address: "seller@example.com")
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 59_72)

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [seller])
        end.to change { seller.comments.with_type_payout_note.count }.by(1)

        date = Time.current.to_fs(:formatted_date_full_month)
        content = "Your payout on #{date} was skipped because your balance of $59.72 was below the $100 minimum. You'll be paid out automatically once your balance reaches $100."
        expect(seller.comments.with_type_payout_note.last.content).to eq(content)
      end

      it "adds an under-review comment for a not-reviewed account with a zero balance" do
        seller = create(:user, payment_address: "seller@example.com")
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 1000)
        create(:balance, user: seller, date: Date.today - 2, amount_cents: -1000)

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [seller])
        end.to change { seller.comments.with_type_payout_note.count }.by(1)

        date = Time.current.to_fs(:formatted_date_full_month)
        content = "Payout on #{date} was skipped because the account was under review."
        expect(seller.comments.with_type_payout_note.last.content).to eq(content)
      end

      it "adds a comment if payout is skipped because the account is suspended" do
        seller = create(:user, user_risk_state: "suspended_for_fraud", payment_address: "seller@example.com")
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 1000)

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [seller])
        end.to change { seller.comments.with_type_payout_note.count }.by(1)

        date = Time.current.to_fs(:formatted_date_full_month)
        content = "Payout on #{date} was skipped because the account was not compliant."
        expect(seller.comments.with_type_payout_note.count).to eq 1
        expect(seller.comments.with_type_payout_note.last.content).to eq(content)

        seller.update!(user_risk_state: "suspended_for_tos_violation")

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [seller])
        end.to change { seller.comments.with_type_payout_note.count }.by(1)

        expect(seller.comments.with_type_payout_note.count).to eq 2
        expect(seller.comments.with_type_payout_note.last.content).to eq(content)
      end

      it "adds a comment if payout is skipped because payouts are paused by admin" do
        seller = create(:compliant_user, payment_address: "seller@gr.co")
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 1000)
        seller.update!(payouts_paused_internally: true)

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [seller])
        end.to change { seller.comments.with_type_payout_note.count }.by(1)

        date = Time.current.to_fs(:formatted_date_full_month)
        content = "Payout on #{date} was skipped because payouts on the account were paused by the admin."
        expect(seller.comments.with_type_payout_note.last.content).to eq(content)
      end

      it "adds a comment if payout is skipped because payouts are paused by stripe" do
        seller = create(:compliant_user)
        create(:ach_account, user: seller)
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 1000)
        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller])
        end.to change { seller.comments.with_type_payout_note.count }.by(1)

        date = Time.current.to_fs(:formatted_date_full_month)
        content = "Payout on #{date} was skipped because payouts on the account were paused by the payout processor."
        expect(seller.comments.with_type_payout_note.last.content).to eq(content)
      end

      it "adds a comment if payout is skipped because payouts are paused by the system" do
        seller = create(:compliant_user)
        create(:ach_account, user: seller)
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 1000)
        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller])
        end.to change { seller.comments.with_type_payout_note.count }.by(1)

        date = Time.current.to_fs(:formatted_date_full_month)
        content = "Payout on #{date} was skipped because payouts on the account were paused by the system."
        expect(seller.comments.with_type_payout_note.last.content).to eq(content)
      end

      it "adds a comment if payout is skipped because payouts are paused by the seller" do
        seller = create(:compliant_user)
        create(:ach_account, user: seller)
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 1000)
        seller.update!(payouts_paused_by_user: true)

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller])
        end.to change { seller.comments.with_type_payout_note.count }.by(1)

        date = Time.current.to_fs(:formatted_date_full_month)
        content = "Payout on #{date} was skipped because payouts on the account were paused by the user."
        expect(seller.comments.with_type_payout_note.last.content).to eq(content)
      end

      # A seller whose PayPal account can never receive the money is told so once, and that note is
      # the only thing on their Payouts page telling them what to do about it. The banner shows the
      # newest note they are allowed to see, so writing this weekly note seller-visible would put
      # them back to reading "payouts were paused by the system" within one payout cycle.
      it "does not let the paused-payout note bury a terminal PayPal explanation" do
        seller = seller_blocked_by_paypal_reading_the_explanation
        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [seller])
        end.to change { seller.comments.with_type_payout_note.count }.by(1)

        # Support still gets the note; the seller keeps seeing the explanation.
        paused_note = seller.comments.with_type_payout_note.last
        expect(paused_note.content).to include("payouts on the account were paused by the system")
        expect(PayoutNoteVisibility.seller_visible?(paused_note)).to eq(false)
        expect(seller.reload.latest_seller_visible_payout_note.content)
          .to include("payments cannot be received in the country on that account's address")
      end

      it "still shows the paused-payout note to a seller with no terminal PayPal explanation" do
        seller = create(:compliant_user)
        create(:ach_account, user: seller)
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 1000)
        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)

        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller])

        paused_note = seller.comments.with_type_payout_note.last
        expect(PayoutNoteVisibility.seller_visible?(paused_note)).to eq(true)
      end

      # Hiding a pause note takes information away from the seller, so it lasts only as long as the
      # PayPal block does. The explanation stays their newest visible note forever once written, so
      # keying on its wording alone would hide every future pause note — including pauses placed for
      # reasons that have nothing to do with PayPal.
      it "shows the paused-payout note again once the seller is no longer blocked by PayPal" do
        seller = seller_blocked_by_paypal_reading_the_explanation
        # The seller fixed it the way we asked them to.
        create(:ach_account, user: seller)
        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)

        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [seller])

        paused_note = seller.comments.with_type_payout_note.last
        expect(paused_note.content).to include("payouts on the account were paused by the system")
        expect(PayoutNoteVisibility.seller_visible?(paused_note)).to eq(true)
      end

      # For a seller who paused their own payouts, the note naming that switch is the actionable
      # message — and the explanation they would see instead may promise a payout date their own
      # pause now prevents, because its wording was chosen when it was written.
      it "still shows the paused-payout note to a seller who paused their own payouts" do
        seller = seller_blocked_by_paypal_reading_the_explanation
        seller.update!(payouts_paused_by_user: true)

        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [seller])

        paused_note = seller.comments.with_type_payout_note.last
        expect(paused_note.content).to include("payouts on the account were paused by the user")
        expect(PayoutNoteVisibility.seller_visible?(paused_note)).to eq(true)
      end

      # Every run adds a row whether or not the seller sees it, and the note lookups only scan back
      # 25 notes — so repeating the hidden note would push the explanation out of that window and
      # silently disarm the suppression, besides flooding accounts that already carry hundreds of
      # automated comments.
      it "does not write a second hidden paused-payout note on the next run" do
        seller = seller_blocked_by_paypal_reading_the_explanation
        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)

        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [seller])

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [seller])
        end.to_not change { seller.comments.with_type_payout_note.count }

        # And the explanation is still what the seller sees.
        expect(seller.reload.latest_seller_visible_payout_note.content)
          .to include("payments cannot be received in the country on that account's address")
      end

      # A held seller can be reading an explanation of a rejection they have already left behind:
      # rejected on one PayPal address, switched to another, rejected again. The note on their page
      # names the address they abandoned, so it quotes a payout date that is not the one that
      # stopped their money and — because the two rejections say different things — possibly the
      # wrong restriction. They are held, so the PayPal processor's own re-explain never runs for
      # them; this walk is the only thing that can correct it.
      it "restores the explanation for a held seller reading one about an address they left" do
        seller = create(:compliant_user, payment_address: "old@example.com")
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 1000)
        old_rejection = create(:payment_failed, user: seller, payment_address: "old@example.com",
                                                failure_reason: "PAYPAL 3148", txn_id: nil, processor_fee_cents: nil)
        seller.add_payout_note(content: old_rejection.terminal_paypal_failure_seller_note, seller_visible: true)

        # They moved to a different PayPal account, which PayPal refused for a different reason.
        seller.update!(payment_address: "new@example.com")
        create(:payment_failed, user: seller, payment_address: "new@example.com",
                                failure_reason: "PAYPAL 14159", txn_id: nil, processor_fee_cents: nil)
        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)

        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [seller])

        expect(seller.reload.latest_seller_visible_payout_note.content)
          .to include("your PayPal account cannot receive US dollars")
      end

      # The hold is checked before any processor runs, so a held seller never reaches the PayPal
      # processor's own re-explain. Without a restore here they read "payouts were paused by the
      # system" every week with nothing telling them PayPal is what stopped the money — the exact
      # dead end gumroad-private#1478 exists to remove, and permanent, because nothing else writes
      # the explanation again.
      it "restores the explanation for a held seller whose explanation was buried" do
        seller = create(:compliant_user, payment_address: "stuck@example.com")
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 1000)
        create(:payment_failed, user: seller, payment_address: "stuck@example.com",
                                failure_reason: "PAYPAL 3148", txn_id: nil, processor_fee_cents: nil)
        # A different, true blocker took the explanation's place on their Payouts page.
        seller.add_payout_note(content: "Payout on July 8th, 2026 was skipped because the account was under review.",
                               seller_visible: true)
        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)

        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [seller])

        expect(seller.reload.latest_seller_visible_payout_note.content)
          .to include("payments cannot be received in the country on that account's address")
        # Support still gets the pause note, hidden, exactly as when an explanation is visible.
        paused_note = seller.comments.with_type_payout_note.order(created_at: :desc, id: :desc).find do |note|
          note.content.include?("payouts on the account were paused by the")
        end
        expect(PayoutNoteVisibility.seller_visible?(paused_note)).to eq(false)
      end

      # Once restored, the next run must settle into the ordinary suppressed-and-deduped state
      # rather than writing the explanation again every week.
      it "does not restore the explanation again on the next run" do
        seller = create(:compliant_user, payment_address: "stuck@example.com")
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 1000)
        create(:payment_failed, user: seller, payment_address: "stuck@example.com",
                                failure_reason: "PAYPAL 3148", txn_id: nil, processor_fee_cents: nil)
        seller.add_payout_note(content: "Payout on July 8th, 2026 was skipped because the account was under review.",
                               seller_visible: true)
        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)

        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [seller])

        expect do
          described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [seller])
        end.to_not change { seller.comments.with_type_payout_note.count }
      end

      # A seller who is NOT blocked by PayPal must not be handed an explanation of a block they are
      # not under — the restore is tied to the live block, like the suppression it sits beside.
      it "does not restore an explanation for a held seller who is not blocked by PayPal" do
        seller = create(:compliant_user)
        create(:ach_account, user: seller)
        create(:user_compliance_info, user: seller)
        create(:balance, user: seller, date: Date.today - 3, amount_cents: 1000)
        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)

        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller])

        expect(seller.reload.latest_seller_visible_payout_note.content)
          .to include("payouts on the account were paused by the system")
      end
    end

    describe "notification" do
      before do
        @seller = create(:compliant_user, payment_address: "seller@gr.co")
        create(:balance, user: @seller, date: Date.today - 3, amount_cents: 900)
        @seller2 = create(:compliant_user, payment_address: "seller@gr.co")
        create(:balance, user: @seller2, date: Date.today - 3, amount_cents: 1000)
      end

      it "sends a started scheduling payouts message when scheduling payouts" do
        allow(Payouts).to receive(:is_user_payable).twice.and_return(true)

        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [@seller, @seller2], perform_async: true)
      end

      it "sends a retrying message when retrying failed payouts" do
        allow(Payouts).to receive(:is_user_payable).twice.and_return(true)

        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::PAYPAL, [@seller, @seller2], perform_async: true, retrying: true)
      end

      it "includes the country info if payouts are for creators of a specific country" do
        seller = create(:user, unpaid_balance_cents: 100_00)
        create(:canadian_bank_account, user: seller)
        seller2 = create(:user, unpaid_balance_cents: 50_00)
        create(:canadian_bank_account, user: seller2)
        seller3 = create(:user, unpaid_balance_cents: 20_00)
        create(:korea_bank_account, user: seller3)
        seller4 = create(:user, unpaid_balance_cents: 220_00)
        create(:korea_bank_account, user: seller4)
        seller5 = create(:user, unpaid_balance_cents: 120_00)
        create(:korea_bank_account, user: seller5)
        seller6 = create(:user, unpaid_balance_cents: 120_00)
        create(:european_bank_account, user: seller6)
        seller7 = create(:user, unpaid_balance_cents: 120_00)
        create(:european_bank_account, user: seller7)

        allow(Payouts).to receive(:is_user_payable).exactly(7).times.and_return(true)

        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller, seller2], perform_async: true, bank_account_type: "CanadianBankAccount")
        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller3, seller4, seller5], perform_async: true, bank_account_type: "KoreaBankAccount")
        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller6, seller7], perform_async: true, bank_account_type: "EuropeanBankAccount")
      end

      it "includes the bank or debit card info if payouts are for creators from US", :vcr do
        seller = create(:user, unpaid_balance_cents: 100_00)
        create(:ach_account, user: seller)
        seller2 = create(:user, unpaid_balance_cents: 100_00)
        create(:ach_account, user: seller2)
        seller3 = create(:user, unpaid_balance_cents: 100_00)
        create(:ach_account, user: seller3)
        seller4 = create(:user, unpaid_balance_cents: 50_00)
        create(:card_bank_account, user: seller4)
        seller5 = create(:user, unpaid_balance_cents: 50_00)
        create(:card_bank_account, user: seller5)
        seller6 = create(:user, unpaid_balance_cents: 50_00)
        create(:card_bank_account, user: seller6)
        seller7 = create(:user, unpaid_balance_cents: 50_00)
        create(:card_bank_account, user: seller7)

        allow(Payouts).to receive(:is_user_payable).exactly(7).times.and_return(true)

        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller, seller2, seller3], perform_async: true, bank_account_type: "AchAccount")
        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller4, seller5, seller6, seller7], perform_async: true, bank_account_type: "CardBankAccount")
      end

      it "includes the Stripe Connect info for Stripe payouts without a bank account type" do
        seller = create(:user, unpaid_balance_cents: 100_00)
        create(:merchant_account_stripe_connect, user: seller)
        seller2 = create(:user, unpaid_balance_cents: 100_00)
        create(:merchant_account_stripe_connect, user: seller2)

        allow(Payouts).to receive(:is_user_payable).exactly(2).times.and_return(true)

        described_class.create_payments_for_balances_up_to_date_for_users(Date.today - 1, PayoutProcessorType::STRIPE, [seller, seller2], perform_async: true)
      end
    end

    describe "a user is payable but balances are changed (e.g. by a chargeback) and will make for a negative payment" do
      let(:payout_date) { Date.today - 1 }
      let(:payout_processor_type) { PayoutProcessorType::PAYPAL }

      let(:u1) { create(:user) }
      let(:u1a1) { create(:ach_account, user: u1) }
      let(:u1b1) { create(:balance, user: u1, date: payout_date - 3, amount_cents: 1_00) }
      let(:u1b2) { create(:balance, user: u1, date: payout_date - 2, amount_cents: -15_00) }

      before do
        u1 && u1a1 && u1b1 && u1b2
        expect(described_class).to receive(:is_user_payable).and_return(true) # let the user be thought to be payable on the initial check
      end

      let(:create_payments_for_balances_up_to_date_for_users) do
        described_class.create_payments_for_balances_up_to_date_for_users(payout_date, payout_processor_type, [u1])
      end

      it "remarks the balances as unpaid" do
        create_payments_for_balances_up_to_date_for_users
        expect(u1b1.reload.state).to eq("unpaid")
        expect(u1b2.reload.state).to eq("unpaid")
      end

      it "does not alter the user's balance" do
        create_payments_for_balances_up_to_date_for_users
        expect(u1.reload.unpaid_balance_cents).to eq(-14_00)
      end

      it "does not create a payment" do
        expect { create_payments_for_balances_up_to_date_for_users }.to_not change { Payment.count }
      end
    end
  end
end
