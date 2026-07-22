# frozen_string_literal: true

require "spec_helper"

describe RetryTransientEmailFailureJob do
  let(:user) { create(:unconfirmed_user, email: "new-seller@brand-new-domain.com") }
  let(:retry_record) do
    TransientEmailFailureRetry.create!(
      email: user.email,
      mail_kind: TransientEmailFailureRetry::SIGNUP_CONFIRMATION,
      attempts: 0,
      retry_in_flight: true,
      last_reason: "i/o timeout"
    )
  end

  describe "#perform" do
    it "removes the address from the bounce and block suppression lists, re-sends the confirmation email, and increments the attempt counter" do
      suppression_manager = instance_double(EmailSuppressionManager)
      expect(EmailSuppressionManager).to receive(:new).with(user.email).and_return(suppression_manager)
      expect(suppression_manager).to receive(:remove_from_lists).with([:bounces, :blocks])

      expect do
        described_class.new.perform(retry_record.id)
      end.to have_enqueued_mail(UserSignupMailer, :confirmation_instructions).with { |record, *| expect(record).to eq(user) }

      retry_record.reload
      expect(retry_record.attempts).to eq(1)
      expect(retry_record.retry_in_flight).to eq(false)
    end

    it "never touches spam report or unsubscribe suppression lists" do
      suppression_manager = instance_double(EmailSuppressionManager)
      allow(EmailSuppressionManager).to receive(:new).and_return(suppression_manager)
      allow(suppression_manager).to receive(:remove_from_lists)

      described_class.new.perform(retry_record.id)

      expect(suppression_manager).to have_received(:remove_from_lists) do |lists|
        expect(lists).not_to include(:spam_reports)
        expect(lists).not_to include(:global_unsubscribes)
      end
    end

    it "skips the resend and clears the in-flight flag when the user has confirmed in the meantime" do
      user.confirm

      expect(EmailSuppressionManager).not_to receive(:new)
      expect do
        described_class.new.perform(retry_record.id)
      end.not_to have_enqueued_mail(UserSignupMailer, :confirmation_instructions)

      retry_record.reload
      expect(retry_record.attempts).to eq(0)
      expect(retry_record.retry_in_flight).to eq(false)
    end

    it "resends to the pending address when the user is re-confirming an email change" do
      confirmed_user = create(:user)
      confirmed_user.update!(unconfirmed_email: "pending@example.com")
      record = TransientEmailFailureRetry.create!(
        email: "pending@example.com",
        mail_kind: TransientEmailFailureRetry::SIGNUP_CONFIRMATION,
        retry_in_flight: true
      )
      suppression_manager = instance_double(EmailSuppressionManager, remove_from_lists: {})
      allow(EmailSuppressionManager).to receive(:new).and_return(suppression_manager)

      expect do
        described_class.new.perform(record.id)
      end.to have_enqueued_mail(UserSignupMailer, :confirmation_instructions).with { |mail_record, *| expect(mail_record).to eq(confirmed_user) }
    end

    it "restores the in-flight claim and re-raises when the resend fails, so a Sidekiq re-run can retry it" do
      retry_record # force lazy creation now — creating the unconfirmed user enqueues its own confirmation email
      suppression_manager = instance_double(EmailSuppressionManager)
      allow(EmailSuppressionManager).to receive(:new).and_return(suppression_manager)
      allow(suppression_manager).to receive(:remove_from_lists).and_raise(StandardError.new("suppression API unavailable"))

      expect do
        expect do
          described_class.new.perform(retry_record.id)
        end.to raise_error(StandardError, "suppression API unavailable")
      end.not_to have_enqueued_mail(UserSignupMailer, :confirmation_instructions)

      retry_record.reload
      expect(retry_record.attempts).to eq(0)
      expect(retry_record.retry_in_flight).to eq(true)

      # The restored claim lets the Sidekiq re-run of this job through the
      # claim guard and complete the send.
      allow(suppression_manager).to receive(:remove_from_lists).and_return({})
      expect do
        described_class.new.perform(retry_record.id)
      end.to have_enqueued_mail(UserSignupMailer, :confirmation_instructions)

      retry_record.reload
      expect(retry_record.attempts).to eq(1)
      expect(retry_record.retry_in_flight).to eq(false)
    end

    it "still un-counts the failed attempt when a newer claim re-took the row before the rollback" do
      retry_record # force lazy creation now — creating the unconfirmed user enqueues its own confirmation email
      suppression_manager = instance_double(EmailSuppressionManager)
      allow(EmailSuppressionManager).to receive(:new).and_return(suppression_manager)
      # Simulate a delayed provider failure event re-claiming the row in the
      # window between this job's claim (attempts incremented, flag cleared)
      # and the rescue's rollback: the claim is back to true when the
      # rollback runs. The rollback must still give the failed attempt back —
      # otherwise repeated failures could exhaust MAX_ATTEMPTS with fewer
      # emails actually sent.
      allow(suppression_manager).to receive(:remove_from_lists) do
        TransientEmailFailureRetry.where(id: retry_record.id).update_all(retry_in_flight: true)
        raise StandardError, "suppression API unavailable"
      end

      expect do
        expect do
          described_class.new.perform(retry_record.id)
        end.to raise_error(StandardError, "suppression API unavailable")
      end.not_to have_enqueued_mail(UserSignupMailer, :confirmation_instructions)

      retry_record.reload
      expect(retry_record.attempts).to eq(0)
      expect(retry_record.retry_in_flight).to eq(true)
    end

    it "leaves a newer job's consumed claim alone when the rollback runs after that job already re-claimed and started" do
      retry_record # force lazy creation now — creating the unconfirmed user enqueues its own confirmation email
      suppression_manager = instance_double(EmailSuppressionManager)
      allow(EmailSuppressionManager).to receive(:new).and_return(suppression_manager)
      # Simulate the double race: after this job's claim, a delayed failure
      # event re-claims the row AND the newer scheduled retry job consumes
      # that replacement claim (its own attempt increment, flag cleared) —
      # all before this job's rescue runs. The rollback must NOT fire here:
      # decrementing would erase the newer job's attempt, and restoring the
      # flag would recreate a claim this job's Sidekiq re-run could consume,
      # double-sending the confirmation email.
      allow(suppression_manager).to receive(:remove_from_lists) do
        TransientEmailFailureRetry
          .where(id: retry_record.id)
          .update_all("attempts = attempts + 1, retry_in_flight = false")
        raise StandardError, "suppression API unavailable"
      end

      expect do
        expect do
          described_class.new.perform(retry_record.id)
        end.to raise_error(StandardError, "suppression API unavailable")
      end.not_to have_enqueued_mail(UserSignupMailer, :confirmation_instructions)

      retry_record.reload
      expect(retry_record.attempts).to eq(2)
      expect(retry_record.retry_in_flight).to eq(false)
    end

    it "does not resend when no in-flight claim exists (e.g. a Sidekiq re-run after a completed attempt)" do
      retry_record.update!(retry_in_flight: false, attempts: 1)

      expect(EmailSuppressionManager).not_to receive(:new)
      expect do
        described_class.new.perform(retry_record.id)
      end.not_to have_enqueued_mail(UserSignupMailer, :confirmation_instructions)

      expect(retry_record.reload.attempts).to eq(1)
    end

    it "does nothing when the retry record no longer exists" do
      expect do
        described_class.new.perform(-1)
      end.not_to have_enqueued_mail(UserSignupMailer, :confirmation_instructions)
    end

    describe "receipt retries" do
      let(:purchase) { create(:free_purchase) }
      let(:receipt_retry) do
        TransientEmailFailureRetry.create!(
          email: purchase.email,
          mail_kind: TransientEmailFailureRetry::RECEIPT,
          pending_targets: [{ "purchase_id" => purchase.id }],
          attempts: 0,
          retry_in_flight: true,
          last_reason: "i/o timeout"
        )
      end

      it "unsuppresses the address and re-enqueues the purchase receipt" do
        suppression_manager = instance_double(EmailSuppressionManager)
        expect(EmailSuppressionManager).to receive(:new).with(purchase.email).and_return(suppression_manager)
        expect(suppression_manager).to receive(:remove_from_lists).with([:bounces, :blocks])

        described_class.new.perform(receipt_retry.id)

        expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(purchase.id)
        receipt_retry.reload
        expect(receipt_retry.attempts).to eq(1)
        expect(receipt_retry.retry_in_flight).to eq(false)
        expect(receipt_retry.pending_targets).to eq([])
      end

      it "re-sends every pending receipt when several failed for the same address" do
        second_purchase = create(:free_purchase, email: purchase.email)
        record = TransientEmailFailureRetry.create!(
          email: purchase.email,
          mail_kind: TransientEmailFailureRetry::RECEIPT,
          pending_targets: [
            { "purchase_id" => purchase.id },
            { "purchase_id" => second_purchase.id },
          ],
          retry_in_flight: true
        )
        suppression_manager = instance_double(EmailSuppressionManager, remove_from_lists: {})
        allow(EmailSuppressionManager).to receive(:new).and_return(suppression_manager)

        described_class.new.perform(record.id)

        expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(purchase.id)
        expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(second_purchase.id)
        record.reload
        # One claimed attempt covers all pending receipts for the address.
        expect(record.attempts).to eq(1)
        expect(record.pending_targets).to eq([])
      end

      it "re-sends the combined receipt when the retry is pinned to a charge" do
        charge = create(:charge, purchases: [purchase])
        charge.order.purchases << purchase
        record = TransientEmailFailureRetry.create!(
          email: purchase.email,
          mail_kind: TransientEmailFailureRetry::RECEIPT,
          pending_targets: [{ "charge_id" => charge.id }],
          retry_in_flight: true
        )
        suppression_manager = instance_double(EmailSuppressionManager, remove_from_lists: {})
        allow(EmailSuppressionManager).to receive(:new).and_return(suppression_manager)

        expect do
          described_class.new.perform(record.id)
        end.to have_enqueued_mail(CustomerMailer, :receipt).with(nil, charge.id)

        expect(record.reload.attempts).to eq(1)
      end

      it "skips the charge resend when the order's receipt recipient no longer matches the failed address" do
        # The mailer picks the charge's recipient through order.email (the
        # order's first successful purchase), so the guard must compare
        # against that same address — not an arbitrary purchase on the charge.
        charge = create(:charge, purchases: [purchase])
        recipient_purchase = create(:free_purchase, email: "corrected@example.com")
        charge.order.purchases << recipient_purchase
        record = TransientEmailFailureRetry.create!(
          email: purchase.email,
          mail_kind: TransientEmailFailureRetry::RECEIPT,
          pending_targets: [{ "charge_id" => charge.id }],
          retry_in_flight: true
        )

        expect(EmailSuppressionManager).not_to receive(:new)
        described_class.new.perform(record.id)

        record.reload
        expect(record.attempts).to eq(0)
        expect(record.retry_in_flight).to eq(false)
        expect(record.pending_targets).to eq([])
      end

      it "skips the resend and clears the claim when the purchase no longer exists" do
        record = TransientEmailFailureRetry.create!(
          email: purchase.email,
          mail_kind: TransientEmailFailureRetry::RECEIPT,
          pending_targets: [{ "purchase_id" => -1 }],
          retry_in_flight: true
        )

        expect(EmailSuppressionManager).not_to receive(:new)
        described_class.new.perform(record.id)

        record.reload
        expect(record.attempts).to eq(0)
        expect(record.retry_in_flight).to eq(false)
        expect(record.pending_targets).to eq([])
        expect(SendPurchaseReceiptJob.jobs).to be_empty
      end

      it "skips the resend when the purchase's email has since been corrected to a different address" do
        receipt_retry
        purchase.update_column(:email, "corrected@example.com")

        expect(EmailSuppressionManager).not_to receive(:new)
        described_class.new.perform(receipt_retry.id)

        receipt_retry.reload
        expect(receipt_retry.attempts).to eq(0)
        expect(receipt_retry.retry_in_flight).to eq(false)
        expect(receipt_retry.pending_targets).to eq([])
        expect(SendPurchaseReceiptJob.jobs).to be_empty
      end

      it "restores the in-flight claim and re-raises when the unsuppress call fails" do
        receipt_retry
        suppression_manager = instance_double(EmailSuppressionManager)
        allow(EmailSuppressionManager).to receive(:new).and_return(suppression_manager)
        allow(suppression_manager).to receive(:remove_from_lists).and_raise(StandardError.new("suppression API unavailable"))

        expect do
          described_class.new.perform(receipt_retry.id)
        end.to raise_error(StandardError, "suppression API unavailable")

        receipt_retry.reload
        expect(receipt_retry.attempts).to eq(0)
        expect(receipt_retry.retry_in_flight).to eq(true)
        # The unsent target stays queued for the Sidekiq re-run.
        expect(receipt_retry.pending_targets).to eq([{ "purchase_id" => purchase.id }])
        expect(SendPurchaseReceiptJob.jobs).to be_empty
      end
    end
  end
end
