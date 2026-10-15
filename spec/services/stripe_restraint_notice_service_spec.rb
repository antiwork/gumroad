# frozen_string_literal: true

require "spec_helper"

describe StripeRestraintNoticeService do
  let(:seller) { create(:user, email: "restrained-seller@example.com") }
  let(:account_id) { "acct_1SA76bS5BbOI7YuG" }
  let(:notice_key) { "stripe-restraint:#{account_id}:cwallace@scalefirm.com:8f14e45f" }
  let(:notice_params) do
    {
      stripe_account_id: account_id,
      firm_name: "Scale LLP",
      firm_email: "cwallace@scalefirm.com",
      notice_key:,
    }
  end

  let!(:merchant_account) { create(:merchant_account, user: seller, charge_processor_merchant_id: account_id) }

  describe ".resolve_user!" do
    it "resolves the seller from the Stripe account id" do
      expect(described_class.resolve_user!(account_id)).to eq(seller)
    end

    it "rejects a value that is not a Stripe account id" do
      expect { described_class.resolve_user!("12345") }
        .to raise_error(described_class::InvalidNoticeError, /acct_/)
    end

    it "fails when no live user owns the account" do
      merchant_account.mark_deleted!

      expect { described_class.resolve_user!(account_id) }
        .to raise_error(described_class::UserNotFoundError, /no live user/)
    end

    it "fails when the owning user has no email address" do
      seller.update_columns(email: "")

      expect { described_class.resolve_user!(account_id) }
        .to raise_error(described_class::UserNotFoundError, /no live user/)
    end

    it "fails when the account maps to more than one live user" do
      other = create(:user, email: "other-owner@example.com")
      # Written past the uniqueness validation on purpose: the point of the rule is what the
      # endpoint does when Stripe's account id is not unique, not whether the write is allowed.
      create(:merchant_account, user: other, charge_processor_merchant_id: "acct_other").update_column(:charge_processor_merchant_id, account_id)

      expect { described_class.resolve_user!(account_id) }
        .to raise_error(described_class::AmbiguousUserError, /2 live users/)
    end
  end

  describe ".call" do
    it "requires the firm and the notice key" do
      expect { described_class.call(**notice_params.merge(firm_email: "")) }
        .to raise_error(described_class::InvalidNoticeError, /firm_email/)
      expect { described_class.call(**notice_params.merge(firm_name: " ")) }
        .to raise_error(described_class::InvalidNoticeError, /firm_name/)
      expect { described_class.call(**notice_params.merge(notice_key: nil)) }
        .to raise_error(described_class::InvalidNoticeError, /notice_key/)
    end

    it "returns the matched user and the rendered email on a dry run, and writes nothing" do
      result = nil

      expect do
        result = described_class.call(**notice_params)
      end.to_not change { [seller.comments.count, AdminApiAuditLog.count] }

      expect(result.user_external_id).to eq(seller.external_id)
      expect(result.email).to eq(seller.email)
      expect(result.comment_id).to be_nil
      expect(result.already_sent).to be(false)
      expect(result.rendered_email[:to]).to eq(seller.email)
      expect(result.rendered_email[:reply_to]).to eq(ApplicationMailer::SUPPORT_EMAIL)
      expect(result.rendered_email[:subject]).to eq("Important notice regarding your Gumroad payment account")
      expect(result.rendered_email[:body]).to include("Scale LLP", "cwallace@scalefirm.com", "court order")
      expect(result.rendered_email[:body]).to include("Your payouts are paused")
    end

    it "records the notice once and queues the seller notice" do
      result = nil

      expect do
        result = described_class.call(**notice_params.merge(dry_run: false))
      end.to change { seller.comments.where(idempotency_key: notice_key).count }.by(1)
        .and have_enqueued_mail(MerchantRegistrationMailer, :stripe_restraint_notice)
        .with(seller.id, "Scale LLP", "cwallace@scalefirm.com")

      expect(result.already_sent).to be(false)
      expect(result.comment_id).to eq(seller.comments.find_by(idempotency_key: notice_key).id)
      expect(seller.comments.find_by(idempotency_key: notice_key).content).to eq(described_class.comment_content(**notice_params))
    end

    it "does not notify twice for the same notice key" do
      described_class.call(**notice_params.merge(dry_run: false))

      result = nil
      expect do
        result = described_class.call(**notice_params.merge(dry_run: false))
      end.to_not have_enqueued_mail(MerchantRegistrationMailer, :stripe_restraint_notice)

      expect(result.already_sent).to be(true)
      expect(result.comment_id).to be_present
      expect(seller.comments.where(idempotency_key: notice_key).count).to eq(1)
    end

    it "reports already_sent on a dry run once the notice has been handled" do
      described_class.call(**notice_params.merge(dry_run: false))

      result = described_class.call(**notice_params)

      expect(result.already_sent).to be(true)
      expect(result.rendered_email).to be_present
    end

    it "surfaces a repeat with different content as a conflict" do
      described_class.call(**notice_params.merge(dry_run: false))

      expect do
        described_class.call(**notice_params.merge(firm_name: "Other LLP", dry_run: false))
      end.to raise_error(User::CreateAdminCommentService::IdempotencyConflictError)
    end
  end
end
