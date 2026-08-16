# frozen_string_literal: true

require "spec_helper"

describe ContactingCreatorMailer do
  let(:custom_mailer_route_helper) do
    Class.new(ActionMailer::Base) do
      include CustomMailerRouteBuilder
    end.new
  end

  it "uses SUPPORT_EMAIL_WITH_NAME as default from address" do
    expect(described_class.default[:from]).to eq(ApplicationMailer::SUPPORT_EMAIL_WITH_NAME)
  end

  describe "cannot pay" do
    before { @payment = create(:payment) }

    it "sends notice to the payment user" do
      mail = ContactingCreatorMailer.cannot_pay(@payment.id)
      expect(mail.to).to eq [@payment.user.email]
      expect(mail.subject).to eq("We were unable to pay you.")
      expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
    end
  end

  describe "paypal payout permanently failed" do
    let(:payment) { create(:payment_failed, failure_reason: "PAYPAL 3148", txn_id: nil, processor_fee_cents: nil, amount_cents: 439_13, payment_address: "refused@example.com") }

    before do
      # Gumroad supports bank payouts here, so the email may suggest one. Sellers in PayPal-only
      # countries — the majority of those hitting these rejections — are covered separately below.
      create(:user_compliance_info, user: payment.user, country: "United States")
      # The retry-blocking rejection took the PayPal address off the account before this email was
      # enqueued, which is the state the copy describes. The removal is keyed on the address THIS
      # payout was sent to, so the payment has to carry it too.
      payment.user.update!(payment_address: "", invalidated_paypal_payout_address: payment.payment_address)
    end

    it "names PayPal, the restriction, and the fix" do
      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.to).to eq [payment.user.email]
      expect(mail.subject).to eq("Your PayPal account can't receive your payout.")
      expect(mail.body.encoded).to include("$439.13")
      expect(mail.body.encoded).to include("payments cannot be received in the country on that account&#39;s address")
      expect(mail.body.encoded).to include("We've removed that PayPal account from your payout settings")
      expect(mail.body.encoded).to include("add a bank account there")
      expect(mail.body.encoded).to include("stopped retrying it")
    end

    # The email is the only place most of these sellers hear about it, so it must not send them to
    # change a PayPal address that is no longer on the account (gumroad-private#1478).
    it "does not tell the seller to switch the PayPal account we removed" do
      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.body.encoded).to_not include("switch to a different PayPal account")
    end

    # 3148 is about the country on the account's address, so an account in the same country that
    # accepts dollars would be refused exactly the same way — offering that as the fix is wrong.
    it "describes the working alternative by country rather than by currency" do
      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.body.encoded).to include("registered in a country that can receive PayPal payments")
    end

    # A seller paid through a connected PayPal account has no saved address for us to remove, so
    # claiming we removed one would be false.
    it "claims no removal when there was no saved address to remove" do
      payment.user.update!(invalidated_paypal_payout_address: nil)

      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.body.encoded).to_not include("We've removed")
      expect(mail.body.encoded).to include("connect a PayPal account registered in a country that can receive PayPal payments")
    end

    it "names the currency restriction for a currency rejection" do
      payment.update!(failure_reason: "PAYPAL 14159")

      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.body.encoded).to include("your PayPal account cannot receive US dollars")
    end

    # A currency rejection does not stop the retries, so the email must not say it did — and the
    # seller can clear it on the account they already use. Reviewer finding on #6526.
    it "does not claim the retries stopped for a rejection we keep retrying" do
      payment.update!(failure_reason: "PAYPAL 14159")

      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.body.encoded).to_not include("stopped retrying")
      expect(mail.body.encoded).to include("keep trying on your usual payout schedule")
      expect(mail.body.encoded).to include("add US dollars as a currency you accept")
    end

    it "still says the retries stopped for a rejection that blocks them" do
      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.body.encoded).to include("stopped retrying it")
      expect(mail.body.encoded).to_not include("keep trying on your usual payout schedule")
    end

    # gumroad-private#1661. A locked receiving account is not a country problem, so the old copy
    # sent this seller after a PayPal account "registered in a country that can receive PayPal
    # payments" — the wrong diagnosis, and for the 2,152 Russia-KYC sellers in that issue an
    # instruction with no action behind it.
    context "when PayPal has locked the receiving account" do
      before { payment.update!(failure_reason: "PAYPAL 3015") }

      it "names the lock and points the seller at PayPal, not at their country" do
        mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

        expect(mail.body.encoded).to include("your PayPal account is locked or inactive")
        expect(mail.body.encoded).to include("contact PayPal to have them lifted")
        expect(mail.body.encoded).to_not include("registered in a country that can receive PayPal payments")
      end

      it "tells a seller with no bank rail plainly that we may have no way to pay them" do
        payment.user.alive_user_compliance_info.mark_deleted!
        create(:user_compliance_info, user: payment.user, country: "Ukraine")
        expect(payment.user.reload.can_setup_bank_payouts?).to be(false)

        mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

        expect(mail.body.encoded).to include("we have no way to pay you right now")
        expect(mail.body.encoded).to include("We hope to have a way to pay out your balance in the future")
      end

      # Only PayPal can unlock it, so an address-keyed block would freeze out a seller the moment
      # PayPal restores them. The retries continue and the copy must not claim otherwise.
      it "does not claim the retries stopped" do
        mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

        expect(mail.body.encoded).to_not include("stopped retrying")
        expect(mail.body.encoded).to include("keep trying on your usual payout schedule")
      end
    end

    # The payout gate exits on payouts_paused? before any processor runs, so a paused seller is not
    # being retried on schedule whatever the rejection code says. Promising it contradicts the pause
    # this same email describes further down. Reviewer finding on #6526.
    it "does not promise schedule retries to a seller whose payouts we have paused" do
      payment.update!(failure_reason: "PAYPAL 14159")
      payment.user.update!(payouts_paused_internally: true)

      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.body.encoded).to_not include("keep trying on your usual payout schedule")
      expect(mail.body.encoded).to include("Payouts on your account are paused right now")
      # The pause is named once, so the later paragraph must not reintroduce it as a second,
      # distinct restriction.
      expect(mail.body.encoded).to_not include("are also on hold")
      expect(mail.body.encoded).to include("That hold is ours to lift")
    end

    it "does not promise schedule retries to a seller who paused their own payouts" do
      payment.update!(failure_reason: "PAYPAL 14159")
      payment.user.update!(payouts_paused_by_user: true)

      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.body.encoded).to_not include("keep trying on your usual payout schedule")
      expect(mail.body.encoded).to include("Payouts on your account are paused right now")
      expect(mail.body.encoded).to_not include("also paused in your settings")
      expect(mail.body.encoded).to include("You paused them yourself")
    end

    it "promises schedule retries for a retried rejection when nothing is paused" do
      payment.update!(failure_reason: "PAYPAL 14159")

      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.body.encoded).to include("keep trying on your usual payout schedule")
      expect(mail.body.encoded).to_not include("paused right now")
    end

    it "does not promise a payout date when the account is also under a payout hold" do
      payment.user.update!(payouts_paused_internally: true)

      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.body.encoded).to include("Payouts on your account are also on hold")
      expect(mail.body.encoded).to include("reply to this email")
      expect(mail.body.encoded).to_not include("next payout date")
    end

    it "does not blame the hold on the failed payouts, since support or Stripe may have placed it" do
      payment.user.update!(payouts_paused_internally: true)

      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.body.encoded).to_not include("placed a hold")
    end

    # The payout gate checks the broader payouts_paused?, so this seller is skipped too — but the
    # switch is theirs, so they are pointed at it rather than at support.
    it "points a seller who paused their own payouts at their own setting, not at support" do
      payment.user.update!(payouts_paused_by_user: true)

      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.body.encoded).to include("paused in your settings")
      expect(mail.body.encoded).to include("next payout date")
      expect(mail.body.encoded).to_not include("on hold")
      expect(mail.body.encoded).to_not include("reply to this email")
    end

    it "promises the next payout date when the account is not under a payout hold" do
      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.body.encoded).to include("add a bank account there")
      expect(mail.body.encoded).to include("Your balance will be sent on the next payout date after that.")
      expect(mail.body.encoded).to_not include("on hold")
    end

    # The two pause flags are independent, so both can be on. Naming only the hold would tell the
    # seller support can release the balance while their own pause still blocks it. Reviewer
    # finding on #6526.
    it "names both pauses when the account is held and the seller paused their own payouts" do
      payment.user.update!(payouts_paused_internally: true, payouts_paused_by_user: true)

      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.body.encoded).to include("resume payouts in your settings")
      expect(mail.body.encoded).to include("review the hold")
      expect(mail.body.encoded).to_not include("next payout date")
    end

    it "names both pauses for a retried rejection whose retries a pause is stopping" do
      payment.update!(failure_reason: "PAYPAL 14159")
      payment.user.update!(payouts_paused_internally: true, payouts_paused_by_user: true)

      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.body.encoded).to_not include("keep trying on your usual payout schedule")
      expect(mail.body.encoded).to include("Two separate pauses are on your account")
      expect(mail.body.encoded).to include("resume payouts in your settings")
      expect(mail.body.encoded).to include("review the hold")
    end

    it "does not tell a seller in a PayPal-only country to add a bank account" do
      payment.user.alive_user_compliance_info.mark_deleted!
      create(:user_compliance_info, user: payment.user, country: "Ukraine")

      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.body.encoded).to include("We've stopped retrying this payout, because every attempt to that account will be refused")
      expect(mail.body.encoded).to include("PayPal will not send payments to accounts registered in that country, and bank transfer is not available in yours")
      expect(mail.body.encoded).to include("If you do not, we have no way to pay you right now")
      expect(mail.body.encoded).to_not include("until you change how you get paid")
      expect(mail.body.encoded).to_not include("add a bank account")
      expect(mail.body.encoded).to_not include("is not forfeited")
      expect(mail.body.encoded).to_not include("next payout date")
      expect(mail.body.encoded).to_not include("reply to this email so we can review the hold")
    end

    # The no-rail wording replaces the fix, not the hold disclosure: the hold is a separate fact and
    # is still what a seller who does find a payable account would hit next.
    it "still names a hold for a PayPal-only seller whose account is on hold" do
      payment.user.alive_user_compliance_info.mark_deleted!
      create(:user_compliance_info, user: payment.user, country: "Ukraine")
      expect(payment.user.reload.can_setup_bank_payouts?).to be(false)
      payment.user.update!(payouts_paused_internally: true)

      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.body.encoded).to include("we have no way to pay you right now")
      expect(mail.body.encoded).to include("Payouts on your account are also on hold")
      expect(mail.body.encoded).to_not include("add a bank account")
    end

    it "keeps the in-place PayPal-only path for a currency rejection" do
      payment.update!(failure_reason: "PAYPAL 14159")
      payment.user.alive_user_compliance_info.mark_deleted!
      create(:user_compliance_info, user: payment.user, country: "Ukraine")

      mail = ContactingCreatorMailer.paypal_payout_permanently_failed(payment.id)

      expect(mail.body.encoded).to include("add US dollars as a currency you accept")
      expect(mail.body.encoded).to include("use a different PayPal account")
      expect(mail.body.encoded).to_not include("we have no way to pay you right now")
    end
  end

  describe "purchase refunded" do
    it "sends notification to the seller about refunded purchase" do
      purchase = create(:purchase, link: create(:product, name: "Digital Membership"), email: "test@example.com", price_cents: 10_00)

      mail = ContactingCreatorMailer.purchase_refunded(purchase.id)
      expect(mail.to).to eq [purchase.seller.email]
      expect(mail.subject).to eq("A sale has been refunded")
      expect(mail.body.encoded).to include "test@example.com's purchase of Digital Membership for $10 has been refunded."
      expect(mail.body.encoded).not_to include "Reason:"
      expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
    end

    it "includes the refund reason when the refund has a note" do
      purchase = create(:purchase, link: create(:product, name: "Digital Membership"), email: "test@example.com", price_cents: 10_00)
      refund = create(:refund, purchase:, note: "Buyer reported being charged twice")

      mail = ContactingCreatorMailer.purchase_refunded(purchase.id, refund.id)
      expect(mail.body.encoded).to include "Reason: Buyer reported being charged twice"
    end

    it "omits the reason when the refund has no note" do
      purchase = create(:purchase, link: create(:product, name: "Digital Membership"), email: "test@example.com", price_cents: 10_00)
      refund = create(:refund, purchase:)

      mail = ContactingCreatorMailer.purchase_refunded(purchase.id, refund.id)
      expect(mail.body.encoded).not_to include "Reason:"
    end
  end

  describe "purchase refunded for fraud" do
    it "sends notification to the seller about purchase refunded for fraud" do
      purchase = create(:purchase, link: create(:product, name: "Digital Membership"), email: "test@example.com", price_cents: 10_00)

      mail = ContactingCreatorMailer.purchase_refunded_for_fraud(purchase.id)
      expect(mail.to).to eq [purchase.seller.email]
      expect(mail.subject).to eq("Fraud was detected on your Gumroad account.")
      expect(mail.body.encoded).to include "Our risk team has detected a fraudulent transaction on one of your products, using a stolen card."
      expect(mail.body.encoded).to include "We have refunded test@example.com's purchase of Digital Membership for $10."
      expect(mail.body.encoded).to include "We're doing our best to protect you, and no further action needs to be taken on your part."
      expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
    end
  end

  describe "chargeback notice" do
    let(:seller) { create(:named_seller) }

    context "for a dispute on Purchase" do
      let(:purchase) { create(:purchase, link: create(:product, user: seller)) }
      let(:dispute) { create(:dispute_formalized, purchase:) }

      it "sends chargeback notice correctly" do
        mail = ContactingCreatorMailer.chargeback_notice(dispute.id)
        expect(mail.to).to eq [seller.email]
        expect(mail.subject).to eq "A sale has been disputed"

        expect(mail.body.encoded).to include "A customer of yours (#{purchase.email}) has disputed their purchase of #{purchase.link.name} for #{purchase.formatted_disputed_amount}."
        expect(mail.body.encoded).to include "We have deducted the amount from your balance, and are looking into it for you."
        expect(mail.body.encoded).to include "We fight every dispute. If we succeed, you will automatically be re-credited the full amount. This process takes up to 75 days."
        expect(mail.body.encoded).not_to include "Any additional information you can provide"
      end

      context "when the seller is contacted to submit evidence" do
        let!(:dispute_evidence) do
          create(:dispute_evidence, dispute:)
        end

        it "includes copy to submit evidence" do
          mail = ContactingCreatorMailer.chargeback_notice(dispute.id)
          expect(mail.subject).to eq "🚨 Urgent: Action required for resolving disputed sale"

          expect(mail.body.encoded).to include "A customer of yours (#{purchase.email}) has disputed their purchase of #{purchase.link.name} for #{purchase.formatted_disputed_amount}."
          expect(mail.body.encoded).to include "Any additional information you can provide by"
          expect(mail.body.encoded).to include "(in the next 72 hours) will help us win on your behalf."
          expect(mail.body.encoded).to include "Submit additional information"
        end

        # The link's expiry is not the deadline. Minting it with seller_response_due_at killed the
        # token the same second the window closed, so a seller who clicked a minute late got a 404
        # instead of the "deadline has passed" explanation the page is written to give them. The
        # window is still refused on arrival — check_if_needs_redirect does that, not the token.
        it "mints a link that still resolves after the deadline it quotes" do
          mail = ContactingCreatorMailer.chargeback_notice(dispute.id)
          token = mail.body.decoded[%r{/purchases/([^/?"]+)/dispute_evidence}, 1]
          expect(token).to be_present

          travel_to(dispute_evidence.seller_response_due_at + 1.hour) do
            found = Purchase.find_by_secure_external_id(token, scope: Purchases::DisputeEvidenceController::SECURE_ID_SCOPE)
            expect(found).to eq(purchase)
          end
        end

        # Hours are computed when the mail renders, not when it is enqueued, and
        # CreateMissingDisputeEvidenceJob backdates windows to a few hours to beat the processor's
        # cutoff. A notice queued with an hour left can therefore render with none, and asking for
        # information "in the next 0 hours" beside a live button is worse than not asking.
        context "when the window has run out by the time the mail renders" do
          before do
            dispute_evidence.update!(seller_contacted_at: (DisputeEvidence::SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS - 0.4).hours.ago)
          end

          it "drops the request for evidence rather than quoting a deadline that has passed" do
            mail = ContactingCreatorMailer.chargeback_notice(dispute.id)

            expect(dispute_evidence.hours_left_to_submit_evidence).to eq(0)
            expect(mail.body.encoded).not_to include "Any additional information you can provide"
            expect(mail.body.encoded).not_to include "in the next 0 hours"
            expect(mail.body.encoded).not_to include "Submit additional information"
            expect(mail.subject).to eq "A sale has been disputed"
            expect(mail.body.encoded).to include "We fight every dispute."
          end
        end

        # The mailer renders whenever the queue gets to it, so the seller may have answered the ask —
        # or the row may have been resolved — after the notice was enqueued. Only resolution closes
        # the form now: nothing is forwarded until the window elapses, so a seller who saved early
        # may still revise, and the notice must keep linking them back.
        context "when the seller has already saved a response by the time the mail renders" do
          before { dispute_evidence.update!(seller_submitted_at: Time.current) }

          it "still links the seller back to the form they can keep revising" do
            mail = ContactingCreatorMailer.chargeback_notice(dispute.id)

            expect(dispute_evidence.accepting_evidence?).to be(true)
            expect(mail.body.encoded).to include "Any additional information you can provide"
            expect(mail.body.encoded).to include "Submit additional information"
            expect(mail.subject).to eq "🚨 Urgent: Action required for resolving disputed sale"
          end
        end

        describe "chargeback evidence due soon" do
          it "reminds the seller while the submission window is still open" do
            dispute_evidence.update!(seller_contacted_at: 49.hours.ago)

            mail = ContactingCreatorMailer.chargeback_evidence_due_soon(dispute.id)

            expect(mail.to).to eq [seller.email]
            expect(mail.subject).to eq "Reminder: Submit dispute evidence within 24 hours"
            expect(mail.body.encoded).to include "Please submit any additional information by"
            expect(mail.body.encoded).to include "You have 23 hours left."
            expect(mail.body.encoded).to include "Submit additional information"
          end

          it "still reminds a seller who saved early, since they may keep revising" do
            dispute_evidence.update!(seller_contacted_at: 49.hours.ago, seller_submitted_at: Time.current)

            mail = ContactingCreatorMailer.chargeback_evidence_due_soon(dispute.id)

            expect(mail.subject).to eq "Reminder: Submit dispute evidence within 24 hours"
            expect(mail.body.encoded).to include "You have 23 hours left."
          end

          it "does not send once the evidence has been resolved" do
            dispute_evidence.update!(resolved_at: Time.current, resolution: DisputeEvidence::RESOLUTION_SUBMITTED)

            mail = ContactingCreatorMailer.chargeback_evidence_due_soon(dispute.id)

            expect(mail.message).to be_a(ActionMailer::Base::NullMail)
          end
        end

        context "when the evidence has been resolved by the time the mail renders" do
          before { dispute_evidence.update!(resolved_at: Time.current, resolution: DisputeEvidence::RESOLUTION_SUBMITTED) }

          it "does not ask for evidence the submission page will not accept" do
            mail = ContactingCreatorMailer.chargeback_notice(dispute.id)

            expect(mail.body.encoded).not_to include "Any additional information you can provide"
            expect(mail.body.encoded).not_to include "Submit additional information"
            expect(mail.subject).to eq "A sale has been disputed"
            expect(mail.body.encoded).to include "We fight every dispute."
          end
        end

        # An evidence row can exist with no window while a notice for it is still queued: the
        # sweep's push succeeded and the stamp write then failed. The form rejects that state too,
        # and quoting its window would read "in the next 0 hours".
        context "when the row exists but its window was never opened" do
          before { dispute_evidence.update!(seller_contacted_at: nil) }

          it "sends the plain notice without asking for evidence" do
            mail = ContactingCreatorMailer.chargeback_notice(dispute.id)

            expect(dispute_evidence.reload.hours_left_to_submit_evidence).to eq(0)
            expect(mail.body.encoded).not_to include "Any additional information you can provide"
            expect(mail.body.encoded).not_to include "in the next 0 hours"
            expect(mail.body.encoded).not_to include "Submit additional information"
            expect(mail.subject).to eq "A sale has been disputed"
            expect(mail.body.encoded).to include "We fight every dispute."
          end
        end
      end

      context "when the purchase was done via a PayPal Connect account" do
        before do
          purchase.update!(charge_processor_id: PaypalChargeProcessor.charge_processor_id)
        end

        it "includes copy about PayPal's dispute process" do
          mail = ContactingCreatorMailer.chargeback_notice(dispute.id)

          expect(mail.body.encoded).to include "A customer of yours (#{purchase.email}) has disputed their purchase of #{purchase.link.name} for #{purchase.formatted_disputed_amount}."
          expect(mail.body.encoded).to include "Unfortunately, we’re unable to fight disputes on purchases via PayPal Connect since we don’t have access to your PayPal account."
        end
      end
    end

    context "for a dispute on Charge" do
      let(:charge) do
        charge = create(:charge, seller:)
        charge.purchases << create(:purchase, link: create(:product, user: seller))
        charge.purchases << create(:purchase, link: create(:product, user: seller))
        charge.purchases << create(:purchase, link: create(:product, user: seller))
        charge
      end

      let(:dispute) { create(:dispute_formalized_on_charge, purchase: nil, charge:) }

      it "sends chargeback notice correctly" do
        mail = ContactingCreatorMailer.chargeback_notice(dispute.id)
        expect(mail.to).to eq [seller.email]
        expect(mail.subject).to eq "A sale has been disputed"

        expect(mail.body.encoded).to include "A customer of yours (#{charge.customer_email}) has disputed their purchase of the following items for #{charge.formatted_disputed_amount}."
        charge.disputed_purchases.each do |purchase|
          expect(mail.body.encoded).to include purchase.link.name
        end
        expect(mail.body.encoded).to include "We have deducted the amount from your balance, and are looking into it for you."
        expect(mail.body.encoded).to include "We fight every dispute. If we succeed, you will automatically be re-credited the full amount. This process takes up to 75 days."
        expect(mail.body.encoded).not_to include "Any additional information you can provide"
      end

      context "when the seller is contacted to submit evidence" do
        let!(:dispute_evidence) do
          create(:dispute_evidence_on_charge, dispute:)
        end

        it "includes copy to submit evidence" do
          mail = ContactingCreatorMailer.chargeback_notice(dispute.id)
          expect(mail.subject).to eq "🚨 Urgent: Action required for resolving disputed sale"

          expect(mail.body.encoded).to include "A customer of yours (#{charge.customer_email}) has disputed their purchase of the following items for #{charge.formatted_disputed_amount}."
          charge.disputed_purchases.each do |purchase|
            expect(mail.body.encoded).to include purchase.link.name
          end
          expect(mail.body.encoded).to include "Any additional information you can provide by"
          expect(mail.body.encoded).to include "(in the next 72 hours) will help us win on your behalf."
          expect(mail.body.encoded).to include "Submit additional information"
        end
      end

      context "when the purchase was done via a PayPal Connect account" do
        before do
          charge.update!(processor: PaypalChargeProcessor.charge_processor_id)
        end

        it "includes copy about PayPal's dispute process" do
          mail = ContactingCreatorMailer.chargeback_notice(dispute.id)

          expect(mail.body.encoded).to include "A customer of yours (#{charge.customer_email}) has disputed their purchase of the following items for #{charge.formatted_disputed_amount}."
          charge.disputed_purchases.each do |purchase|
            expect(mail.body.encoded).to include purchase.link.name
          end
          expect(mail.body.encoded).to include "Unfortunately, we’re unable to fight disputes on purchases via PayPal Connect since we don’t have access to your PayPal account."
        end
      end
    end
  end

  describe "preorder_release_reminder" do
    let(:preorder_link) { create(:preorder_link) }
    let(:product) { preorder_link.link }
    let(:seller) { product.user }

    context "for a physical product" do
      before do
        product.update!(is_physical: true, require_shipping: true)
      end
      it "sends the email with the the correct text" do
        email = ContactingCreatorMailer.preorder_release_reminder(product.id)

        expect(email.to).to eq [seller.form_email]
        expect(email.subject).to eq "Your pre-order will be released shortly"

        expect(email.body.encoded).to include "Your pre-order, #{product.name} will be released on"
        expect(email.body.encoded).to include "Charges will occur at that time."
        expect(email.body.encoded).to include "Your customers will be excited for #{product.name} to ship shortly after they are charged."
        expect(email.body.encoded).to_not include "You will need to upload a file before its release, or we won't be able to release the product and charge your customers"
      end
    end

    context "for a non-physical product" do
      context "when the product does not have delivery content saved" do
        before do
          allow_any_instance_of(Link).to receive(:has_content?).and_return(false)
        end
        it "sends the email with the the correct text" do
          email = ContactingCreatorMailer.preorder_release_reminder(product.id)

          expect(email.to).to eq [seller.form_email]
          expect(email.subject).to eq "Your pre-order will be released shortly"

          expect(email.body.encoded).to include "Your pre-order, #{product.name} is scheduled for a release on"
          expect(email.body.encoded).to include "You will need to"
          expect(email.body.encoded).to include "upload files or specify a redirect URL"
          expect(email.body.encoded).to include "before its release, or we won't be able to release the product and charge your customers."
        end
      end

      context "when the product has delivery content saved" do
        before do
          allow_any_instance_of(Link).to receive(:has_content?).and_return(true)
        end
        it "sends the email with the the correct text" do
          email = ContactingCreatorMailer.preorder_release_reminder(product.id)

          expect(email.to).to eq [seller.form_email]
          expect(email.subject).to eq "Your pre-order will be released shortly"

          expect(email.body.encoded).to include "Your pre-order, #{product.name} will be released on"
          expect(email.body.encoded).to include "Once released all credit cards will be charged."
          expect(email.body.encoded).to_not include "You will need to upload a file before its release, or we won't be able to release the product and charge your customers"
        end
      end
    end
  end

  describe "remind" do
    before do
      @user = create(:user, email: "blah@example.com")
      allow_any_instance_of(User).to receive(:secure_external_id).and_return("sample-secure-id")
    end

    it "sends out a reminder" do
      mail = ContactingCreatorMailer.remind(@user.id)
      expect(mail.to).to eq ["blah@example.com"]
      expect(mail.subject).to eq "Please add a payment account to Gumroad."
      expect(mail.body.encoded).to include user_unsubscribe_url(id: "sample-secure-id", email_type: :product_update)
    end
  end

  describe "seller_update" do
    # The mailer reports on "last week", which it defines as the seven days ending at the most
    # recent Sunday midnight (`Date.today.beginning_of_week(:sunday)`). These examples rely on
    # being able to create a purchase that lands *after* that window closes, so that it is
    # excluded from the totals — they do this with `5.minutes.ago`.
    #
    # That only holds if "now" is comfortably past Sunday midnight. When the suite runs during the
    # first minutes of a Sunday in UTC, the window closes at today's midnight, so `5.minutes.ago`
    # falls back into Saturday and is counted as part of last week — the excluded purchase silently
    # becomes an included one and the expected totals shift. Pinning the clock to a mid-week moment
    # keeps the window boundary a fixed distance from "now", so these examples do not depend on
    # which day of the week CI happens to run.
    before { travel_to(Time.utc(2024, 5, 1, 12, 0, 0)) } # a Wednesday

    before do
      @user = create(:user)
      allow_any_instance_of(User).to receive(:secure_external_id).and_return("sample-secure-id")
      end_of_period = Date.today.beginning_of_week(:sunday).to_datetime
      @start_of_period = end_of_period - 7.days
    end

    it "sends an update to the seller" do
      mail = ContactingCreatorMailer.seller_update(@user.id)
      expect(mail.subject).to eq "Your last week."
      expect(mail.to).to eq [@user.email]
      expect(mail.body.encoded).to include user_unsubscribe_url(id: "sample-secure-id", email_type: :seller_update)
    end

    describe "subscriptions" do
      before do
        @user = create(:user)
        @product = create(:subscription_product, user: @user)
        @product_subscription1 = create(:subscription, link: @product)
      end

      it "renders properly" do
        @product_subscription2 = create(:subscription, link: @product)
        link2 = create(:subscription_product, user: @user)
        link2_subscription1 = create(:subscription, link: link2)
        create(:purchase, subscription_id: @product_subscription1.id, is_original_subscription_purchase: true, link: @product, created_at: @start_of_period + 1.hour)
        create(:purchase, subscription_id: @product_subscription2.id, is_original_subscription_purchase: true, link: @product, created_at: @start_of_period + 1.hour)
        create(:purchase, subscription_id: link2_subscription1.id, is_original_subscription_purchase: true, link: link2, created_at: 17.days.ago)
        create(:purchase, subscription_id: link2_subscription1.id, is_original_subscription_purchase: false, link: link2, created_at: @start_of_period + 1.hour)

        mail = ContactingCreatorMailer.seller_update(@user.id)
        expect(mail.subject).to eq "Your last week."
        expect(mail.to).to eq [@user.email]
        expect(mail.body).to include @product.name
        expect(mail.body).to include "2 new subscriptions"
        expect(mail.body).to include link2.name
        expect(mail.body).to include "1 existing subscription"
      end

      it "does not show any new subscriptions" do
        create(:purchase, subscription_id: @product_subscription1.id, is_original_subscription_purchase: true, link: @product, created_at: 19.days.ago)
        create(:purchase, subscription_id: @product_subscription1.id, is_original_subscription_purchase: false, link: @product, created_at: @start_of_period + 1.hour)

        mail = ContactingCreatorMailer.seller_update(@user.id)
        expect(mail.subject).to eq "Your last week."
        expect(mail.to).to eq [@user.email]
        expect(mail.body).to include @product.name
        expect(mail.body).to include "1 existing subscription"
        expect(mail.body).to_not include "new subscription"
      end
    end

    describe "sales" do
      before do
        @user = create(:user)
        @product = create(:product, user: @user, is_recurring_billing: false, created_at: @start_of_period - 2.hours)
        @product2 = create(:product, user: @user, is_recurring_billing: false, created_at: @start_of_period - 2.hours)
        2.times { create(:purchase, link: @product, created_at: @start_of_period + 1.hour) }
        create(:purchase, link: @product, created_at: 5.minutes.ago)
        create(:purchase, link: @product2, created_at: @start_of_period + 1.hour)
        create(:purchase, link: @product2, created_at: @start_of_period + 1.hour, chargeback_date: DateTime.current)
      end

      it "renders properly" do
        mail = ContactingCreatorMailer.seller_update(@user.id)
        expect(mail.subject).to eq "Your last week."
        expect(mail.to).to eq [@user.email]
        expect(mail.body).to include "$0.21" # 3 not-chargebacked purchases * 7¢ each.
        expect(mail.body).to include @product.name
        expect(mail.body).to include "2 sales"
        expect(mail.body).to include @product2.name
        expect(mail.body).to include "1 sale"
      end
    end
  end

  describe "credit_notification" do
    before do
      @user = create(:user)
    end

    it "notifies user about credit to their account" do
      mail = ContactingCreatorMailer.credit_notification(@user.id, 200)
      expect(mail.to).to eq [@user.email]
      expect(mail.subject).to eq "You've received Gumroad credit!"
      expect(mail.body.encoded).to include "$2"
    end

    it "includes the reason in the body when one is given" do
      mail = ContactingCreatorMailer.credit_notification(@user.id, 200, "Thanks for reporting the checkout bug")
      expect(mail.body.encoded).to include "Thanks for reporting the checkout bug"
    end

    it "preserves line breaks in a multi-line reason" do
      mail = ContactingCreatorMailer.credit_notification(@user.id, 200, "Refunded the duplicate charge.\nAdded a little extra for the trouble.")
      body = (mail.html_part || mail).body.decoded
      expect(body).to match(%r{Refunded the duplicate charge\.\s*<br\s*/?>\s*Added a little extra for the trouble})
    end
  end

  describe "gumroad_day_credit_notification" do
    before do
      @user = create(:user)
    end

    it "notifies user about credit to their account" do
      mail = ContactingCreatorMailer.gumroad_day_credit_notification(@user.id, 200)
      expect(mail.to).to eq [@user.email]
      expect(mail.subject).to eq "You've received Gumroad credit!"
      expect(mail.body.encoded).to include "$2"
    end
  end

  describe "notify" do
    let(:seller) { create(:user, email: "seller@example.com") }
    let(:buyer) { create(:user, email: "buyer@example.com") }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product, seller: product.user) }

    before do
      Feature.activate(:send_sales_notifications_to_creator_app)
    end

    def expect_push_alert(seller_id, text)
      expect(PushNotificationWorker).to have_enqueued_sidekiq_job(seller_id,
                                                                  Device::APP_TYPES[:creator],
                                                                  text, nil, {}, "chaching.wav")
    end

    it "uses SUPPORT_EMAIL as from address" do
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
    end

    it "works normally" do
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New sale of #{product.name} for #{purchase.formatted_total_price}"
      expect(mail.to).to eq([seller.email])

      expect_push_alert(seller.id, mail.subject)
    end

    it "displays the resolved tiered offer code discount" do
      product = create(:product, user: seller, price_cents: 2_00)
      offer_code = create(:tiered_offer_code, :for_existing_customers, name: "Renewal discount", products: [product], ownership_products: [product], user: seller)
      purchase = create(:purchase, link: product, seller: product.user, purchaser: buyer, email: buyer.email, offer_code:, displayed_price_cents: 1_00, price_cents: 1_00)
      purchase.create_purchase_offer_code_discount!(
        offer_code:,
        offer_code_amount: 50,
        offer_code_is_percent: true,
        pre_discount_minimum_price_cents: 2_00,
        duration_in_months: nil
      )

      mail = ContactingCreatorMailer.notify(purchase.id)

      expect(mail.body.decoded).to include("Renewal discount")
      expect(mail.body.decoded).to include("50% off")
      expect(mail.body.decoded).not_to include("(0% off)")
    end

    it "works for $0 purchases" do
      product = create(:product, user: seller, price_cents: 0, customizable_price: true)
      purchase = create(:purchase, link: product, seller: product.user, stripe_transaction_id: nil, stripe_fingerprint: nil)
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New download of #{product.name}"

      expect_push_alert(seller.id, mail.subject)
    end

    it "works without a purchaser" do
      purchase.create_url_redirect!
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New sale of #{product.name} for #{purchase.formatted_total_price}"

      expect_push_alert(seller.id, mail.subject)
    end

    it "does not work without a buyer email" do
      seller = create(:user, email: "bob@gumroad.com")
      buyer = create(:user, email: "bob2@gumroad.com")
      link = create(:product, user: seller)
      purchase = create(:purchase, link:, purchaser: buyer, seller: link.user)
      expect(purchase.update(email: nil)).to be(false)
    end

    it "includes discover notice and sets the referrer to Gumroad Discover" do
      seller = create(:user, email: "bob@gumroad.com")
      buyer = create(:user, email: "bob2@gumroad.com")
      link = create(:physical_product, user: seller)
      purchase = create(:physical_purchase, link:, purchaser: buyer, seller: link.user, was_discover_fee_charged: true, referrer: UrlService.discover_domain_with_protocol)
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.body.encoded).to include "Referrer"
      expect(mail.body.encoded).to include "<a href=\"#{UrlService.discover_domain_with_protocol}\" target=\"_blank\">Gumroad Discover</a>"

      expect_push_alert(seller.id, mail.subject)
    end

    it "sets the referrer to Direct when the referrer URL equals 'direct'" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product, user: seller)
      purchase = create(:purchase, link: product, email: "ibuy@gumroad.com", referrer: "direct")
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.body.encoded).to include "Referrer"
      expect(mail.body.encoded).to include "Direct"

      expect_push_alert(seller.id, mail.subject)
    end

    it "sets the referrer to Profile when the referrer URL is from the seller's profile" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product, user: seller)
      purchase = create(:purchase, link: product, email: "ibuy@gumroad.com", referrer: "https://#{seller.username}.gumroad.com")
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.body.encoded).to include "Referrer"
      expect(mail.body.encoded).to include "<a href=\"https://#{seller.username}.gumroad.com\" target=\"_blank\">Profile</a>"

      expect_push_alert(seller.id, mail.subject)
    end

    it "sets the referrer to Twitter when the referrer URL is from twitter" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product, user: seller)
      purchase = create(:purchase, link: product, email: "ibuy@gumroad.com", referrer: "https://twitter.com/")
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.body.encoded).to include "Referrer"
      expect(mail.body.encoded).to include '<a href="https://twitter.com/" target="_blank">Twitter</a>'

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes quantity if greater than 1" do
      seller = create(:user, email: "bob@gumroad.com")
      buyer = create(:user, email: "bob2@gumroad.com")
      link = create(:physical_product, user: seller)
      purchase = create(:physical_purchase, link:, purchaser: buyer, seller: link.user, quantity: 3)
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New sale of #{link.name} for #{purchase.formatted_total_price}"
      expect(mail.body.encoded).to include "Quantity"
      expect(mail.body.encoded).to include "3"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes product price, shipping cost, and total transaction" do
      seller = create(:user, email: "bob@gumroad.com")
      buyer = create(:user, email: "bob2@gumroad.com")
      link = create(:physical_product, user: seller)
      purchase = create(:physical_purchase, link:, purchaser: buyer, seller: link.user, quantity: 3, shipping_cents: 400, price_cents: 500)
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New sale of #{link.name} for #{purchase.formatted_total_price}"
      expect(mail.body.encoded).to include "Product price"
      expect(mail.body.encoded).to include "$1"
      expect(mail.body.encoded).to include "Shipping"
      expect(mail.body.encoded).to include "$4"
      expect(mail.body.encoded).to include "Order total"
      expect(mail.body.encoded).to include "$5"
      expect(mail.body.encoded).to include "Shipping address"
      expect(mail.body.encoded).to include "barnabas"
      expect(mail.body.encoded).to include "123 barnabas street"
      expect(mail.body.encoded).to include "barnabasville, CA 94114"
      expect(mail.body.encoded).to include "United States"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes product price, nonzero tax, and total transaction" do
      seller = create(:user, email: "bob@gumroad.com")
      buyer = create(:user, email: "bob2@gumroad.com")
      link = create(:product, user: seller)
      purchase = create(:purchase,
                        link:,
                        purchaser: buyer,
                        seller: link.user,
                        quantity: 1,
                        tax_cents: 40,
                        price_cents: 140,
                        was_purchase_taxable: true,
                        was_tax_excluded_from_price: true,
                        zip_tax_rate: create(:zip_tax_rate))
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New sale of #{link.name} for #{purchase.formatted_total_price}"
      expect(mail.body.encoded).to include "Product price"
      expect(mail.body.encoded).to include "$1"
      expect(mail.body.encoded).to include "Sales tax"
      expect(mail.body.encoded).to include "$0.40"
      expect(mail.body.encoded).to include "Order total"
      expect(mail.body.encoded).to include "$1.40"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes product price, nonzero VAT, and total transaction" do
      seller = create(:user, email: "bob@gumroad.com")
      buyer = create(:user, email: "bob2@gumroad.com")
      link = create(:product, user: seller)
      purchase = create(:purchase,
                        link:,
                        purchaser: buyer,
                        seller: link.user,
                        quantity: 1,
                        tax_cents: 40,
                        price_cents: 140,
                        was_purchase_taxable: true,
                        was_tax_excluded_from_price: true,
                        zip_tax_rate: create(:zip_tax_rate, country: "DE"))
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New sale of #{link.name} for #{purchase.formatted_total_price}"
      expect(mail.body.encoded).to include "Product price"
      expect(mail.body.encoded).to include "$1"
      expect(mail.body.encoded).to include "EU VAT"
      expect(mail.body.encoded).to include "$0.40"
      expect(mail.body.encoded).to include "Order total"
      expect(mail.body.encoded).to include "$1.40"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes product price, nonzero VAT inclusive, and total transaction" do
      seller = create(:user, email: "bob@gumroad.com")
      buyer = create(:user, email: "bob2@gumroad.com")
      link = create(:product, user: seller)
      purchase = create(:purchase,
                        link:,
                        purchaser: buyer,
                        seller: link.user,
                        quantity: 1,
                        tax_cents: 40,
                        price_cents: 140,
                        was_purchase_taxable: true,
                        was_tax_excluded_from_price: false,
                        zip_tax_rate: create(:zip_tax_rate, country: "DE"))
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New sale of #{link.name} for #{purchase.formatted_total_price}"
      expect(mail.body.encoded).to include "Product price"
      expect(mail.body.encoded).to include "$1"
      expect(mail.body.encoded).to include "EU VAT (included)"
      expect(mail.body.encoded).to include "$0.40"
      expect(mail.body.encoded).to include "Order total"
      expect(mail.body.encoded).to include "$1.40"

      expect_push_alert(seller.id, mail.subject)
    end

    it "does not include tax if it is 0" do
      seller = create(:user, email: "bob@gumroad.com")
      buyer = create(:user, email: "bob2@gumroad.com")
      link = create(:product, user: seller)
      purchase = create(:purchase,
                        link:,
                        purchaser: buyer,
                        seller: link.user,
                        quantity: 1,
                        tax_cents: 0,
                        price_cents: 100,
                        was_purchase_taxable: true,
                        was_tax_excluded_from_price: true,
                        zip_tax_rate: create(:zip_tax_rate))
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New sale of #{link.name} for #{purchase.formatted_total_price}"
      expect(mail.body.encoded).to include "Product price"
      expect(mail.body.encoded).to include "$1"
      expect(mail.body.encoded).to_not include "Sales tax"
      expect(mail.body.encoded).to include "Order total"
      expect(mail.body.encoded).to include "$1"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes product price, shipping cost, and total transaction for jpy" do
      seller = create(:user, email: "bob@gumroad.com")
      buyer = create(:user, email: "bob2@gumroad.com")
      link = create(:physical_product, user: seller, price_currency_type: "jpy")
      purchase = create(:physical_purchase, link:, purchaser: buyer, seller: link.user, shipping_cents: 400, price_cents: 528, displayed_price_cents: 100, displayed_price_currency_type: "jpy")
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New sale of #{link.name} for #{purchase.formatted_total_price}"
      expect(mail.body.encoded).to include "Product price"
      expect(mail.body.encoded).to include "¥100"
      expect(mail.body.encoded).to include "Shipping"
      expect(mail.body.encoded).to include "¥314"
      expect(mail.body.encoded).to include "Order total"
      expect(mail.body.encoded).to include "¥414"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes discount information" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product, user: seller, price_cents: 500)
      offer_code = create(:percentage_offer_code, products: [product], name: "Black Friday", amount_percentage: 10)
      purchase = create(:purchase, link: product, email: "ibuy@gumroad.com", offer_code:)
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.body.encoded).to include "Discount"
      expect(Nokogiri::HTML(mail.body.encoded).text).to include "Black Friday (10% off)"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes upsell information without offer code" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product_with_digital_versions, user: seller)
      upsell = create(:upsell, product:, name: "Complete course", seller:)
      upsell_variant = create(:upsell_variant, upsell:, selected_variant: product.alive_variants.first, offered_variant: product.alive_variants.second)
      upsell_purchase = create(:upsell_purchase, upsell:, upsell_variant:)
      mail = ContactingCreatorMailer.notify(upsell_purchase.purchase.id)
      expect(mail.body.encoded).to include "Upsell"
      expect(mail.body.encoded).to include "Complete course"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes upsell information with offer code" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product_with_digital_versions, user: seller, price_cents: 1000)
      offer_code = create(:percentage_offer_code, user: seller, products: [product], amount_percentage: 20)
      upsell = create(:upsell, product:, name: "Complete course", seller:, offer_code:)
      upsell_variant = create(:upsell_variant, upsell:, selected_variant: product.alive_variants.first, offered_variant: product.alive_variants.second)
      upsell_purchase = create(:upsell_purchase, upsell:, upsell_variant:)
      upsell_purchase.purchase.create_purchase_offer_code_discount!(
        offer_code:,
        offer_code_amount: 20,
        offer_code_is_percent: true,
        pre_discount_minimum_price_cents: product.price_cents,
        duration_in_months: nil
      )
      mail = ContactingCreatorMailer.notify(upsell_purchase.purchase.id)
      expect(mail.body.encoded).to include "Upsell"
      expect(Nokogiri::HTML(mail.body.encoded).text).to include "Complete course (20% off)"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes variant information" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product_with_digital_versions, user: seller)
      variant = product.variant_categories_alive.first.variants.first
      purchase = create(:purchase, link: product, email: "ibuy@gumroad.com", variant_attributes: [variant])
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.body.encoded).to include "Variant"
      expect(mail.body.encoded).to include "(Untitled 1)"

      expect_push_alert(seller.id, mail.subject)
    end

    context "when the product is a membership product" do
      it "includes tier information" do
        seller = create(:user, email: "bob@gumroad.com")
        product = create(:membership_product_with_preset_tiered_pricing, user: seller)
        purchase = create(:membership_purchase, link: product, email: "ibuy@gumroad.com", variant_attributes: [product.default_tier])
        mail = ContactingCreatorMailer.notify(purchase.id)
        expect(mail.body.encoded).to include "Tier"
        expect(mail.body.encoded).to include "(First Tier)"

        expect_push_alert(seller.id, mail.subject)
      end
    end

    it "includes the affiliate commission information when 'apply_to_all_products' is true" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product, user: seller, price_cents: 10_00)
      affiliate_user = create(:affiliate_user)
      direct_affiliate = create(:direct_affiliate, affiliate_user:, seller:, affiliate_basis_points: 5_00, apply_to_all_products: true)
      create(:product_affiliate, product:, affiliate: direct_affiliate, affiliate_basis_points: 10_00)
      purchase = create(:purchase_in_progress, link: product, email: "ibuy@gumroad.com", purchase_state: "in_progress", affiliate: direct_affiliate)
      purchase.process!
      purchase.update_balance_and_mark_successful!
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.body.encoded).to include "Affiliate email"
      expect(mail.body.encoded).to include affiliate_user.form_email
      expect(mail.body.encoded).to include "Affiliate commission"
      expect(mail.body.encoded).to include "$0.50 (5%)"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes the product commission information when 'apply_to_all_products' is false" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product, user: seller, price_cents: 10_00)
      affiliate_user = create(:affiliate_user)
      direct_affiliate = create(:direct_affiliate, affiliate_user:, seller:, apply_to_all_products: false)
      create(:product_affiliate, product:, affiliate: direct_affiliate, affiliate_basis_points: 10_00)
      purchase = create(:purchase_in_progress, link: product, email: "ibuy@gumroad.com", purchase_state: "in_progress", affiliate: direct_affiliate)
      purchase.process!
      purchase.update_balance_and_mark_successful!
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.body.encoded).to include "Affiliate email"
      expect(mail.body.encoded).to include affiliate_user.form_email
      expect(mail.body.encoded).to include "Affiliate commission"
      expect(mail.body.encoded).to include "$1 (10%)"

      expect_push_alert(seller.id, mail.subject)
    end

    it "does not include affiliate information when price is $0" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product, user: seller, price_cents: 0, customizable_price: true)
      affiliate_user = create(:affiliate_user)
      direct_affiliate = create(:direct_affiliate, affiliate_user:, seller:)
      create(:product_affiliate, product:, affiliate: direct_affiliate, affiliate_basis_points: 10_00)
      purchase = create(:purchase_in_progress, link: product, email: "ibuy@gumroad.com", purchase_state: "in_progress", affiliate: direct_affiliate)
      purchase.process!
      purchase.update_balance_and_mark_successful!
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.body.encoded).to_not include "Affiliate commission"

      expect_push_alert(seller.id, mail.subject)
    end

    context "for a collab product" do
      let(:product) { create(:product, price_cents: 20_00) }
      let(:seller) { product.user }
      let(:collaborator) { create(:collaborator) }
      let(:purchase) { create(:purchase_in_progress, link: product, email: "ibuy@gumroad.com", affiliate: collaborator) }

      before do
        create(:product_affiliate, affiliate: collaborator, product:, affiliate_basis_points: 50_00)
        purchase.process!
        purchase.update_balance_and_mark_successful!
      end

      it "includes the collaborator information" do
        mail = ContactingCreatorMailer.notify(purchase.id)
        expect(mail.body.encoded).to include "Collaborator email"
        expect(mail.body.encoded).to include collaborator.affiliate_user.form_email
        expect(mail.body.encoded).to include "Collaborator commission"
        expect(mail.body.encoded).to include "$10 (50%)"
      end
    end

    context "when send_creator_notifications_to_consumer_app feature flag is enabled" do
      before do
        Feature.activate(:send_sales_notifications_to_consumer_app)
      end

      it "sends sale notification to both creator and consumer apps" do
        mail = ContactingCreatorMailer.notify(purchase.id)

        expect_push_alert(seller.id, mail.subject)
        expect(PushNotificationWorker).to have_enqueued_sidekiq_job(seller.id,
                                                                    Device::APP_TYPES[:consumer],
                                                                    mail.subject, nil, {}, "chaching.wav")
      end
    end

    context "when the purchase is a gift" do
      it "adds a row displaying the giftee's email" do
        seller = create(:user, email: "bob@gumroad.com")
        product = create(:product, user: seller)
        purchase = create(:purchase, link: product, email: "ibuy@gumroad.com", is_gift_sender_purchase: true)
        create(:gift, gifter_email: "ibuy@gumroad.com", giftee_email: "giftee@gumroad.com", link: @product, gifter_purchase: purchase)
        mail = ContactingCreatorMailer.notify(purchase.id)
        expect(mail.body.encoded).to include "Giftee email"
        expect(mail.body.encoded).to include "giftee@gumroad.com"

        expect_push_alert(seller.id, mail.subject)
      end
    end

    context "when the purchase is via staff picks" do
      before do
        purchase.update!(recommended_by: RecommendationType::GUMROAD_STAFF_PICKS_RECOMMENDATION)
      end

      it "includes subheading about staff picks" do
        mail = ContactingCreatorMailer.notify(purchase.id)
        expect(mail.body.encoded).to include "via Staff picks in <a href=\"#{UrlService.discover_domain_with_protocol}\" target=\"_blank\">Discover</a>"
      end
    end


    context "when the purchase is via more like this" do
      before do
        purchase.update!(was_product_recommended: true, recommended_by: RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION, referrer: "gumroad.com")
      end

      it "includes subheading about more like this" do
        mail = ContactingCreatorMailer.notify(purchase.id)
        expect(mail.body.encoded).to include "via More like this recommendations"
      end

      it "includes more like this as the referrer" do
        mail = ContactingCreatorMailer.notify(purchase.id)
        expect(mail.body.encoded).to include "Referrer"
        expect(mail.body.encoded).to include '<a href="gumroad.com" target="_blank">Gumroad Product Recommendations</a>'
      end
    end

    describe "subscription purchases" do
      context "for original purchase" do
        it "renders the correct subject" do
          purchase = create(:membership_purchase)

          mail = ContactingCreatorMailer.notify(purchase.id)
          expect(mail.subject).to match(/^You have a new subscriber for /)

          expect_push_alert(purchase.seller.id, mail.subject)
        end
      end

      context "for recurring purchase" do
        it "renders the correct subject" do
          purchase = create(:recurring_membership_purchase, is_original_subscription_purchase: false)

          mail = ContactingCreatorMailer.notify(purchase.id)
          expect(mail.subject).to eq("New recurring charge for #{purchase.link.name} of #{purchase.formatted_total_price}")

          expect_push_alert(purchase.seller.id, mail.subject)
        end
      end

      context "for upgrade purchase" do
        it "renders the correct subject" do
          purchase = create(:recurring_membership_purchase, is_original_subscription_purchase: false)
          purchase.is_upgrade_purchase = true
          purchase.save!

          mail = ContactingCreatorMailer.notify(purchase.id)
          expect(mail.subject).to eq("A subscriber has upgraded their subscription for #{purchase.link.name} and was charged #{purchase.formatted_total_price}")

          expect_push_alert(purchase.seller.id, mail.subject)
        end
      end
    end

    describe "test purchases" do
      it "works without a purchase" do
        seller = create(:user)
        link = create(:product, user: seller)
        mail = ContactingCreatorMailer.notify(nil, false, "bob@gumroad.com", link.id)
        expect(mail.subject).to eq "New sale of #{link.name} for #{link.price_formatted}"

        expect_push_alert(seller.id, mail.subject)
      end

      it "works without a purchase with variants" do
        seller = create(:user)
        link = create(:product, user: seller)
        mail = ContactingCreatorMailer.notify(nil, false, "another@gumroad.com", link.id, nil, %w[blue small])
        expect(mail.subject).to eq "New sale of #{link.name} for #{link.price_formatted}"

        expect_push_alert(seller.id, mail.subject)
      end

      it "works without a purchase with shipping info" do
        seller = create(:user)
        link = create(:product, user: seller, require_shipping: true)
        shipping_info = { full_name: "Jim Banshee", street_address: "40 Queensdale Boulevard", zip_code: 12_345,
                          city: "Dalesfieldvilleton City", country: "USA", state: "Iowa" }
        mail = ContactingCreatorMailer.notify(nil, false, "yetanother@gumroad.com", link.id, nil, nil, shipping_info)
        expect(mail.subject).to eq "New sale of #{link.name} for #{link.price_formatted}"

        expect_push_alert(seller.id, mail.subject)
      end

      it "works with a price range" do
        seller = create(:user)
        link = create(:product, user: seller)
        mail = ContactingCreatorMailer.notify(nil, false, "blue@gumroad.com", link.id, 400, nil, nil)
        expect(mail.subject).to eq "New sale of #{link.name} for $4"

        expect_push_alert(seller.id, mail.subject)
      end

      describe "payment notification settings" do
        before do
          @user = create(:user, email: "blah@gumroad.com")
          @link = create(:product, user: @user)
          @purchase = create(:purchase, link: @link, seller: @link.user)
        end

        context "with default notification settings" do
          it "sends email and push notification" do
            mail = ContactingCreatorMailer.notify(@purchase.id)
            expect(mail.subject).to eq "New sale of #{@link.name} for #{@purchase.formatted_total_price}"
            expect(mail.to).to eq(["blah@gumroad.com"])
            expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])

            expect_push_alert(@user.id, mail.subject)
          end
        end

        context "with email notifications disabled" do
          before do
            @user.enable_payment_email = false
            @user.save!
          end

          it "does not sends email but sends push notification" do
            mail = ContactingCreatorMailer.notify(@purchase.id)
            expect(mail.message).to be_a(ActionMailer::Base::NullMail)

            expect_push_alert(@user.id, "New sale of #{@link.name} for #{@purchase.formatted_total_price}")
          end

          context "with push notifications disabled" do
            before do
              @user.enable_payment_push_notification = false
              @user.save!
            end

            it "does not sends email or push notifications" do
              mail = ContactingCreatorMailer.notify(@purchase.id)
              expect(mail.message).to be_a(ActionMailer::Base::NullMail)

              expect(PushNotificationWorker.jobs.size).to eq(0)
            end
          end
        end
      end
    end

    describe "pre-orders" do
      it "delivers notification with pre order subject" do
        creator = create(:user)
        product = create(:product, user: creator)
        purchase = create(:preorder_authorization_purchase, link: product, seller: product.user)
        mail = ContactingCreatorMailer.notify(purchase.id, true)
        expect(mail.subject).to eq "New pre-order of #{product.name} for #{purchase.formatted_total_price}"

        expect_push_alert(creator.id, mail.subject)
      end
    end

    describe "coffee products" do
      it "excludes quantity and variant from email" do
        product = create(:coffee_product)
        purchase = create(:purchase, link: product, seller: product.user)
        mail = ContactingCreatorMailer.notify(purchase.id, true)
        expect(mail.body.encoded).to_not include "Quantity"
        expect(mail.body.encoded).to_not include "Variant"
      end
    end

    describe "call products" do
      let(:variant_category) { call.link.variant_categories.first }

      context "call that starts and ends on the same day" do
        let(:call) { create(:call, :skip_validation, start_time: DateTime.parse("2023-05-15 14:30 UTC"), end_time: DateTime.parse("2023-05-15 15:30 UTC")) }

        before do
          call.purchase.update!(variant_attributes: [create(:variant, name: "60 minutes", duration_in_minutes: 60, variant_category:)])
        end

        it "includes call information in the email" do
          mail = ContactingCreatorMailer.notify(call.purchase.id)

          expect(mail.body.encoded).to include("Call schedule")
          expect(mail.body.encoded).to include("07:30 AM - 08:30 AM PDT")
          expect(mail.body.encoded).to include("Monday, May 15th, 2023")
          expect(mail.body.encoded).to include("Duration")
          expect(mail.body.encoded).to include("60 minutes")
          expect(mail.body.encoded).not_to include("Quantity")
          expect(mail.body.encoded).not_to include("Variant")
        end
      end

      context "call that spans multiple days" do
        let(:call) { create(:call, :skip_validation, start_time: DateTime.parse("2023-05-15 22:30 PDT"), end_time: DateTime.parse("2023-05-16 01:30 PDT")) }

        before do
          call.purchase.update!(variant_attributes: [create(:variant, name: "3 hours", duration_in_minutes: 180, variant_category:)])
        end

        it "includes call information for multi-day calls" do
          mail = ContactingCreatorMailer.notify(call.purchase.id)

          expect(mail.body.encoded).to include("Call schedule")
          expect(mail.body.encoded).to include("10:30 PM - 01:30 AM PDT")
          expect(mail.body.sanitized).to include("Monday, May 15th, 2023 - Tuesday, May 16th, 2023")
          expect(mail.body.encoded).to include("Duration")
          expect(mail.body.encoded).to include("3 hours")
        end
      end
    end

    context "purchase with tip", :vcr do
      before { purchase.create_tip(value_cents: 100, value_usd_cents: 100) }

      it "includes the tip details" do
        mail = ContactingCreatorMailer.notify(purchase.id)

        expect(mail.body.sanitized).to include("$1 The Works of Edgar Gumstein")
        expect(mail.body.sanitized).to include("Tip $1")
      end
    end

    context "commission deposit purchase", :vcr do
      let(:commission) { create(:commission) }

      it "includes the commission details" do
        mail = ContactingCreatorMailer.notify(commission.deposit_purchase.id)

        expect(mail.subject).to eq ("New sale of The Works of Edgar Gumstein for $2")
        expect(mail.body.sanitized).to include("$2 The Works of Edgar Gumstein")
        expect(mail.body.sanitized).to include("Deposit paid $1")
      end
    end

    it "includes the UTM link driven sale details" do
      utm_link = create(:utm_link, seller: purchase.seller, utm_source: "twitter", utm_medium: "social", utm_campaign: "gumroad-day", utm_term: "gumroad-day-123", utm_content: "gumroad-day-56")
      create(:utm_link_driven_sale, purchase:, utm_link:)

      mail = ContactingCreatorMailer.notify(purchase.id)

      body = mail.body.sanitized
      expect(body).to include("UTM link driven sale")
      expect(body).to include("Link: #{utm_link.title}")
      expect(body).to include("Source: twitter")
      expect(body).to include("Medium: social")
      expect(body).to include("Campaign: gumroad-day")
      expect(body).to include("Term: gumroad-day-123")
      expect(body).to include("Content: gumroad-day-56")
      expect(mail.body.encoded).to have_link("UTM link", href: utm_link.utm_url)
      expect(mail.body.encoded).to have_link(utm_link.title, href: dashboard_utm_links_url(query: utm_link.title))
    end
  end

  describe "subscription_cancelled" do
    context "memberships" do
      before do
        @product = create(:product, subscription_duration: "monthly")
        @subscriber = create(:user)
        @subscription = create(:subscription, link: @product, user: @subscriber)
        @purchase = create(:purchase, link: @product, is_original_subscription_purchase: true, subscription: @subscription)
      end

      it "has the correct text" do
        mail = ContactingCreatorMailer.subscription_cancelled(@subscription.id)
        expect(mail.subject).to eq "A subscription has been canceled."
        expect(mail.body.encoded).to include @subscriber.email
        expect(mail.body.encoded).to include @product.name
      end
    end

    context "installment plans" do
      let(:installment_plan_purchase) { create(:installment_plan_purchase) }
      let(:subscription) { installment_plan_purchase.subscription }

      it "has the correct text" do
        mail = ContactingCreatorMailer.subscription_cancelled(subscription.id)
        expect(mail.subject).to eq "An installment plan has been canceled."
        expect(mail.body.encoded).to include subscription.email
        expect(mail.body.encoded).to include subscription.link.name
      end
    end
  end

  describe "subscription_autocancelled" do
    context "memberships" do
      before do
        @product = create(:product)
        @subscriber = create(:user)
        @subscription = create(:subscription, link: @product, user: @subscriber)
      end

      it "has the correct text" do
        mail = ContactingCreatorMailer.subscription_autocancelled(@subscription.id)
        expect(mail.subject).to eq "A subscription has been canceled."
        expect(mail.body.encoded).to include @product.name
        expect(mail.body.encoded).to include @subscriber.email
      end

      it "includes the purchase failure if available" do
        purchase = create(:purchase, is_original_subscription_purchase: true, link: @product, stripe_error_code: "2000", card_type: CardType::PAYPAL, subscription: @subscription)
        purchase.update_attribute(:purchase_state, "failed")
        mail = ContactingCreatorMailer.subscription_autocancelled(@subscription.id)
        expect(mail.subject).to eq "A subscription has been canceled."
        expect(mail.body.encoded).to include @product.name
        expect(mail.body.encoded).to include @subscriber.email
        expect(mail.body.encoded).to include purchase.formatted_error_code
        expect(mail.body.encoded).to include "For reference, PayPal gave us this error message for the last failure:"
      end

      it "includes non-paypal purchase failure if available" do
        purchase = create(:purchase, is_original_subscription_purchase: true, link: @product, stripe_error_code: "2000", card_type: CardType::MASTERCARD, subscription: @subscription)
        purchase.update_attribute(:purchase_state, "failed")
        mail = ContactingCreatorMailer.subscription_autocancelled(@subscription.id)
        expect(mail.subject).to eq "A subscription has been canceled."
        expect(mail.body.encoded).to include @product.name
        expect(mail.body.encoded).to include @subscriber.email
        expect(mail.body.encoded).to include purchase.formatted_error_code
        expect(mail.body.encoded).to include "For reference, your card issuer gave us this error message for the last failure:"
      end
    end

    context "installment plans" do
      let(:installment_plan_purchase) { create(:installment_plan_purchase) }
      let(:subscription) { installment_plan_purchase.subscription }

      it "has the correct text" do
        mail = ContactingCreatorMailer.subscription_autocancelled(subscription.id)
        expect(mail.subject).to eq "An installment plan has been paused."
        expect(mail.body.encoded).to include subscription.link.name
        expect(mail.body.encoded).to include subscription.email
      end

      it "includes the purchase failure if available" do
        installment_plan_purchase.update_columns(
          purchase_state: "failed",
          stripe_error_code: "2000",
          card_type: CardType::PAYPAL
        )
        mail = ContactingCreatorMailer.subscription_autocancelled(subscription.id)
        expect(mail.subject).to eq "An installment plan has been paused."
        expect(mail.body.encoded).to include subscription.link.name
        expect(mail.body.encoded).to include subscription.email
        expect(mail.body.encoded).to include installment_plan_purchase.formatted_error_code
        expect(mail.body.encoded).to include "For reference, PayPal gave us this error message for the last failure:"
      end
    end
  end

  describe "subscription_downgraded" do
    it "has the correct text" do
      product = create(:membership_product_with_preset_tiered_pricing)
      new_tier = product.tiers.last
      purchase = create(:membership_purchase, link: product, variant_attributes: [product.default_tier])
      subscription = purchase.subscription
      plan_change = subscription.subscription_plan_changes.create!(tier: new_tier, perceived_price_cents: 1599, recurrence: "yearly")
      downgrade_date = subscription.end_time_of_subscription.in_time_zone(subscription.user.timezone).to_fs(:formatted_date_full_month)

      mail = ContactingCreatorMailer.subscription_downgraded(subscription.id, plan_change.id)

      expect(mail.subject).to eq "A subscription has been downgraded."
      expect(mail.body.encoded).to include "has elected to downgrade their subscription to #{product.name}"
      expect(mail.body.encoded).to include new_tier.name
      expect(mail.body.encoded).to include downgrade_date
    end
  end

  describe "subscription_restarted" do
    context "memberships" do
      it "has the correct text" do
        product = create(:membership_product_with_preset_tiered_pricing)
        purchase = create(:membership_purchase, link: product, variant_attributes: [product.default_tier])
        subscription = purchase.subscription

        mail = ContactingCreatorMailer.subscription_restarted(subscription.id)

        expect(mail.subject).to eq "A subscription has been restarted."
        expect(mail.body.encoded).to include "has restarted their subscription to #{product.name}"
      end
    end

    context "installment plans" do
      let(:installment_plan_purchase) { create(:installment_plan_purchase) }
      let(:subscription) { installment_plan_purchase.subscription }

      it "has the correct text" do
        mail = ContactingCreatorMailer.subscription_restarted(subscription.id)
        expect(mail.subject).to eq "An installment plan has been restarted."
        expect(mail.body.encoded).to include "has restarted their installment plan for #{subscription.link.name}"
      end
    end
  end

  describe "subscription_product_deleted" do
    context "memberships" do
      let(:product) { create(:subscription_product) }

      it "has the correct text" do
        mail = ContactingCreatorMailer.subscription_product_deleted(product.id)
        expect(mail.subject).to eq "Subscriptions have been canceled"
        expect(mail.body.encoded).to include "Subscriptions for product #{product.name} have been canceled due to the deletion of the product"
      end
    end

    context "installment plans" do
      let(:product) { create(:product) }

      it "has the correct text" do
        mail = ContactingCreatorMailer.subscription_product_deleted(product.id)
        expect(mail.subject).to eq "Installment plans have been canceled"
        expect(mail.body.encoded).to include "Installment plans for product #{product.name} have been canceled due to the deletion of the product"
      end
    end
  end

  describe "subscription_ended" do
    context "memberships" do
      let(:membership_purchase) { create(:membership_purchase) }
      let(:subscription) { membership_purchase.subscription }
      let(:product) { subscription.link }

      it "has the correct text" do
        mail = ContactingCreatorMailer.subscription_ended(subscription.id)
        expect(mail.subject).to eq "A subscription has ended."
        expect(mail.body.encoded).to include "A subscription to #{product.name} has expired for your subscriber #{subscription.email}"
      end
    end

    context "installment plans" do
      let(:installment_plan_purchase) { create(:installment_plan_purchase) }
      let(:subscription) { installment_plan_purchase.subscription }

      it "has the correct text" do
        mail = ContactingCreatorMailer.subscription_ended(subscription.id)
        expect(mail.subject).to eq "An installment plan has been paid in full."
        expect(mail.body.encoded).to include subscription.email
        expect(mail.body.encoded).to include subscription.link.name
        expect(mail.body.encoded).to include "has completed all their installment payments for"
      end
    end
  end

  describe "unremovable_discord_member" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, seller:, link: product) }

    it "has the correct subject and content" do
      mail = ContactingCreatorMailer.unremovable_discord_member("000000000000000000", "Server Name", purchase.id)

      expect(mail.subject).to eq "We were unable to remove a Discord member from your server"
      expect(mail.body.encoded).to include "Unremovable Discord member"
      expect(mail.body.encoded).to include product.name
      expect(mail.body.encoded).to include "We were unable to remove the member because they have a Discord role which is higher than the Gumroad bot's role on the server."
    end
  end

  describe "unstampable_pdf_notification" do
    let(:product) { create(:product) }

    it "has the correct subject and content" do
      mail = ContactingCreatorMailer.unstampable_pdf_notification(product.id)

      expect(mail.subject).to eq "We were unable to stamp your PDF"
      expect(mail.body.encoded).to include "We were unable to stamp your PDF"
      expect(mail.body.encoded).to include product.name
      expect(mail.body.encoded).to include edit_link_url(product)
    end
  end

  describe "undelivered_receipts" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller, name: "Terraforming Guide") }

    def undelivered_purchase
      purchase = create(:purchase, seller:, link: product)
      create(:customer_email_info, purchase:, state: "sent", sent_at: 3.days.ago)
      purchase
    end

    def notified_key(purchase) = RedisKey.undelivered_receipt_notified(purchase.id)

    it "names the buyer and product for a single affected sale" do
      purchase = undelivered_purchase

      mail = ContactingCreatorMailer.undelivered_receipts(seller.id, [purchase.id])

      expect(mail.to).to eq [seller.email]
      expect(mail.subject).to eq "A buyer may not have received their receipt"
      expect(mail.body.encoded).to include purchase.email
      expect(mail.body.encoded).to include "Terraforming Guide"
      expect(mail.body.encoded).to include "A buyer paid you and we have no confirmation"
    end

    it "pluralizes the subject and body for several affected sales" do
      first = undelivered_purchase
      second = undelivered_purchase

      mail = ContactingCreatorMailer.undelivered_receipts(seller.id, [first.id, second.id])

      expect(mail.subject).to eq "2 buyers may not have received their receipt"
      expect(mail.body.encoded).to include "2 of your buyers"
    end

    # The sweep and this render are separated by a queue, and the whole email asks the seller to chase
    # someone who may have opened their content in between.
    it "drops a buyer who accessed their content after the sweep" do
      listed = undelivered_purchase
      recovered = undelivered_purchase
      create(:url_redirect, purchase: recovered, link: product, uses: 1)

      mail = ContactingCreatorMailer.undelivered_receipts(seller.id, [listed.id, recovered.id])

      expect(mail.body.encoded).to include listed.email
      expect(mail.body.encoded).not_to include recovered.email
    end

    # The count is what the seller acts on, so it has to shrink with the list rather than keep the
    # sweep's figure and claim more affected sales than the email stands behind.
    it "reduces the reported total when a listed buyer has recovered" do
      listed = undelivered_purchase
      recovered = undelivered_purchase
      create(:url_redirect, purchase: recovered, link: product, uses: 1)

      mail = ContactingCreatorMailer.undelivered_receipts(seller.id, [listed.id, recovered.id])

      expect(mail.subject).to eq "A buyer may not have received their receipt"
      expect(mail.body.encoded).not_to include "and 1 more"
    end

    it "counts the buyers it does not list" do
      purchases = Array.new(UndeliveredReceiptNotifier::MAX_LISTED_PER_SELLER + 3) { undelivered_purchase }

      mail = ContactingCreatorMailer.undelivered_receipts(seller.id, purchases.map(&:id))

      expect(mail.subject).to eq "13 buyers may not have received their receipt"
      expect(mail.body.encoded).to include "and 3 more"
    end

    # Truncating before the recheck let the first ten buyers decide the digest for everyone: if those
    # ten recovered, the mailer suppressed the message while the eleventh was still affected, and the
    # job marked all of them notified. The list is cut down here, after the recheck, for that reason.
    it "still reports an unlisted buyer when every listed buyer has recovered" do
      recovered = Array.new(UndeliveredReceiptNotifier::MAX_LISTED_PER_SELLER) do
        purchase = undelivered_purchase
        create(:url_redirect, purchase:, link: product, uses: 1)
        purchase
      end
      still_affected = undelivered_purchase

      mail = ContactingCreatorMailer.undelivered_receipts(seller.id, recovered.map(&:id) + [still_affected.id])

      expect(mail.subject).to eq "A buyer may not have received their receipt"
      expect(mail.body.encoded).to include still_affected.email
      expect($redis.exists?(notified_key(recovered.first))).to be false
    end

    it "sends nothing when every listed buyer has recovered" do
      recovered = undelivered_purchase
      create(:url_redirect, purchase: recovered, link: product, uses: 1)

      mail = ContactingCreatorMailer.undelivered_receipts(seller.id, [recovered.id])

      expect(mail.message).to be_a ActionMailer::Base::NullMail
    end

    it "sends nothing when the seller is gone by render time" do
      purchase = undelivered_purchase

      seller.update!(deleted_at: Time.current)

      mail = ContactingCreatorMailer.undelivered_receipts(seller.id, [purchase.id])

      expect(mail.message).to be_a ActionMailer::Base::NullMail
    end

    # A claim is not evidence the seller was told, so it expires: a render killed between claiming and
    # delivering costs a delayed notice rather than a permanent silence.
    it "holds the claim provisionally on a render that has not delivered" do
      purchase = undelivered_purchase

      ContactingCreatorMailer.undelivered_receipts(seller.id, [purchase.id]).message

      expect($redis.ttl(notified_key(purchase))).to be_between(1, UndeliveredReceiptNotifier::SEND_CLAIM_TTL.to_i)
    end

    it "records the buyers it named, with no expiry" do
      purchase = undelivered_purchase

      ContactingCreatorMailer.undelivered_receipts(seller.id, [purchase.id]).deliver_now

      expect($redis.exists?(notified_key(purchase))).to be true
      expect($redis.ttl(notified_key(purchase))).to eq(-1)
    end

    # A permanent record written for a notice that never left costs the seller the notice itself:
    # every later sweep skips that buyer.
    it "gives the claim back when the message is suppressed at render" do
      recovered = undelivered_purchase
      create(:url_redirect, purchase: recovered, link: product, uses: 1)

      ContactingCreatorMailer.undelivered_receipts(seller.id, [recovered.id]).deliver_now

      expect($redis.exists?(notified_key(recovered))).to be false
    end

    it "gives the claim back when delivery is not performed" do
      purchase = undelivered_purchase

      mail = ContactingCreatorMailer.undelivered_receipts(seller.id, [purchase.id])
      mail.message.perform_deliveries = false
      mail.deliver_now

      expect($redis.exists?(notified_key(purchase))).to be false
    end

    it "gives the claim back when delivery raises" do
      purchase = undelivered_purchase

      allow_any_instance_of(Mail::Message).to receive(:deliver).and_raise(StandardError, "transport down")
      expect do
        ContactingCreatorMailer.undelivered_receipts(seller.id, [purchase.id]).deliver_now
      end.to raise_error(StandardError, "transport down")

      expect($redis.exists?(notified_key(purchase))).to be false

      allow_any_instance_of(Mail::Message).to receive(:deliver).and_call_original
      retried = ContactingCreatorMailer.undelivered_receipts(seller.id, [purchase.id])

      expect(retried.message).not_to be_a ActionMailer::Base::NullMail
    end

    # The settling callback runs for every action on this mailer — deliver callbacks cannot be scoped
    # with `only:` — so the ivar is what keeps it from touching another action's bookkeeping.
    it "touches no send-once state when an unrelated email is delivered" do
      expect(UndeliveredReceiptNotifier).not_to receive(:record_sent)
      expect(UndeliveredReceiptNotifier).not_to receive(:release_claim)

      ContactingCreatorMailer.unstampable_pdf_notification(product.id).deliver_now
    end

    # The claim is what separates two renders of the same buyer: the sweep's read cannot, and the
    # job's own Sidekiq retry re-collects these rows before any mail has been delivered.
    it "does not name the same buyer in a second concurrent render" do
      purchase = undelivered_purchase

      ContactingCreatorMailer.undelivered_receipts(seller.id, [purchase.id]).message
      second = ContactingCreatorMailer.undelivered_receipts(seller.id, [purchase.id])

      expect(second.message).to be_a ActionMailer::Base::NullMail
    end
  end

  describe "undeliverable_ping_subscription" do
    let(:seller) { create(:user) }
    let(:oauth_application) { create(:oauth_application, owner: seller, name: "Gumroad Store Agent") }
    let(:resource_subscription) { create(:resource_subscription, oauth_application:, user: seller) }

    def notified_key(reason) = RedisKey.undeliverable_ping_subscription_notified(resource_subscription.id, reason)

    it "names the affected webhook and tells a seller with a revoked credential to reconnect" do
      mail = ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id)

      expect(mail.to).to eq [seller.email]
      expect(mail.subject).to eq "Your sale webhook is not being sent"
      expect(mail.body.encoded).to include "Gumroad Store Agent"
      expect(mail.body.encoded).to include "no longer has permission to read your sales"
      expect(mail.body.encoded).to include "Reconnecting Gumroad inside that application"
      expect(mail.body.encoded).not_to include "does not have a URL to send to"
    end

    # Resource subscriptions have no seller-facing UI, so advanced settings is offered as the
    # alternative destination rather than the place to fix this webhook.
    it "does not tell the seller to change this webhook in their own settings" do
      mail = ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id)

      expect(mail.body.encoded).to include "nothing to change"
      expect(mail.body.encoded).to include "Reply to this email"
      expect(mail.body.encoded).not_to include "review your webhooks and set a notification URL"
    end

    it "tells a seller with no post URL to set one through the application that created it" do
      resource_subscription.update_column(:post_url, nil)

      mail = ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id)

      expect(mail.body.encoded).to include "does not have a URL to send to"
      expect(mail.body.encoded).to include "through the application that created it"
      expect(mail.body.encoded).not_to include "no longer has permission to read your sales"
    end

    # Enqueued on a sale, rendered later: the seller may have removed it in between, and the email
    # asserts the subscription "is still listed as active".
    it "sends nothing when the subscription is gone by render time" do
      resource_subscription.mark_deleted!

      mail = ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id)

      expect(mail.message).to be_a ActionMailer::Base::NullMail
    end

    # Same window, other direction: the whole email asks the seller to do something they have now
    # already done, so it has to stop asking.
    it "sends nothing once the application has a live token again by render time" do
      create("doorkeeper/access_token", application: oauth_application, resource_owner_id: seller.id, scopes: "view_sales")

      mail = ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id)

      expect(mail.message).to be_a ActionMailer::Base::NullMail
    end

    it "sends nothing once a post URL is set on an authorized application by render time" do
      create("doorkeeper/access_token", application: oauth_application, resource_owner_id: seller.id, scopes: "account")

      mail = ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id)

      expect(mail.message).to be_a ActionMailer::Base::NullMail
    end

    # A disconnect in the window soft-deletes the application; deliverability alone still renders
    # "re-authorize" advice for an app the seller removed.
    it "sends nothing when the application was deleted by render time" do
      oauth_application.mark_deleted!
      # mark_deleted! soft-deletes the subscriptions too; this isolates the application's own state,
      # which is the half the render was not re-asking.
      ResourceSubscription.where(id: resource_subscription.id).update_all(deleted_at: nil)

      mail = ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id)

      expect(mail.message).to be_a ActionMailer::Base::NullMail
      expect($redis.exists?(notified_key(UndeliverablePingSubscriptionNotifier::REVOKED_CREDENTIAL))).to be false
    end

    # Same shape for the agent exclusion: those subscriptions are token-less by design and their owners
    # have no authorization flow to re-run, so a render must not email them either.
    it "sends nothing for a Store Agent application at render time" do
      oauth_application.update!(is_first_party_agent_app: true)

      mail = ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id)

      expect(mail.message).to be_a ActionMailer::Base::NullMail
      expect($redis.exists?(notified_key(UndeliverablePingSubscriptionNotifier::REVOKED_CREDENTIAL))).to be false
    end

    # Rendering is not sending, which is why nothing is recorded here: the record has no expiry, and
    # one written for an email nobody received would refuse the notice the seller is owed when the
    # same reason breaks again.
    it "claims nothing when it suppresses the send" do
      create("doorkeeper/access_token", application: oauth_application, resource_owner_id: seller.id, scopes: "view_sales")

      ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id).message

      expect($redis.exists?(notified_key(UndeliverablePingSubscriptionNotifier::REVOKED_CREDENTIAL))).to be false
    end

    # The render takes the notice rather than reading whether it is taken, because two renders can
    # overlap: the enqueue throttle is keyed on the reason at enqueue, so both jobs resolving to the
    # same reason here would pass a read and both send.
    it "sends only one of two renders that overlap before either delivers" do
      first = ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id)
      second = ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id)

      expect(first.message).not_to be_a ActionMailer::Base::NullMail
      expect(second.message).to be_a ActionMailer::Base::NullMail
    end

    # A claim is not evidence the seller was told, so it expires: a render killed between claiming and
    # delivering costs a delayed notice rather than a permanent silence.
    it "holds the claim provisionally on a render that has not delivered" do
      ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id).message

      ttl = $redis.ttl(notified_key(UndeliverablePingSubscriptionNotifier::REVOKED_CREDENTIAL))
      expect(ttl).to be_between(1, UndeliverablePingSubscriptionNotifier::SEND_CLAIM_TTL.to_i)
    end

    it "records the reason it sent, with no expiry" do
      ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id).deliver_now

      key = notified_key(UndeliverablePingSubscriptionNotifier::REVOKED_CREDENTIAL)
      expect($redis.exists?(key)).to be true
      expect($redis.ttl(key)).to eq(-1)
    end

    # The seller cannot act on a repeat: there is no way to re-authorize an app holding no live token,
    # and no UI or API to delete the subscription without one.
    it "sends once for the same reason however many times it is delivered" do
      ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id).deliver_now

      second = ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id)

      expect(second.message).to be_a ActionMailer::Base::NullMail
    end

    # The settling callback runs for every action on this mailer — deliver callbacks cannot be scoped
    # with `only:` — so the ivars are what keep it from touching another action's bookkeeping.
    it "touches no send-once state when an unrelated email is delivered" do
      product = create(:product, user: seller)
      expect(UndeliverablePingSubscriptionNotifier).not_to receive(:record_sent)
      expect(UndeliverablePingSubscriptionNotifier).not_to receive(:release_claim)

      ContactingCreatorMailer.unstampable_pdf_notification(product.id).deliver_now
    end

    # A delivery that raises gives the notice back, or the seller's one notice goes on an email that
    # never left — the same permanent silence a claim that is never released causes.
    it "still reports the reason after a delivery failure" do
      allow_any_instance_of(Mail::Message).to receive(:deliver).and_raise(StandardError, "transport down")
      expect do
        ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id).deliver_now
      end.to raise_error(StandardError, "transport down")

      expect($redis.exists?(notified_key(UndeliverablePingSubscriptionNotifier::REVOKED_CREDENTIAL))).to be false

      allow_any_instance_of(Mail::Message).to receive(:deliver).and_call_original
      retried = ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id)

      expect(retried.message).not_to be_a ActionMailer::Base::NullMail
    end

    # `RescueSmtpErrors` swallows these, so the delivery looks successful to the caller. The claim
    # still has to come back: `handle_exceptions` wraps the deliver callbacks from outside, so the
    # raise reaches this settle before the handler sees it.
    [Net::SMTPFatalError, Net::SMTPSyntaxError, Net::SMTPAuthenticationError].each do |error_class|
      it "gives the notice back when SMTP rejects the message with #{error_class}" do
        allow_any_instance_of(Mail::Message).to receive(:deliver).and_raise(error_class, "550 rejected")

        expect do
          ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id).deliver_now
        end.not_to raise_error

        expect($redis.exists?(notified_key(UndeliverablePingSubscriptionNotifier::REVOKED_CREDENTIAL))).to be false

        allow_any_instance_of(Mail::Message).to receive(:deliver).and_call_original
        retried = ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id)

        expect(retried.message).not_to be_a ActionMailer::Base::NullMail
      end
    end

    # `deliver_email` returns before `mail` for an address it will not send to, so the delivery
    # succeeds with nothing sent — keeping the claim there would burn the notice permanently.
    it "gives the notice back when the seller's address is not one we will send to" do
      allow_any_instance_of(User).to receive(:form_email).and_return("not-an-email")

      ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id).deliver_now

      expect($redis.exists?(notified_key(UndeliverablePingSubscriptionNotifier::REVOKED_CREDENTIAL))).to be false
    end

    # `perform_deliveries = false` drops the message with no raise and a recipient still set, so
    # treating it as sent would burn the notice on a mail that never left the process.
    it "gives the notice back when deliveries are switched off" do
      mail = ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id)
      mail.perform_deliveries = false

      mail.deliver_now

      expect($redis.exists?(notified_key(UndeliverablePingSubscriptionNotifier::REVOKED_CREDENTIAL))).to be false
    end

    # The advice comes from current state, so the reason recorded has to be the reason the seller was
    # told about — the other reason is still a notice they are owed.
    it "records only the reason it gave, leaving the other one reportable" do
      resource_subscription.update_column(:post_url, nil)

      mail = ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id)
      mail.deliver_now

      expect(mail.body.encoded).to include "does not have a URL to send to"
      expect($redis.exists?(notified_key(UndeliverablePingSubscriptionNotifier::MISSING_POST_URL))).to be true
      expect($redis.exists?(notified_key(UndeliverablePingSubscriptionNotifier::REVOKED_CREDENTIAL))).to be false
    end

    it "still sends the second reason after the first was already sent" do
      ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id).deliver_now
      resource_subscription.update_column(:post_url, nil)

      mail = ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id)

      expect(mail.body.encoded).to include "does not have a URL to send to"
    end

    # Silence is what this notice exists to break, so a failure in the send-once bookkeeping has to
    # cost a possible repeat rather than the email itself.
    it "sends when the send-once state cannot be claimed" do
      allow($redis).to receive(:set).and_raise(Redis::BaseError)
      expect(ErrorNotifier).to receive(:notify).at_least(:once)

      mail = ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id)

      expect(mail.message).not_to be_a ActionMailer::Base::NullMail
    end

    # `:eval`, not `:set`: the claim is the `set` and recording is the Lua settle, so stubbing `set`
    # here would fail the claim instead and only re-test the example above.
    it "sends the email even when recording that it sent fails" do
      allow($redis).to receive(:eval).and_raise(Redis::BaseError)
      expect(ErrorNotifier).to receive(:notify).at_least(:once)

      expect do
        ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id).deliver_now
      end.to change { ActionMailer::Base.deliveries.size }.by(1)
    end

    # A small numeric primary key matches inside the footer address, so the identifier worth
    # asserting on is the one that would actually leak: the subscription's own external id.
    it "does not leak the post URL or an identifier of the seller's subscription" do
      mail = ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id)

      expect(mail.body.encoded).not_to include resource_subscription.post_url
      expect(mail.body.encoded).not_to include resource_subscription.external_id
    end
  end

  describe "chargeback_lost_no_refund_policy" do
    let(:seller) { create(:user) }

    context "for a dispute on Purchase" do
      let(:product) { create(:product, user: seller) }
      let!(:purchase) { create(:purchase, seller:, link: product) }
      let(:dispute) { create(:dispute_formalized, purchase:) }

      it "has the correct text" do
        mail = ContactingCreatorMailer.chargeback_lost_no_refund_policy(dispute.id)
        expect(mail.subject).to eq "A dispute has been lost"
        expect(mail.body.encoded).to include "Unfortunately, we weren't able to win the dispute initiated by" \
          " one of your customers (#{purchase.email}) for their purchase of " \
          "<a target=\"_blank\" href=\"#{product.long_url}\">#{product.name}</a> for #{purchase.formatted_disputed_amount}."
        expect(mail.body.encoded).to include product.link.name
        expect(mail.body.encoded).to include purchase.formatted_display_price
        expect(mail.body.encoded).to include product.long_url
        expect(mail.body.encoded).to include edit_link_url(product)
      end

      it "renders from one delivery-time refund-policy snapshot" do
        allow(Dispute).to receive(:find).with(dispute.id).and_return(dispute)
        expect(purchase).to receive(:first_product_without_refund_policy).once.and_return(product)

        mail = ContactingCreatorMailer.chargeback_lost_no_refund_policy(dispute.id)

        expect(mail.body.encoded).to include product.name
        expect(mail.body.encoded).to include edit_link_url(product)
      end
    end

    context "for a dispute on Charge" do
      let(:charge) do
        charge = create(:charge, seller:)
        charge.purchases << create(:purchase, seller:, link: create(:product, user: seller))
        charge.purchases << create(:purchase, seller:, link: create(:product, user: seller))
        charge.purchases << create(:purchase, seller:, link: create(:product, user: seller))
        charge
      end

      let(:dispute) { create(:dispute_formalized_on_charge, purchase: nil, charge:) }

      it "has the correct text" do
        mail = ContactingCreatorMailer.chargeback_lost_no_refund_policy(dispute.id)

        expect(mail.subject).to eq "A dispute has been lost"
        expect(mail.body.encoded).to include "Unfortunately, we weren't able to win the dispute initiated by" \
          " one of your customers (#{charge.customer_email}) for their purchase of the following items for #{charge.formatted_disputed_amount}."
        charge.disputed_purchases.each do |purchase|
          expect(mail.body.encoded).to include purchase.link.name
          expect(mail.body.encoded).to include purchase.formatted_display_price
          expect(mail.body.encoded).to include purchase.link.long_url
        end

        product_without_refund_policy = charge.first_product_without_refund_policy
        expect(mail.body.encoded).to include "We noticed that #{product_without_refund_policy.name} currently doesn't have a refund policy."
        expect(mail.body.encoded).to include edit_link_url(product_without_refund_policy)
      end
    end

    context "when every disputed product has since gained a refund policy" do
      let(:product) { create(:product, user: seller) }
      let!(:purchase) { create(:purchase, seller:, link: product) }
      let(:dispute) { create(:dispute_formalized, purchase:) }

      it "does not send" do
        create(:product_refund_policy, seller:, product:)
        product.update!(product_refund_policy_enabled: true)

        mail = ContactingCreatorMailer.chargeback_lost_no_refund_policy(dispute.id)

        expect(mail.message).to be_a(ActionMailer::Base::NullMail)
      end
    end
  end

  describe "chargeback_won" do
    let!(:seller) { create(:user) }

    context "for a dispute on Purchase" do
      let!(:purchase) { create(:purchase, seller:, link: create(:product, user: seller)) }
      let!(:dispute) { create(:dispute, purchase:) }

      it "has the correct text" do
        mail = ContactingCreatorMailer.chargeback_won(dispute.id)

        expect(mail.subject).to eq "A dispute has been won"
        expect(mail.body.encoded).to include "We have won a dispute against #{purchase.email}'s purchase of " \
          "#{purchase.link.name} for #{purchase.formatted_disputed_amount} on your behalf. Your account has been credited the full amount."
        expect(mail.body.encoded).to include purchase.link.name
        expect(mail.body.encoded).to include purchase.formatted_display_price
      end
    end

    context "for a dispute on Charge" do
      let!(:charge) do
        charge = create(:charge, seller:)
        charge.purchases << create(:purchase, seller:, link: create(:product, user: seller))
        charge.purchases << create(:purchase, seller:, link: create(:product, user: seller))
        charge.purchases << create(:purchase, seller:, link: create(:product, user: seller))
        charge
      end

      let!(:dispute) { create(:dispute_on_charge, purchase: nil, charge:) }

      it "has the correct text" do
        mail = ContactingCreatorMailer.chargeback_won(dispute.id)

        expect(mail.subject).to eq "A dispute has been won"
        expect(mail.body.encoded).to include "We have won a dispute against #{charge.customer_email}'s purchase of " \
          "the following items for #{charge.formatted_disputed_amount} on your behalf. Your account has been credited the full amount."
        charge.disputed_purchases.each do |p|
          expect(mail.body.encoded).to include p.link.name
          expect(mail.body.encoded).to include p.formatted_display_price
        end
      end
    end
  end

  describe "preorder_summary" do
    before do
      @product = create(:product, price_cents: 600, is_in_preorder_state: false)
      @preorder_product = create(:preorder_product_with_content, link: @product)
      @preorder_product.update(release_at: Time.current) # bypassed the creation validation
      @good_card = build(:chargeable)
      @good_card_but_cant_charge = build(:chargeable_success_charge_decline)
    end

    describe "physical preorders" do
      before do
        @product.update(is_physical: true, require_shipping: true, name: "Physical Preorder")
        @product.shipping_destinations << ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2, one_item_rate_cents: 4_00, multiple_items_rate_cents: 2_00)
        @preorder_product.update(url: nil)
      end

      it "sends the correct summary email", :vcr do
        authorization_purchase = build(:purchase,
                                       link: @product,
                                       chargeable: @good_card,
                                       purchase_state: "in_progress",
                                       is_preorder_authorization: true,
                                       full_name: "Edgar Gumstein",
                                       street_address: "123 Gum Road",
                                       country: "United States",
                                       state: "CA",
                                       city: "San Francisco",
                                       zip_code: "94107")
        preorder = @preorder_product.build_preorder(authorization_purchase)
        preorder.authorize!
        preorder.mark_authorization_successful
        preorder.charge!
        preorder.mark_charge_successful

        mail = ContactingCreatorMailer.preorder_summary(@preorder_product.id)
        expect(mail.subject).to eq "Your pre-order was successfully released!"
        expect(mail.body.encoded).to include "from 1 pre-order"
        expect(mail.body.encoded).to include "The buyer has been charged, and they&#39;re ready to have Physical Preorder shipped to them."
        expect(mail.body.encoded).to_not include "Unfortunately"
      end

      it "includes the copy for the failed charges in the email", :vcr do
        # Successfully charged preorder:
        authorization_purchase = build(:purchase,
                                       link: @product,
                                       chargeable: @good_card,
                                       purchase_state: "in_progress",
                                       is_preorder_authorization: true,
                                       full_name: "Edgar Gumstein",
                                       street_address: "123 Gum Road",
                                       country: "United States",
                                       state: "CA",
                                       city: "San Francisco",
                                       zip_code: "94107")
        preorder = @preorder_product.build_preorder(authorization_purchase)
        preorder.authorize!
        preorder.mark_authorization_successful
        preorder.charge!
        preorder.mark_charge_successful

        # Preorder with failed charge
        authorization_purchase = build(:purchase,
                                       link: @product,
                                       chargeable: @good_card_but_cant_charge,
                                       purchase_state: "in_progress",
                                       is_preorder_authorization: true,
                                       full_name: "Edgar Gumstein",
                                       street_address: "123 Gum Road",
                                       country: "United States",
                                       state: "CA",
                                       city: "San Francisco",
                                       zip_code: "94107")
        preorder = @preorder_product.build_preorder(authorization_purchase)
        preorder.authorize!
        preorder.mark_authorization_successful
        preorder.charge!

        mail = ContactingCreatorMailer.preorder_summary(@preorder_product.id)
        expect(mail.subject).to eq "Your pre-order was successfully released!"
        expect(mail.body.encoded).to include "from 1 pre-order"
        expect(mail.body.encoded).to include "The buyer has been charged, and they&#39;re ready to have Physical Preorder shipped to them."
        expect(mail.body.encoded).to include "Once corrected, the sale will appear in your account and Physical Preorder can be shipped to them."
        str = "Unfortunately, a customer&#39;s credit card was declined. We have sent an email asking them to update their information. " \
              "Once corrected, the sale will appear in your account and Physical Preorder can be shipped to them."
        expect(mail.body.encoded).to include str
      end

      it "does not send email if the preorder had no sales", :vcr do
        mail = ContactingCreatorMailer.preorder_summary(@preorder_product.id)
        expect(mail.subject).to eq nil
      end
    end

    describe "digital preorders" do
      it "sends the correct summary email", :vcr do
        authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
        preorder = @preorder_product.build_preorder(authorization_purchase)
        preorder.authorize!
        preorder.mark_authorization_successful
        preorder.charge!
        preorder.mark_charge_successful

        mail = ContactingCreatorMailer.preorder_summary(@preorder_product.id)
        expect(mail.subject).to eq "Your pre-order was successfully released!"
        expect(mail.body.encoded).to include "from 1 pre-order"
        expect(mail.body.encoded).to_not include "Unfortunately"
      end

      it "includes the copy for the failed charges in the email", :vcr do
        # Successfully charged preorder:
        authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
        preorder = @preorder_product.build_preorder(authorization_purchase)
        preorder.authorize!
        preorder.mark_authorization_successful
        preorder.charge!
        preorder.mark_charge_successful

        # Preorder with failed charge
        authorization_purchase = build(:purchase, link: @product, chargeable: @good_card_but_cant_charge,
                                                  purchase_state: "in_progress", is_preorder_authorization: true)
        preorder = @preorder_product.build_preorder(authorization_purchase)
        preorder.authorize!
        preorder.mark_authorization_successful
        preorder.charge!

        mail = ContactingCreatorMailer.preorder_summary(@preorder_product.id)
        expect(mail.subject).to eq "Your pre-order was successfully released!"
        expect(mail.body.encoded).to include "from 1 pre-order"
        expect(mail.body.encoded).to include ERB::Util.html_escape("Unfortunately, a customer's credit card")
        expect(mail.body.encoded).to include authorization_purchase.email
      end

      it "does not send email if the preorder had no sales", :vcr do
        mail = ContactingCreatorMailer.preorder_summary(@preorder_product.id)
        expect(mail.subject).to eq nil
      end
    end
  end

  describe "user_sales_data" do
    it "contains the correct text, attachment, and attributes" do
      user = create(:user)
      file = Tempfile.new(["TestSales", ".csv"])
      mail = ContactingCreatorMailer.user_sales_data(user.id, file)
      expect(mail.body.encoded).to include "Your requested data"
      expect(mail.body.encoded).to include "We've attached the customer data you requested to this email."
      expect(mail.attachments.size).to eq(1)
      expect(mail.to).to eq([user.email])
      expect(mail.subject).to eq("Here's your customer data!")
    end
  end

  describe "tax_form_transaction_report" do
    it "contains the correct text, attachment, and attributes" do
      user = create(:user)
      file = Tempfile.new(["1099-K-transactions", ".csv"])
      mail = ContactingCreatorMailer.tax_form_transaction_report(user.id, 2025, file)
      expect(mail.body.encoded).to include "Your 1099-K transaction report"
      expect(mail.body.encoded).to include "We've attached the transaction report"
      expect(mail.attachments.size).to eq(1)
      expect(mail.attachments.first.filename).to eq("1099-K-transactions-2025.csv")
      expect(mail.to).to eq([user.email])
      expect(mail.subject).to eq("Your 2025 1099-K transaction report")
    end
  end

  describe "payout_data" do
    let(:recipient) { create(:user) }
    let(:attachment_name) { "payout_data_#{SecureRandom.hex}.csv" }
    let(:extension) { "csv" }
    let(:tempfile) { Tempfile.new }

    context "when file can be attached directly" do
      before do
        allow_any_instance_of(MailerAttachmentOrLinkService).to receive(:perform).and_return(
          { file: tempfile, url: nil }
        )
      end

      it "contains the correct attachment and attributes" do
        mail = ContactingCreatorMailer.payout_data(attachment_name, extension, tempfile, recipient.id)

        expect(mail.to).to eq([recipient.email])
        expect(mail.subject).to eq("Here's your payout data!")
        expect(mail.attachments.size).to eq(1)
        expect(mail.attachments[attachment_name]).to be_present
      end
    end

    context "when file is too large and a URL is provided instead" do
      let(:download_url) { "https://example.com/download/payout_data.csv" }

      before do
        allow_any_instance_of(MailerAttachmentOrLinkService).to receive(:perform).and_return(
          { file: nil, url: download_url }
        )
      end

      it "contains the download URL in the email body" do
        mail = ContactingCreatorMailer.payout_data(attachment_name, extension, tempfile, recipient.id)

        expect(mail.to).to eq([recipient.email])
        expect(mail.subject).to eq("Here's your payout data!")
        expect(mail.attachments).to be_empty
        expect(mail.body.encoded).to include(download_url)
      end
    end
  end

  describe ".affiliates_data" do
    before do
      @recipient = create(:user)
      @filename = "affiliates-export-#{SecureRandom.hex}.csv"
      @tempfile = Tempfile.new
      @tempfile.puts "csv content"
    end

    let(:mail) do
      described_class.affiliates_data(
        recipient: @recipient,
        tempfile: @tempfile,
        filename: @filename,
      )
    end

    it "contains the correct attachment and attributes" do
      expect(mail.to).to eq([@recipient.email])
      expect(mail.subject).to include("Here is your affiliates data")
      expect(mail.attachments.size).to eq(1)
      expect(mail.attachments.first.body.raw_source).to eq("csv content\n")
    end

    context "when attachment size is above threshold" do
      before do
        stub_const("MailerAttachmentOrLinkService::MAX_FILE_SIZE", 1.byte)
      end

      it "contains a link instead of an attachment" do
        expect(mail.to).to eq([@recipient.email])
        expect(mail.subject).to include("Here is your affiliates data")
        expect(mail.attachments.size).to eq(0)
        expect(mail.body).to include(@filename)
        expect(Nokogiri::HTML(mail.body.encoded).text).to include("Please click this link")
      end
    end
  end

  describe ".subscribers_data" do
    let(:recipient) { create(:user) }
    let(:filename) { "subscribers-export-#{SecureRandom.hex}.csv" }
    let(:tempfile) { Tempfile.new }

    before do
      tempfile.puts "csv content"
    end

    it "contains the correct attachment and attributes" do
      mail = ContactingCreatorMailer.subscribers_data(
        recipient: recipient,
        tempfile: tempfile,
        filename: filename,
      )

      expect(mail.to).to eq([recipient.email])
      expect(mail.subject).to include("Here is your subscribers data")
      expect(mail.attachments.size).to eq(1)
      expect(mail.attachments.first.body.raw_source).to eq("csv content\n")
    end

    context "when attachment size is above threshold" do
      let(:download_url) { "https://example.com/download/subscribers_data.csv" }

      before do
        allow_any_instance_of(MailerAttachmentOrLinkService).to receive(:perform).and_return(
          { file: nil, url: download_url }
        )
      end

      it "contains a link instead of an attachment" do
        mail = ContactingCreatorMailer.subscribers_data(
          recipient: recipient,
          tempfile: tempfile,
          filename: filename,
        )

        expect(mail.to).to eq([recipient.email])
        expect(mail.subject).to include("Here is your subscribers data")
        expect(mail.attachments.size).to eq(0)
        expect(mail.body).to have_link("link", href: download_url)
      end
    end
  end

  describe "video_transcode_failed" do
    before do
      @user = create(:user, name: "Person")
      @product = create(:product, user: @user, name: "A Tale of Two Links")
      @product_file = create(:product_file, link: @product, display_name: "A Tale of Two Products")
      @product_file_two = create(:product_file, link: @product)
    end

    it "has the correct text when product file has display_name set" do
      mail = ContactingCreatorMailer.video_transcode_failed(@product_file.id)

      expect(mail.subject).to eq("A video failed to transcode.")
      expect(mail.to).to eq([@user.email])
      expect(mail.body.encoded).to include @product_file.s3_filename
      expect(mail.body.encoded).to include "Please try re-encoding it locally on your computer and uploading it again."
    end

    it "has the correct text when product file does not have display_name set" do
      mail = ContactingCreatorMailer.video_transcode_failed(@product_file_two.id)

      expect(mail.subject).to eq("A video failed to transcode.")
      expect(mail.to).to eq([@user.email])
      expect(mail.body.encoded).to include @product_file.link.name
      expect(mail.body.encoded).to include "Please try re-encoding it locally on your computer and uploading it again."
    end

    it "returns early without error when the associated link has been deleted" do
      product_file = create(:product_file, link: @product)
      product_file.update_column(:link_id, nil)

      mail = ContactingCreatorMailer.video_transcode_failed(product_file.id)

      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end
  end

  describe "tax_form_1099k" do
    describe "filed form" do
      it "has the correct subject and body with form download url included" do
        creator = create(:user)
        year = Date.current.year.pred
        create(:user_tax_form, user: creator, tax_year: year, tax_form_type: "us_1099_k", filed_at: 1.week.ago.to_i)

        mail = ContactingCreatorMailer.tax_form_1099k(creator.id, year)

        expect(mail.subject).to eq "Get your 1099-K form for #{year}"
        expect(mail.to).to eq [creator.email]
        expect(mail.body.encoded).to include "Your 1099-K form for #{year} is ready to download"
        expect(mail.body.encoded).to include "The 1099-K is a purely informational form that summarizes the payments that were made to your account during #{year} and is designed to help you report your taxes."
        expect(mail.body.encoded).to include "Our payment processor, Stripe, files a copy electronically with the IRS."
        expect(mail.body.encoded).to include "The sales deposited directly to your connected PayPal and Stripe accounts are not included in your 1099-K. You will receive separate 1099-K forms for those sales from PayPal and Stripe."
        expect(mail.body).to have_link("Download form", href: download_tax_form_url(form_type: "us_1099_k", year:))
        expect(mail.body.encoded).to include "You can also download it from your <a href=\"#{tax_center_url}\">Gumroad tax center</a> at any time."
      end
    end

    describe "informational not-filed form" do
      it "has the correct subject and body with form download url included" do
        creator = create(:user)
        year = Date.current.year.pred
        create(:user_tax_form, user: creator, tax_year: year, tax_form_type: "us_1099_k")

        mail = ContactingCreatorMailer.tax_form_1099k(creator.id, year)

        expect(mail.subject).to eq "Get your 1099-K form for #{year}"
        expect(mail.to).to eq [creator.email]
        expect(mail.body.encoded).to include "Your 1099-K form for #{year} is ready to download"
        expect(mail.body.encoded).to include "The 1099-K is a purely informational form that summarizes the payments that were made to your account during #{year} and is designed to help you report your taxes."
        expect(mail.body.encoded).to include "This form is for your records only and has not been filed with the IRS."
        expect(mail.body).to have_link("Download form", href: download_tax_form_url(form_type: "us_1099_k", year:))
        expect(mail.body.encoded).to include "You can also download it from your <a href=\"#{tax_center_url}\">Gumroad tax center</a> at any time."
      end
    end
  end

  describe "tax_form_1099misc" do
    it "has the correct subject and body with form download url included" do
      creator = create(:user)
      year = Date.current.year.pred

      mail = ContactingCreatorMailer.tax_form_1099misc(creator.id, year)

      expect(mail.subject).to eq "Get your 1099-MISC form for #{year}"
      expect(mail.to).to eq [creator.email]
      expect(mail.body.encoded).to include "Your 1099-MISC form for #{year} is ready to download"
      expect(mail.body.encoded).to include "The 1099-MISC is a purely informational form that summarizes the commissions you earned as an affiliate during #{year} and is designed to help you report your taxes."
      expect(mail.body.encoded).to include "Our payment processor, Stripe, files a copy electronically with the IRS."
      expect(mail.body).to have_link("Download form", href: download_tax_form_url(form_type: "us_1099_misc", year:))
      expect(mail.body.encoded).to include "You can also download it from your <a href=\"#{tax_center_url}\">Gumroad tax center</a> at any time."
    end
  end

  describe "#singapore_identity_verification_reminder" do
    it "has the correct subject and body with payments settings page url included" do
      creator = create(:user)

      mail = ContactingCreatorMailer.singapore_identity_verification_reminder(creator.id, Time.new(2023, 10, 10))

      expect(mail.to).to eq [creator.email]
      expect(mail.subject).to eq "[Action Required] Complete the identity verification to avoid account closure"
      expect(mail.body.encoded).to include "In accordance with Singapore’s Payment Services Act, our payment processor Stripe requires extra verification for Singapore-based accounts."
      expect(mail.body.encoded).to include "https://gumroad.com/settings/payments"
      expect(mail.body.encoded).to include "After the deadline on October 10, 2023, your current balance will be forfeited."
    end
  end

  describe "#stripe_document_verification_failed" do
    it "has the correct subject and body with payments settings page url included" do
      creator = create(:user)
      stripe_error_reason = "The document might have been altered so it could not be verified."

      mail = ContactingCreatorMailer.stripe_document_verification_failed(creator.id, stripe_error_reason)

      expect(mail.to).to eq [creator.email]
      expect(mail.subject).to eq "[Action Required] Stripe needs an updated document"
      expect(mail.body.encoded).to include "Stripe, our payment processor, was unable to verify a document"
      expect(mail.body.encoded).to include stripe_error_reason
      expect(mail.body.encoded).to include "gumroad.com/settings/payments"
      expect(mail.body.encoded).to include settings_payments_url
    end

    it "drops the upload instructions and points at support when the reason is one the seller can't act on" do
      creator = create(:user)

      mail = ContactingCreatorMailer.stripe_document_verification_failed(creator.id, UserComplianceInfoRequest::PO_BOX_ADDRESS_DEADLOCK_MESSAGE)

      expect(mail.body.encoded).to include "uploading it again won&#39;t help"
      expect(mail.body.encoded).to include "mailto:support@gumroad.com"
      expect(mail.body.encoded).to_not include "upload a valid document"
      expect(mail.body.encoded).to_not include "Go to payout settings"
      expect(mail.body.encoded).to_not include "Here&#39;s what Stripe reported"
    end

    it "also treats the previously queued P.O. Box wording as unactionable" do
      creator = create(:user)

      mail = ContactingCreatorMailer.stripe_document_verification_failed(creator.id, UserComplianceInfoRequest::PREVIOUS_PO_BOX_ADDRESS_DEADLOCK_MESSAGE)

      expect(mail.body.encoded).to include "Your registered address is a P.O. Box"
      expect(mail.body.encoded).to include "mailto:support@gumroad.com"
      expect(mail.body.encoded).to_not include "upload a valid document"
      expect(mail.body.encoded).to_not include "Go to payout settings"
    end
  end

  describe "#stripe_identity_verification_failed" do
    it "has the correct subject and body with payments settings page url included" do
      creator = create(:user)
      stripe_error_reason = "The identity information you entered cannot be verified. Please correct any errors or upload a document that matches the identity fields (e.g., name and date of birth) that you entered."

      mail = ContactingCreatorMailer.stripe_identity_verification_failed(creator.id, stripe_error_reason)

      expect(mail.to).to eq [creator.email]
      expect(mail.subject).to eq "[Action Required] Stripe needs updated identity information"
      expect(mail.body.encoded).to include "Stripe, our payment processor, was unable to verify some of the identity information"
      expect(mail.body.encoded).to include stripe_error_reason
      expect(mail.body.encoded).to include "gumroad.com/settings/payments"
      expect(mail.body.encoded).to include settings_payments_url
    end

    it "drops the update instructions and points at support when the reason is one the seller can't act on" do
      creator = create(:user)

      mail = ContactingCreatorMailer.stripe_identity_verification_failed(creator.id, UserComplianceInfoRequest::PO_BOX_ADDRESS_DEADLOCK_MESSAGE)

      expect(mail.body.encoded).to include "uploading it again won&#39;t help"
      expect(mail.body.encoded).to include "mailto:support@gumroad.com"
      expect(mail.body.encoded).to_not include "update the relevant information"
      expect(mail.body.encoded).to_not include "Go to payout settings"
      expect(mail.body.encoded).to_not include "Here&#39;s what Stripe reported"
    end

    it "also treats the previously queued P.O. Box wording as unactionable" do
      creator = create(:user)

      mail = ContactingCreatorMailer.stripe_identity_verification_failed(creator.id, UserComplianceInfoRequest::PREVIOUS_PO_BOX_ADDRESS_DEADLOCK_MESSAGE)

      expect(mail.body.encoded).to include "Your registered address is a P.O. Box"
      expect(mail.body.encoded).to include "mailto:support@gumroad.com"
      expect(mail.body.encoded).to_not include "update the relevant information"
      expect(mail.body.encoded).to_not include "Go to payout settings"
    end
  end

  describe "#review_submitted" do
    let(:review) { create(:product_review) }

    it "has the correct subject and body" do
      mail = ContactingCreatorMailer.review_submitted(review.id)
      expect(mail.to).to eq([review.link.user.email])
      expect(mail.subject).to eq("#{review.purchase.email} reviewed #{review.link.name}")
      expect(mail.body.encoded).to have_text("New review")
      expect(mail.body.encoded).to have_text("#{review.purchase.email} reviewed")
      expect(mail.body.encoded).to have_link(review.link.name, href: review.link.long_url)
      expect(mail.body.encoded).to have_text(review.message)
      expect(mail.body.encoded).to have_selector("[aria-label='1 star']")
      expect(mail.body.encoded).to have_selector("img[src='#{ActionController::Base.helpers.image_path("email/solid-star.png")}']", count: 1)
      expect(mail.body.encoded).to have_selector("img[src='#{ActionController::Base.helpers.image_path("email/outline-star.png")}']", count: 4)
      expect(mail.body.encoded).to have_link("View all reviews", href: review.link.long_url)
    end

    context "no message" do
      before { review.update!(message: nil) }
      it "omits the quotation marks" do
        mail = ContactingCreatorMailer.review_submitted(review.id)
        expect(mail.body.encoded).to_not have_text('""')
      end
    end

    context "the seller's notification claim" do
      it "does not send when another render already claimed the notification" do
        RedisKey.product_review_seller_notified(review.id).then { |key| $redis.set(key, Time.current.to_i) }

        mail = ContactingCreatorMailer.review_submitted(review.id)
        expect(mail.message).to be_a(ActionMailer::Base::NullMail)
      end

      it "still sends the first time nothing has claimed it" do
        mail = ContactingCreatorMailer.review_submitted(review.id)
        expect(mail.to).to eq([review.link.user.email])
      end

      it "does not send once a delivered render has recorded the seller as notified" do
        review.update_columns(seller_notified_at: Time.current)

        mail = ContactingCreatorMailer.review_submitted(review.id)
        expect(mail.message).to be_a(ActionMailer::Base::NullMail)
      end

      it "does not send again once the claim has expired, because the record of the send outlives it" do
        ContactingCreatorMailer.review_submitted(review.id).deliver_now
        $redis.del(RedisKey.product_review_seller_notified(review.id))

        mail = ContactingCreatorMailer.review_submitted(review.id)
        expect(mail.message).to be_a(ActionMailer::Base::NullMail)
      end

      it "records the seller as notified once the message is delivered" do
        expect do
          ContactingCreatorMailer.review_submitted(review.id).deliver_now
        end.to change { review.reload.seller_notified_at }.from(nil)
      end

      it "gives the claim back when delivery raises, so the retry still sends" do
        allow_any_instance_of(Mail::Message).to receive(:do_delivery).and_raise(Net::SMTPServerBusy, "451 try again later")

        expect do
          ContactingCreatorMailer.review_submitted(review.id).deliver_now
        end.to raise_error(Net::SMTPServerBusy)

        expect(review.reload.seller_notified_at).to be_nil
        expect($redis.get(RedisKey.product_review_seller_notified(review.id))).to be_nil
      end

      it "leaves nothing claimed when the render decides not to send" do
        review.link.user.update!(disable_reviews_email: true)

        ContactingCreatorMailer.review_submitted(review.id).deliver_now

        expect($redis.get(RedisKey.product_review_seller_notified(review.id))).to be_nil
        expect(review.reload.seller_notified_at).to be_nil
      end
    end

    it "does not send for a deleted review" do
      review.mark_deleted!
      mail = ContactingCreatorMailer.review_submitted(review.id)
      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    it "does not send if the seller turned off review emails after the job was enqueued" do
      review.link.user.update!(disable_reviews_email: true)
      mail = ContactingCreatorMailer.review_submitted(review.id)
      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    context "when the review has a pending video" do
      let!(:pending_video) do
        create(
          :product_review_video,
          :pending_review,
          product_review: review,
          video_file: create(:video_file, :with_thumbnail)
        )
      end

      it "includes the video thumbnail" do
        mail = ContactingCreatorMailer.review_submitted(review.id)
        expect(mail.body.encoded).to have_selector("img[src='#{pending_video.video_file.thumbnail_url}']")
        expect(mail.body.encoded).to have_link("Review & approve video", href: customers_url(query: review.purchase.email))
      end
    end
  end

  describe "#upcoming_call_reminder" do
    describe "email content", :freeze_time do
      before { travel_to(Time.utc(2024, 5, 1)) }

      let!(:product) { create(:call_product, :available_for_a_year, name: "Portfolio review") }
      let!(:variant_category) { product.variant_categories.first }
      let!(:variant) { create(:variant, name: "60 minutes", duration_in_minutes: 60, variant_category:) }
      let!(:call) do
        create(
          :call,
          start_time: DateTime.parse("2024-05-02 10:00:00 PDT"),
          end_time: DateTime.parse("2024-05-02 11:00:00 PDT"),
          purchase: build(:call_purchase, link: product, variant_attributes: [variant])
        )
      end
      let!(:checkout_custom_fields) do
        [
          create(
            :purchase_custom_field,
            purchase: call.purchase,
            name: "Checkout custom field name",
            value: "Checkout custom field value"
          )
        ]
      end
      let!(:post_purchase_custom_field) do
        create(
          :purchase_custom_field,
          purchase: call.purchase,
          is_post_purchase: true,
          name: "Post purchase custom field name",
          value: "Post purchase custom field value"
        )
      end
      let!(:file_custom_field) do
        create(
          :purchase_custom_field,
          purchase: call.purchase,
          field_type: CustomField::TYPE_FILE,
          name: "File upload",
          value: "Post purchase custom field value"
        )
      end


      it "includes the correct information" do
        mail = ContactingCreatorMailer.upcoming_call_reminder(call.id)

        expect(mail.to).to eq([product.user.email])
        expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
        expect(mail.subject).to include("Your scheduled call with #{call.purchase.email} is tomorrow!")

        expect(mail.body).to include("Your scheduled call with #{call.purchase.email} is tomorrow!")

        expect(mail.body).to include("Your scheduled call with #{call.purchase.email} is tomorrow!")

        expect(mail.body.sanitized).to include("Checkout custom field name Checkout custom field value")
        expect(mail.body.sanitized).to include("Post purchase custom field name Post purchase custom field value")
        expect(mail.body).to_not include("File upload")

        expect(mail.body.sanitized).to include("Call schedule 10:00 AM - 11:00 AM PDT Thursday, May 2nd, 2024")
        expect(mail.body.sanitized).to include("Duration 60 minutes")
        expect(mail.body.sanitized).to include("Product Portfolio review")
      end
    end

    context "when the call is not eligible for reminder" do
      let(:call) { create(:call) }

      it "does not send the email" do
        allow_any_instance_of(Call).to receive(:eligible_for_reminder?).and_return(false)

        mail = ContactingCreatorMailer.upcoming_call_reminder(call.id)

        expect(mail.subject).to be_nil
      end
    end
  end

  describe "#stripe_remediation", :vcr do
    let!(:seller) { create(:named_seller) }
    let!(:user_compliance_info) { create(:user_compliance_info, user: seller) }
    let!(:bank_account) { create(:ach_account_stripe_succeed, user: seller) }
    let!(:tos_agreement) { create(:tos_agreement, user: seller) }
    let!(:stripe_connect_account_id) { StripeMerchantAccountManager.create_account(seller, passphrase: "1234").charge_processor_merchant_id }

    it "has the correct subject and body" do
      travel_to(Date.parse("2024-09-23")) do
        mail = ContactingCreatorMailer.stripe_remediation(seller.id)

        expect(mail.to).to eq([seller.email])
        expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
        expect(mail.subject).to eq("We need more information from you.")

        expect(mail.body.encoded).to include("To continue paying you out, we need some more information from you.")
        expect(mail.body.encoded).to include("This information is required by our banking partners for identity verification, to align with bank regulations, and to protect against fraud.")
        expect(mail.body.encoded).to include("Please provide the requested information before your next payout.")
        expect(mail.body.encoded).to have_link("Provide your information", href: remediation_settings_payments_url)
      end
    end
  end

  describe "#more_kyc_needed" do
    let!(:seller) { create(:named_seller) }

    it "links the call-to-action to the remediation endpoint so sellers reach Stripe's hosted upload flow" do
      mail = ContactingCreatorMailer.more_kyc_needed(seller.id, %w[individual_tax_id])

      expect(mail.to).to eq([seller.email])
      expect(mail.body.encoded).to have_link("Provide your information", href: remediation_settings_payments_url)
      expect(mail.body.encoded).not_to have_link("Provide your information", href: settings_payments_url)
    end
  end

  describe "#invalid_bank_account" do
    let(:seller) { create(:user) }
    let(:format_rejection_message) do
      "Invalid routing number for PK. The number must contain both the bank code and the branch code, and should be in the format AAAAPKBB or AAAAPKBBXYZ."
    end
    let(:directory_miss_message) { "We couldn't find the bank for that bank/branch code" }

    context "when the bank code was rejected on format" do
      let(:mail) do
        ContactingCreatorMailer.invalid_bank_account(
          seller.id,
          StripeMerchantAccountManager::BANK_REJECTION_KIND_FORMAT,
          format_rejection_message
        )
      end

      it "tells the seller to correct the code and shows the expected format" do
        expect(mail.to).to eq([seller.email])
        expect(mail.subject).to eq("Your bank details need correcting for payouts.")
        expect(mail.body.encoded).to include("don't match the format banks in your country use")
        expect(mail.body.encoded).to include("should be in the format AAAAPKBB or AAAAPKBBXYZ")
        expect(mail.body.encoded).to have_link("your payout settings", href: settings_payments_url)
      end

      it "does not promise an automatic re-check that cannot succeed" do
        expect(mail.body.encoded).not_to include("you don't need to do anything")
        expect(mail.body.encoded).not_to include("automatically re-check")
        expect(mail.body.encoded).to include("Waiting won't clear this one")
      end

      it "omits the format hint when Stripe's message doesn't carry one" do
        mail = ContactingCreatorMailer.invalid_bank_account(
          seller.id,
          StripeMerchantAccountManager::BANK_REJECTION_KIND_FORMAT,
          "Invalid account number"
        )

        expect(mail.subject).to eq("Your bank details need correcting for payouts.")
        expect(mail.body.encoded).not_to include("Here's the format your bank expects")
      end

      it "does not mistake Stripe's generic \"check the information provided\" line for a format hint" do
        mail = ContactingCreatorMailer.invalid_bank_account(
          seller.id,
          StripeMerchantAccountManager::BANK_REJECTION_KIND_FORMAT,
          "Invalid account number. Please double-check the information provided and try again."
        )

        expect(mail.body.encoded).not_to include("Here's the format your bank expects")
        expect(mail.body.encoded).not_to include("double-check the information provided")
      end

      it "drops an implausibly long format sentence instead of pasting it into the email" do
        mail = ContactingCreatorMailer.invalid_bank_account(
          seller.id,
          StripeMerchantAccountManager::BANK_REJECTION_KIND_FORMAT,
          "Invalid routing number. The expected format is described as follows: #{'a very long explanation ' * 20}."
        )

        expect(mail.body.encoded).not_to include("Here's the format your bank expects")
        expect(mail.body.encoded).to include("check your account and bank code against what your bank shows")
      end
    end

    context "when Stripe refused the account itself" do
      let(:unusable_message) do
        "This bank account can't be used because previous payments or payouts failed. Contact support at https://support.stripe.com/contact if you think this is an error."
      end
      let(:mail) do
        ContactingCreatorMailer.invalid_bank_account(
          seller.id,
          StripeMerchantAccountManager::BANK_REJECTION_KIND_TERMINAL,
          unusable_message
        )
      end

      it "asks for a different bank account rather than a corrected code" do
        expect(mail.to).to eq([seller.email])
        expect(mail.subject).to eq("We need a different bank account for your payouts.")
        expect(mail.body.encoded).to include("add a different bank account")
        expect(mail.body.encoded).to have_link("your payout settings", href: settings_payments_url)
      end

      it "does not promise a re-check and does not blame a typo" do
        expect(mail.body.encoded).not_to include("automatically re-check")
        expect(mail.body.encoded).not_to include("you don't need to do anything")
        expect(mail.body.encoded).not_to include("format banks in your country use")
        expect(mail.body.encoded).to include("won't clear on its own")
      end

      it "offers a way out for a seller who has no other account" do
        expect(mail.body.encoded).to include("reply to this email")
      end
    end

    context "when the bank simply isn't in the partner's records yet" do
      it "keeps the wait-and-we-will-re-check wording" do
        mail = ContactingCreatorMailer.invalid_bank_account(seller.id)

        expect(mail.subject).to eq("We couldn't verify your bank account yet.")
        expect(mail.body.encoded).to include("automatically re-check")
        expect(mail.body.encoded).to have_link("your payout settings", href: settings_payments_url)
      end

      it "quotes back both values and asks the seller to check both halves" do
        bank_account = create(:uzbekistan_bank_account, user: seller, bank_code: "JSCLUZ22XXX", branch_code: "00401")

        mail = ContactingCreatorMailer.invalid_bank_account(seller.id, nil, directory_miss_message, bank_account.id)

        expect(mail.body.encoded).to include("bank code JSCLUZ22XXX and branch code 00401")
        expect(mail.body.encoded).to include("check both")
        expect(mail.body.encoded).not_to include("branch code is the half")
      end

      it "omits the two-field advice for a country that collects one routing value" do
        bank_account = create(:ach_account, user: seller, routing_number: "110000000")

        mail = ContactingCreatorMailer.invalid_bank_account(seller.id, nil, directory_miss_message, bank_account.id)

        expect(mail.body.encoded).to include("routing number 110000000")
        expect(mail.body.encoded).not_to include("check both")
      end

      it "quotes nothing when the caller could not name the refused row" do
        # A job enqueued before the id argument existed. The seller may have re-saved since, so
        # naming the active row would attribute values Stripe never saw.
        create(:uzbekistan_bank_account, user: seller, bank_code: "JSCLUZ22XXX", branch_code: "00401")

        mail = ContactingCreatorMailer.invalid_bank_account(seller.id, nil, directory_miss_message)

        # Decoded, not .encoded: quoted-printable soft-wraps can split a quoted value across a
        # line break and make a negative assertion pass for the wrong reason.
        body = mail.html_part&.decoded || mail.body.decoded
        # Positive anchor from static template text — the header copy's apostrophes HTML-escape
        # ("couldn&#39;t"), so anchoring on those makes the negatives below vacuous.
        expect(body).to include("double-check your details")
        expect(body).not_to include("JSCLUZ22XXX")
        expect(body).not_to include("The details we sent were")
      end

      it "quotes the row Stripe refused, not whatever the seller has saved since" do
        # The mail renders asynchronously, and the #1550 seller re-saved six times in eleven
        # minutes. Re-saving soft-deletes the old row and makes the newest one active, so reading
        # the active row would tell them values that were never sent had been refused.
        rejected = create(:uzbekistan_bank_account, user: seller, bank_code: "JSCLUZ22XXX", branch_code: "00401")
        rejected.mark_deleted!
        replacement = create(:uzbekistan_bank_account, user: seller, bank_code: "KACHUZ22XXX", branch_code: "01158")
        expect(seller.reload.active_bank_account).to eq(replacement)

        mail = ContactingCreatorMailer.invalid_bank_account(seller.id, nil, directory_miss_message, rejected.id)

        expect(mail.body.encoded).to include("branch code 00401")
        expect(mail.body.encoded).not_to include("01158")
      end

      it "says nothing about routing values when the rejection was not a directory miss" do
        # A declined debit card and a bank-country mismatch both arrive with no rejection kind.
        # Quoting routing values at those sellers points them at a field that was never the problem.
        bank_account = create(:uzbekistan_bank_account, user: seller, bank_code: "JSCLUZ22XXX", branch_code: "00401")

        mail = ContactingCreatorMailer.invalid_bank_account(seller.id, nil, "Your card was declined.", bank_account.id)

        expect(mail.body.encoded).not_to include("JSCLUZ22XXX")
        expect(mail.body.encoded).not_to include("The details we sent were")
      end
    end

    context "when Stripe has block-listed the specific external account" do
      let(:mail) do
        ContactingCreatorMailer.invalid_bank_account(
          seller.id,
          StripeMerchantAccountManager::BANK_REJECTION_KIND_BLOCKED,
          "You cannot use this external account because it is on your block list. Please contact us via https://support.stripe.com/contact if you think this is an error."
        )
      end

      it "asks the seller for a different account" do
        expect(mail.to).to eq([seller.email])
        expect(mail.subject).to eq("Please add a different bank account for payouts.")
        expect(mail.body.encoded).to include("won't accept that particular account")
        expect(mail.body.encoded).to have_link("your payout settings", href: settings_payments_url)
      end

      it "does not tell the seller to check for typos or to wait" do
        # These are the two wrong instructions we used to send. A seller followed the second one
        # for three months, re-saving a perfectly valid account against a refusal that would
        # never lift (gumroad-private#1476), so both are pinned as absent rather than assumed.
        expect(mail.body.encoded).not_to include("automatically re-check")
        expect(mail.body.encoded).not_to include("you don't need to do anything")
        expect(mail.body.encoded).not_to include("have a typo")
        expect(mail.body.encoded).to include("re-entering them won't help")
      end

      it "does not promise that payouts will resume, since other payout holds can outlive this one" do
        # Adding a different account clears THIS destination only. A seller can still be held by
        # compliance, a missing tax form, or the minimum balance, so promising resumption sets up
        # a second round of "you said I'd get paid".
        expect(mail.body.encoded).not_to include("payouts will resume")
        expect(mail.body.encoded).to include("clears this particular hold")
      end

      it "does not leak Stripe's own message, which tells the seller to contact Stripe" do
        # Stripe's text points the seller at support.stripe.com, which cannot help them: the
        # block is on OUR connected account, not theirs.
        expect(mail.body.encoded).not_to include("support.stripe.com")
        expect(mail.body.encoded).not_to include("block list")
      end
    end
  end

  describe "#payout_setup_retry_exhausted" do
    let(:seller) { create(:user) }

    it "uses bank-specific wording for a bank marker" do
      mail = ContactingCreatorMailer.payout_setup_retry_exhausted(seller.id, "bank")

      expect(mail.to).to eq([seller.email])
      expect(mail.subject).to eq("We still couldn't verify your bank account.")
      expect(mail.body.encoded).to include("the bank account you added for Gumroad payouts")
      expect(mail.body.encoded).to have_link("your payout settings", href: settings_payments_url)
    end

    it "uses postal-specific wording for a postal marker" do
      mail = ContactingCreatorMailer.payout_setup_retry_exhausted(seller.id, "postal")

      expect(mail.to).to eq([seller.email])
      expect(mail.subject).to eq("We still couldn't verify your postal code.")
      expect(mail.body.encoded).to include("the postal code on your Gumroad payout details")
      expect(mail.body.encoded).to have_link("your payout settings", href: settings_payments_url)
    end

    it "does not send to a suspended seller" do
      seller.update!(user_risk_state: "suspended_for_fraud")

      mail = ContactingCreatorMailer.payout_setup_retry_exhausted(seller.id, "bank")

      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end
  end

  describe "#suspended_due_to_stripe_risk" do
    let(:seller) { create(:named_seller) }

    it "has the correct subject and body" do
      travel_to(Date.parse("2024-09-23")) do
        mail = ContactingCreatorMailer.suspended_due_to_stripe_risk(seller.id)

        expect(mail.to).to eq([seller.email])
        expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
        expect(mail.subject).to eq("Your account has been suspended for being high risk")

        expect(mail.body.encoded).to include("Hey,")
        expect(mail.body.encoded).to include("We want to first thank you for choosing Gumroad. We're really excited to help you get paid for your work and grow your business.")
        expect(mail.body.encoded).to include("However, our banking partners have found your account to be a high risk, so we are temporarily suspending your account.")
        expect(mail.body.encoded).to include("Of course, we will pay you out your remaining balance. Your existing customers' purchases will not be affected by this.")
        expect(mail.body.encoded).to include("And you can contact our support team to get your account reviewed again.")
        expect(mail.body.encoded).to include("We're super sorry about the inconvenience!")
      end
    end
  end

  describe "product_level_refund_policies_reverted" do
    let(:seller) { create(:user) }

    it "sends the email correctly" do
      mail = ContactingCreatorMailer.product_level_refund_policies_reverted(seller.id)

      expect(mail.to).to eq [seller.email]
      expect(mail.subject).to eq "Important: Refund policy changes effective immediately"
      expect(mail.body.encoded).to include "Hey #{seller.name_or_username},"
    end
  end

  describe "refund_policy_enforced_notification" do
    let(:seller) { create(:user) }

    it "sends the email correctly" do
      mail = ContactingCreatorMailer.refund_policy_enforced_notification(seller.id)

      expect(mail.to).to eq [seller.email]
      expect(mail.subject).to eq "Important: Your refund policy has been updated"
      expect(mail.body.encoded).to include "Hey #{seller.name_or_username},"
      expect(mail.body.encoded).to include seller.refund_policy.title
      expect(mail.body.encoded).to include "high rate of chargebacks"
      expect(mail.body.encoded).to include "reply to this email with the specific steps"
    end

    it "does not send when the seller's account is not active" do
      seller.update!(user_risk_state: "suspended_for_fraud")

      mail = ContactingCreatorMailer.refund_policy_enforced_notification(seller.id)

      expect(mail.to).to be_nil
    end
  end

  describe "#flagged_for_explicit_nsfw_tos_violation" do
    let(:seller) { create(:named_seller) }

    it "has the correct subject and body" do
      travel_to(Date.parse("2024-03-28")) do
        mail = ContactingCreatorMailer.flagged_for_explicit_nsfw_tos_violation(seller.id)

        expect(mail.to).to eq([seller.email])
        expect(mail.from).to eq([ApplicationMailer::NOREPLY_EMAIL])
        expect(mail.subject).to eq("Your account has been temporarily suspended for selling sexually explicit / fetish-related content")

        expect(mail.body.encoded).to include("Hey,")
        expect(mail.body.encoded).to include("We want to first thank you for choosing Gumroad. We're really excited to help you get paid for your work and grow your business.")
        expect(mail.body.encoded).to include("However, due to more stringent banking regulations, we can no longer allow sexually explicit or fetish-oriented materials to be sold on Gumroad, and it looks like at least one of your products could be considered in violation of these rules.")
        expect(mail.body.encoded).to include("As a result, we've temporarily paused sales of the affected products and payouts for your account.")
        expect(mail.body.encoded).to include("Your account will be permanently suspended in 10 days, on 7 April, if your storefront is not updated to be compliant by then.")
        expect(mail.body.encoded).to include("Of course, we will pay you out your remaining balance. Your existing customers' purchases will not be affected by this.")
        expect(mail.body.encoded).to include("We're super sorry about the inconvenience!")
      end
    end
  end
end
