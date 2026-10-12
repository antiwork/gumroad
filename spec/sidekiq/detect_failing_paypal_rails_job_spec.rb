# frozen_string_literal: true

require "spec_helper"

describe DetectFailingPaypalRailsJob do
  let(:seller) { create(:user) }
  let!(:merchant_account) { create(:merchant_account_paypal, user: seller) }
  let(:threshold) { described_class::MIN_FAILED_ATTEMPTS }

  def create_purchases(count, state:, account: merchant_account, created_at: 1.day.ago, charge_processor_id: PaypalChargeProcessor.charge_processor_id, **attrs)
    attrs = { error_code: PurchaseErrorCode::PAYPAL_PAYEE_COMPLIANCE_VIOLATION }.merge(attrs) if state == "failed"
    product = create(:product, user: account.user || create(:user))
    create_list(:purchase, count, link: product, purchase_state: state, merchant_account: account, charge_processor_id:, created_at:, **attrs)
  end

  def notes_for(user)
    user.comments.with_type_note.where(author_name: described_class::AUTHOR_NAME)
  end

  describe "#perform" do
    it "notes a connected PayPal account with repeated failures and no completions" do
      create_purchases(threshold, state: "failed")

      expect { described_class.new.perform }.to change { notes_for(seller).count }.by(1)

      content = notes_for(seller).last.content
      expect(content).to include("(#{merchant_account.charge_processor_merchant_id})")
      expect(content).to include("#{threshold} failed PayPal payee-side purchase attempts")
    end

    it "notes an account whose failures carry the restricted merchant account code" do
      create_purchases(threshold, state: "failed", error_code: nil, stripe_error_code: PurchaseErrorCode::PAYPAL_MERCHANT_ACCOUNT_RESTRICTED)

      expect { described_class.new.perform }.to change { notes_for(seller).count }.by(1)
    end

    it "does not count buyer-side declines" do
      create_purchases(threshold, state: "failed", error_code: PurchaseErrorCode::PAYPAL_PAYER_ACCOUNT_DECLINED_PAYMENT, stripe_error_code: nil)
      create_purchases(threshold, state: "failed", error_code: nil, stripe_error_code: nil)

      expect { described_class.new.perform }.not_to change { Comment.count }
    end

    it "does not note an account one failure below the threshold" do
      create_purchases(threshold - 1, state: "failed")

      expect { described_class.new.perform }.not_to change { Comment.count }
    end

    it "does not count failures older than the lookback window" do
      create_purchases(threshold, state: "failed", created_at: described_class::LOOKBACK.ago - 1.hour)

      expect { described_class.new.perform }.not_to change { Comment.count }
    end

    it "does not note an account with a successful PayPal completion in the window" do
      create_purchases(threshold + 5, state: "failed")
      create_purchases(1, state: "successful")

      expect { described_class.new.perform }.not_to change { Comment.count }
    end

    it "notes an account whose only completion is older than the window" do
      create_purchases(threshold, state: "failed")
      create_purchases(1, state: "successful", created_at: described_class::LOOKBACK.ago - 1.hour)

      expect { described_class.new.perform }.to change { notes_for(seller).count }.by(1)
    end

    it "ignores a PayPal account that is no longer connected" do
      merchant_account.update!(charge_processor_deleted_at: Time.current)
      create_purchases(threshold, state: "failed")

      expect { described_class.new.perform }.not_to change { Comment.count }
    end

    it "ignores a soft-deleted merchant account" do
      merchant_account.update!(deleted_at: Time.current)
      create_purchases(threshold, state: "failed")

      expect { described_class.new.perform }.not_to change { Comment.count }
    end

    it "ignores a platform-owned PayPal account with no user" do
      platform_account = create(:merchant_account_paypal, user: nil)
      create_purchases(threshold, state: "failed", account: platform_account)

      expect { described_class.new.perform }.not_to change { Comment.count }
    end

    it "ignores a PayPal account that was never marked alive" do
      merchant_account.update!(charge_processor_alive_at: nil)
      create_purchases(threshold, state: "failed")

      expect { described_class.new.perform }.not_to change { Comment.count }
    end

    it "ignores failures on non-PayPal merchant accounts" do
      stripe_account = create(:merchant_account, user: seller)
      create_purchases(threshold, state: "failed", account: stripe_account, charge_processor_id: StripeChargeProcessor.charge_processor_id)

      expect { described_class.new.perform }.not_to change { Comment.count }
    end

    it "notes each qualifying account on its own seller" do
      other_account = create(:merchant_account_paypal, user: create(:user))
      create_purchases(threshold, state: "failed")
      create_purchases(threshold, state: "failed", account: other_account)

      expect { described_class.new.perform }.to change { Comment.count }.by(2)
      expect(notes_for(other_account.user).count).to eq(1)
    end

    it "applies the same rules to every account when accounts are processed in batches" do
      stub_const("#{described_class}::BATCH_SIZE", 1)
      completed_account = create(:merchant_account_paypal, user: create(:user))
      below_threshold_account = create(:merchant_account_paypal, user: create(:user))
      other_account = create(:merchant_account_paypal, user: create(:user))
      create_purchases(threshold, state: "failed")
      create_purchases(threshold, state: "failed", account: completed_account)
      create_purchases(1, state: "successful", account: completed_account)
      create_purchases(threshold - 1, state: "failed", account: below_threshold_account)
      create_purchases(threshold, state: "failed", account: other_account)

      expect { described_class.new.perform }.to change { Comment.count }.by(2)

      expect(notes_for(seller).count).to eq(1)
      expect(notes_for(other_account.user).count).to eq(1)
      expect(notes_for(completed_account.user).count).to eq(0)
      expect(notes_for(below_threshold_account.user).count).to eq(0)
    end

    it "loads connected accounts in bounded batches" do
      stub_const("#{described_class}::BATCH_SIZE", 2)
      4.times { create(:merchant_account_paypal, user: create(:user)) }
      batch_sizes = []
      allow_any_instance_of(described_class).to receive(:note_failing_accounts) { |_job, accounts, _window| batch_sizes << accounts.size }

      described_class.new.perform

      expect(batch_sizes).to eq([2, 2, 1])
    end

    it "notes the remaining accounts when one account's note operation raises" do
      other_account = create(:merchant_account_paypal, user: create(:user))
      create_purchases(threshold, state: "failed")
      create_purchases(threshold, state: "failed", account: other_account)
      allow(ErrorNotifier).to receive(:notify)
      allow_any_instance_of(User).to receive(:with_lock) do |user, &block|
        raise ActiveRecord::LockWaitTimeout, "boom" if user.id == seller.id

        user.transaction(&block)
      end

      expect { described_class.new.perform }.not_to raise_error

      expect(notes_for(seller).count).to eq(0)
      expect(notes_for(other_account.user).count).to eq(1)
      expect(ErrorNotifier).to have_received(:notify).with(
        instance_of(ActiveRecord::LockWaitTimeout),
        context: { merchant_account_id: merchant_account.id, user_id: seller.id }
      ).once
    end

    it "does not add a duplicate note on a repeat run" do
      create_purchases(threshold, state: "failed")

      described_class.new.perform
      create_purchases(3, state: "failed")

      expect { described_class.new.perform }.not_to change { notes_for(seller).count }
    end

    it "notes again once the dedup window has passed" do
      create_purchases(threshold, state: "failed")
      described_class.new.perform
      notes_for(seller).update_all(created_at: described_class::DEDUP_WINDOW.ago - 1.hour)

      expect { described_class.new.perform }.to change { notes_for(seller).count }.by(1)
    end

    it "does not change the seller's state or enqueue notifications" do
      create_purchases(threshold, state: "failed")

      expect { described_class.new.perform }.not_to change { seller.reload.attributes }
      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end
end
