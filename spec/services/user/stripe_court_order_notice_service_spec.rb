# frozen_string_literal: true

require "spec_helper"

describe User::StripeCourtOrderNoticeService do
  let(:admin_user) { create(:admin_user) }
  let(:seller) { create(:user, email: "seller@example.com") }
  let(:stripe_account_id) { "acct_1TestCourtOrder01" }
  let(:firm_name) { "Example Legal LLP" }
  let(:firm_email) { "notices@example.com" }
  let(:notice_key) { "test-court-order-notice-0001" }
  let(:attributes) { { stripe_account_id:, firm_name:, firm_email:, notice_key:, author_id: admin_user.id } }

  before { create(:merchant_account, user: seller, charge_processor_merchant_id: stripe_account_id) }

  def notice(**overrides)
    described_class.new(**attributes, **overrides)
  end

  def expect_error(service, status, message)
    expect { yield service }.to raise_error(described_class::Error, message) { |error| expect(error.status).to eq(status) }
  end

  def notice_comments
    seller.comments.where(idempotency_key: "stripe_court_order_notice:#{Digest::SHA256.hexdigest(notice_key)}")
  end

  describe "input validation" do
    [
      ["a missing Stripe account id", { stripe_account_id: nil }, /stripe_account_id must be/],
      ["a Stripe id of another kind", { stripe_account_id: "cus_1TestCourtOrder01" }, /stripe_account_id must be/],
      ["a Stripe account id with a line break", { stripe_account_id: "acct_1Test\nBcc: x" }, /stripe_account_id must be/],
      ["a Stripe account id sent as a list", { stripe_account_id: ["acct_1TestCourtOrder01"] }, /stripe_account_id must be/],
      ["a blank firm name", { firm_name: "  " }, /firm_name is required/],
      ["a firm name with a line break", { firm_name: "Example Legal\r\nBcc: someone@example.com" }, /control characters/],
      ["a firm name with a bidi override", { firm_name: "Example ‮Legal" }, /control characters/],
      ["a firm name that is too long", { firm_name: "A" * 201 }, /firm_name is too long/],
      ["a firm email with a display name", { firm_email: "Example Legal <notices@example.com>" }, /single email address/],
      ["two firm emails", { firm_email: "notices@example.com, other@example.com" }, /single email address/],
      ["a firm email with an injected header", { firm_email: "notices@example.com\r\nBcc: x@example.com" }, /single email address/],
      ["a firm email without a domain", { firm_email: "notices@" }, /single email address/],
      ["a notice key with spaces", { notice_key: "notice key" }, /notice_key must be/],
      ["a notice key that is too long", { notice_key: "k" * 201 }, /notice_key must be/],
    ].each do |description, overrides, message|
      it "rejects #{description} before reading or writing anything" do
        service = notice(**overrides)
        expect(MerchantAccount).not_to receive(:stripe)

        expect_error(service, :unprocessable_entity, message) { _1.perform }
        expect(Comment.count).to eq(0)
        expect(StripeCourtOrderNoticeEmailJob.jobs.size).to eq(0)
      end
    end
  end

  describe "seller lookup" do
    it "rejects an account id no seller uses" do
      expect_error(notice(stripe_account_id: "acct_1TestUnknown0001"), :not_found, /No Gumroad account uses/) { _1.perform }
    end

    it "rejects an account id that differs only by case, since Stripe ids are case-sensitive" do
      expect_error(notice(stripe_account_id: "acct_1testcourtorder01"), :not_found, /No Gumroad account uses/) { _1.perform }
    end

    it "ignores a PayPal merchant account with the same id" do
      create(:merchant_account_paypal, user: create(:user), charge_processor_merchant_id: stripe_account_id)

      expect(notice.user).to eq(seller)
    end

    def share_account_with(user)
      create(:merchant_account, user:).update_columns(charge_processor_merchant_id: stripe_account_id, deleted_at: 1.day.ago)
    end

    it "rejects an account id that maps to two live sellers" do
      share_account_with(create(:user))

      expect_error(notice, :conflict, /more than one live Gumroad account/) { _1.perform }
      expect(Comment.count).to eq(0)
    end

    it "rejects two live owners even when only one of them has an email address" do
      share_account_with(create(:user).tap { _1.update_column(:email, "") })

      expect_error(notice, :conflict, /more than one live Gumroad account/) { _1.perform }
    end

    it "matches the one live owner when a deleted account also used the Stripe account" do
      share_account_with(create(:user, deleted_at: 1.month.ago))

      expect(notice.user).to eq(seller)
    end

    it "ignores a merchant account row without an owner" do
      create(:merchant_account, user: nil).update_columns(charge_processor_merchant_id: stripe_account_id)

      expect(notice.user).to eq(seller)
    end

    it "matches the seller through a disconnected merchant account" do
      seller.merchant_accounts.update_all(deleted_at: 1.day.ago)

      expect(notice.user).to eq(seller)
    end

    it "rejects a deleted seller" do
      seller.update_column(:deleted_at, 1.day.ago)

      expect_error(notice, :unprocessable_entity, /is deleted/) { _1.perform }
    end

    it "rejects a seller without an email address" do
      seller.update_column(:email, "")

      expect_error(notice, :unprocessable_entity, /has no email address/) { _1.perform }
    end
  end

  describe "#preview" do
    it "returns the matched seller and the rendered email without writing, queueing or sending" do
      writes = []
      callback = ->(*, payload) { writes << payload[:sql] if payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE|REPLACE)/i) }

      service = notice

      result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { service.preview }

      expect(writes).to eq([])
      expect(StripeCourtOrderNoticeEmailJob.jobs.size).to eq(0)
      expect(ActionMailer::Base.deliveries).to be_empty
      expect(Comment.count).to eq(0)
      expect(result.status).to eq(:dry_run)
      expect(result.user).to eq(seller)
      expect(result.comment).to be_nil
      expect(result.mail.to).to eq(["seller@example.com"])
      expect(result.mail.from).to eq([ApplicationMailer::NOREPLY_EMAIL])
      expect(result.mail.reply_to).to eq([ApplicationMailer::SUPPORT_EMAIL])
      expect(result.mail.subject).to eq("Important notice regarding your Gumroad payment account")
      expect(result.mail.body.decoded).to include("Law firm: Example Legal LLP")
    end

    it "reports a notice that was already queued" do
      queued = notice.perform

      result = notice.preview

      expect(result.comment).to eq(queued.comment)
      expect(StripeCourtOrderNoticeEmailJob.jobs.size).to eq(1)
    end

    it "rejects a notice key that was used for a different notice" do
      notice.perform

      expect_error(notice(firm_name: "Other Legal LLP"), :conflict, /already used for a different notice/) { _1.preview }
    end
  end

  describe "#perform" do
    it "records an admin comment and queues one email job" do
      result = notice.perform

      expect(result.status).to eq(:queued)
      comment = notice_comments.sole
      expect(result.comment).to eq(comment)
      expect(comment.author_id).to eq(admin_user.id)
      expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_NOTE)
      expect(comment.content).to eq(
        "Stripe court order notice for acct_1TestCourtOrder01: Stripe paused this account's payouts under a court order. " \
        "Queued an email to the seller with the law firm's contact: Example Legal LLP (notices@example.com). " \
        "Notice key: test-court-order-notice-0001"
      )
      expect(StripeCourtOrderNoticeEmailJob).to have_enqueued_sidekiq_job(seller.id, comment.id, firm_name, firm_email)
      expect(StripeCourtOrderNoticeEmailJob.jobs.size).to eq(1)

      StripeCourtOrderNoticeEmailJob.drain

      mail = ActionMailer::Base.deliveries.sole
      expect(mail.to).to eq(["seller@example.com"])
      expect(mail.body.encoded).to include("notices@example.com")
    end

    it "returns already_sent without queueing again for a repeat of the same notice" do
      first = notice.perform

      second = notice.perform

      expect(second.status).to eq(:already_sent)
      expect(second.comment).to eq(first.comment)
      expect(notice_comments.count).to eq(1)
      expect(StripeCourtOrderNoticeEmailJob.jobs.size).to eq(1)
    end

    it "rejects a notice key reused with a different payload and queues nothing" do
      notice.perform

      expect_error(notice(firm_email: "other@example.com"), :conflict, /already used for a different notice/) { _1.perform }
      expect(notice_comments.count).to eq(1)
      expect(StripeCourtOrderNoticeEmailJob.jobs.size).to eq(1)
    end

    it "rejects a seller deleted after the lookup, under the row lock" do
      service = notice
      service.user
      User.where(id: seller.id).update_all(deleted_at: Time.current)

      expect_error(service, :unprocessable_entity, /is deleted/) { _1.perform }
      expect(Comment.count).to eq(0)
      expect(StripeCourtOrderNoticeEmailJob.jobs.size).to eq(0)
    end

    it "queues nothing when the comment does not save" do
      unsaved = seller.comments.new
      unsaved.errors.add(:base, "Adult keywords are not allowed")
      allow_any_instance_of(User::CreateAdminCommentService).to receive(:perform).and_return(unsaved)

      expect_error(notice, :unprocessable_entity, "Adult keywords are not allowed") { _1.perform }
      expect(StripeCourtOrderNoticeEmailJob.jobs.size).to eq(0)
    end

    it "stores the longest allowed notice key" do
      long_key = "k" * 200

      comment = notice(notice_key: long_key).perform.comment.reload

      expect(comment.idempotency_key).to eq("stripe_court_order_notice:#{Digest::SHA256.hexdigest(long_key)}")
      expect(comment.content).to end_with("Notice key: #{long_key}")
    end

    it "keeps notice keys that differ only by case apart" do
      expect(notice(notice_key: "Notice-Key-0001").perform.status).to eq(:queued)
      expect(notice(notice_key: "notice-key-0001").perform.status).to eq(:queued)

      expect(seller.comments.count).to eq(2)
      expect(StripeCourtOrderNoticeEmailJob.jobs.size).to eq(2)
    end

    it "rolls the comment back when the job push is refused" do
      allow(StripeCourtOrderNoticeEmailJob).to receive(:perform_async).and_return(nil)

      expect_error(notice, :service_unavailable, "The notice email could not be queued") { _1.perform }
      expect(Comment.count).to eq(0)
    end

    it "rolls the comment back when the job push fails, so a retry still sends" do
      allow(StripeCourtOrderNoticeEmailJob).to receive(:perform_async).and_raise(RedisClient::CannotConnectError, "Connection refused")

      expect { notice.perform }.to raise_error(RedisClient::CannotConnectError)
      expect(Comment.count).to eq(0)

      allow(StripeCourtOrderNoticeEmailJob).to receive(:perform_async).and_call_original
      expect(notice.perform.status).to eq(:queued)
      StripeCourtOrderNoticeEmailJob.drain

      expect(ActionMailer::Base.deliveries.size).to eq(1)
    end

    it "sends once when the transaction rolls back after the job was pushed" do
      allow(StripeCourtOrderNoticeEmailJob).to receive(:perform_async).and_wrap_original do |original, *args|
        original.call(*args)
        raise ActiveRecord::ConnectionFailed, "lost connection before commit"
      end

      expect { notice.perform }.to raise_error(ActiveRecord::ConnectionFailed)
      expect(Comment.count).to eq(0)
      expect(StripeCourtOrderNoticeEmailJob.jobs.size).to eq(1)

      StripeCourtOrderNoticeEmailJob.drain
      expect(ActionMailer::Base.deliveries).to be_empty

      allow(StripeCourtOrderNoticeEmailJob).to receive(:perform_async).and_call_original
      expect(notice.perform.status).to eq(:queued)
      StripeCourtOrderNoticeEmailJob.drain

      expect(ActionMailer::Base.deliveries.size).to eq(1)
    end
  end
end
