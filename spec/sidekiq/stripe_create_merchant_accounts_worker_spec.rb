# frozen_string_literal: true

require "spec_helper"

describe StripeCreateMerchantAccountsWorker, :vcr do
  describe "perform" do
    describe "don't queue users who have merchant accounts already" do
      let(:user_1) { create(:user, user_risk_state: "compliant") }
      let(:user_compliance_info_1) { create(:user_compliance_info, user: user_1) }
      let(:tos_agreement_1) { create(:tos_agreement, user: user_1) }
      let(:bank_account_1) { create(:ach_account, user: user_1) }
      let(:balance_1) { create(:balance, created_at: 10.days.ago, user: user_1) }

      let(:user_2) { create(:user, user_risk_state: "compliant") }
      let(:user_compliance_info_2) { create(:user_compliance_info, user: user_2) }
      let(:tos_agreement_2) { create(:tos_agreement, user: user_2) }
      let(:bank_account_2) { create(:ach_account_stripe_succeed, user: user_2) }
      let(:balance_2) { create(:balance, created_at: 10.days.ago, user: user_2) }

      before do
        user_1
        user_compliance_info_1
        tos_agreement_1
        bank_account_1
        balance_1
        user_2
        user_compliance_info_2
        tos_agreement_2
        bank_account_2
        balance_2
        StripeMerchantAccountManager.create_account(user_2, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
      end

      it "only queues the users that don't have merchant accounts" do
        described_class.new.perform

        expect(CreateStripeMerchantAccountWorker).to have_enqueued_sidekiq_job(user_1.id)
        expect(CreateStripeMerchantAccountWorker).not_to have_enqueued_sidekiq_job(user_2.id)
      end

      describe "even if the merchant account has been marked as deleted" do
        before do
          user_2.reload.merchant_accounts.last.mark_deleted!
        end

        it "only queues the users that have never had a merchant account" do
          described_class.new.perform

          expect(CreateStripeMerchantAccountWorker).to have_enqueued_sidekiq_job(user_1.id)
          expect(CreateStripeMerchantAccountWorker).not_to have_enqueued_sidekiq_job(user_2.id)
        end
      end
    end

    describe "don't queue users outside of our support stripe connect countries" do
      let(:user_1) { create(:user, user_risk_state: "compliant") }
      let(:user_compliance_info_1) { create(:user_compliance_info, user: user_1) }
      let(:tos_agreement_1) { create(:tos_agreement, user: user_1) }
      let(:bank_account_1) { create(:ach_account, user: user_1) }
      let(:balance_1) { create(:balance, created_at: 10.days.ago, user: user_1) }

      let(:user_2) { create(:user, user_risk_state: "compliant") }
      let(:user_compliance_info_2) { create(:user_compliance_info, user: user_2, country: Compliance::Countries::CAN.common_name) }
      let(:tos_agreement_2) { create(:tos_agreement, user: user_2) }
      let(:bank_account_2) { create(:canadian_bank_account, user: user_2) }
      let(:balance_2) { create(:balance, created_at: 10.days.ago, user: user_2) }

      let(:user_3) { create(:user, user_risk_state: "compliant") }
      let(:user_compliance_info_3) { create(:user_compliance_info, user: user_3, country: Compliance::Countries::VEN.common_name) }
      let(:tos_agreement_3) { create(:tos_agreement, user: user_3) }
      let(:bank_account_3) { create(:canadian_bank_account, user: user_3) }
      let(:balance_3) { create(:balance, created_at: 10.days.ago, user: user_3) }

      before do
        user_1
        user_compliance_info_1
        tos_agreement_1
        bank_account_1
        balance_1
        user_2
        user_compliance_info_2
        tos_agreement_2
        bank_account_2
        balance_2
        user_3
        user_compliance_info_3
        tos_agreement_3
        bank_account_3
        balance_3
      end

      it "only queues the users in the US and Canada" do
        described_class.new.perform

        expect(CreateStripeMerchantAccountWorker).to have_enqueued_sidekiq_job(user_1.id)
        expect(CreateStripeMerchantAccountWorker).to have_enqueued_sidekiq_job(user_2.id)
        expect(CreateStripeMerchantAccountWorker).not_to have_enqueued_sidekiq_job(user_3.id)
      end
    end

    describe "queue users who have a bank account" do
      let(:user_1) { create(:user, user_risk_state: "compliant") }
      let(:user_compliance_info_1) { create(:user_compliance_info, user: user_1) }
      let(:tos_agreement_1) { create(:tos_agreement, user: user_1) }
      let(:bank_account_1) { create(:ach_account, user: user_1) }
      let(:balance_1) { create(:balance, created_at: 10.days.ago, user: user_1) }

      let(:user_2) { create(:user, user_risk_state: "compliant") }
      let(:user_compliance_info_2) { create(:user_compliance_info, user: user_2) }
      let(:tos_agreement_2) { create(:tos_agreement, user: user_2) }
      let(:balance_2) { create(:balance, created_at: 10.days.ago, user: user_2) }

      before do
        user_1
        user_compliance_info_1
        tos_agreement_1
        bank_account_1
        balance_1
        user_2
        user_compliance_info_2
        tos_agreement_2
        balance_2
      end

      it "only queues the users with bank accounts" do
        described_class.new.perform

        expect(CreateStripeMerchantAccountWorker).to have_enqueued_sidekiq_job(user_1.id)
        expect(CreateStripeMerchantAccountWorker).not_to have_enqueued_sidekiq_job(user_2.id)
      end
    end

    describe "queue users who have agreed to the tos agreement" do
      let(:user_1) { create(:user, user_risk_state: "compliant") }
      let(:user_compliance_info_1) { create(:user_compliance_info, user: user_1) }
      let(:tos_agreement_1) { create(:tos_agreement, user: user_1) }
      let(:bank_account_1) { create(:ach_account, user: user_1) }
      let(:balance_1) { create(:balance, created_at: 10.days.ago, user: user_1) }

      let(:user_2) { create(:user, user_risk_state: "compliant") }
      let(:user_compliance_info_2) { create(:user_compliance_info, user: user_2) }
      let(:bank_account_2) { create(:ach_account, user: user_2) }
      let(:balance_2) { create(:balance, created_at: 10.days.ago, user: user_2) }

      before do
        user_1
        user_compliance_info_1
        tos_agreement_1
        bank_account_1
        balance_1
        user_2
        user_compliance_info_2
        bank_account_2
        balance_2
      end

      it "only queues the users who have agreed to tos" do
        described_class.new.perform

        expect(CreateStripeMerchantAccountWorker).to have_enqueued_sidekiq_job(user_1.id)
        expect(CreateStripeMerchantAccountWorker).not_to have_enqueued_sidekiq_job(user_2.id)
      end
    end

    describe "queue users who have received a balance in the last 3 months" do
      let(:user_1) { create(:user, user_risk_state: "compliant") }
      let(:user_compliance_info_1) { create(:user_compliance_info, user: user_1) }
      let(:tos_agreement_1) { create(:tos_agreement, user: user_1) }
      let(:bank_account_1) { create(:ach_account, user: user_1) }
      let(:balance_1) { create(:balance, created_at: 10.days.ago, user: user_1) }

      let(:user_2) { create(:user, user_risk_state: "compliant") }
      let(:user_compliance_info_2) { create(:user_compliance_info, user: user_2) }
      let(:tos_agreement_2) { create(:tos_agreement, user: user_2) }
      let(:bank_account_2) { create(:ach_account, user: user_2) }
      let(:balance_2) { create(:balance, created_at: 4.months.ago, user: user_2) }

      before do
        user_1
        user_compliance_info_1
        tos_agreement_1
        bank_account_1
        balance_1
        user_2
        user_compliance_info_2
        tos_agreement_2
        bank_account_2
        balance_2
      end

      it "only queues the users in the US" do
        described_class.new.perform

        expect(CreateStripeMerchantAccountWorker).to have_enqueued_sidekiq_job(user_1.id)
        expect(CreateStripeMerchantAccountWorker).not_to have_enqueued_sidekiq_job(user_2.id)
      end
    end

    describe "queue users who are compliant and not reviewed, and not other users" do
      let(:user_1) { create(:user, user_risk_state: "compliant") }
      let(:user_compliance_info_1) { create(:user_compliance_info, user: user_1) }
      let(:tos_agreement_1) { create(:tos_agreement, user: user_1) }
      let(:bank_account_1) { create(:ach_account, user: user_1) }
      let(:balance_1) { create(:balance, created_at: 10.days.ago, user: user_1) }

      let(:user_2) { create(:user, user_risk_state: "suspended_for_fraud") }
      let(:user_compliance_info_2) { create(:user_compliance_info, user: user_2) }
      let(:tos_agreement_2) { create(:tos_agreement, user: user_2) }
      let(:bank_account_2) { create(:ach_account, user: user_2) }
      let(:balance_2) { create(:balance, created_at: 10.days.ago, user: user_2) }

      let(:user_3) { create(:user, user_risk_state: "compliant") }
      let(:user_compliance_info_3) { create(:user_compliance_info, user: user_3) }
      let(:tos_agreement_3) { create(:tos_agreement, user: user_3) }
      let(:bank_account_3) { create(:ach_account, user: user_3) }
      let(:balance_3) { create(:balance, created_at: 10.days.ago, user: user_3) }

      before do
        user_1
        user_compliance_info_1
        tos_agreement_1
        bank_account_1
        balance_1
        user_2
        user_compliance_info_2
        tos_agreement_2
        bank_account_2
        balance_2
        user_3
        user_compliance_info_3
        tos_agreement_3
        bank_account_3
        balance_3
      end

      it "only queues the users in the US" do
        described_class.new.perform

        expect(CreateStripeMerchantAccountWorker).to have_enqueued_sidekiq_job(user_1.id)
        expect(CreateStripeMerchantAccountWorker).not_to have_enqueued_sidekiq_job(user_2.id)
        expect(CreateStripeMerchantAccountWorker).to have_enqueued_sidekiq_job(user_3.id)
      end
    end
  end
end
