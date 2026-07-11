# frozen_string_literal: true

require "spec_helper"

describe User::CreateBrandAccountService do
  let(:creator) { create(:user, username: "personalbrand") }

  def build_service(email: "brand@example.com", username: "mybrand", name: "My Brand")
    described_class.new(creator:, email:, username:, name:, account_created_ip: "1.2.3.4")
  end

  describe "#perform" do
    it "creates a new user with the given brand details" do
      service = build_service

      expect do
        expect(service.perform).to eq(true)
      end.to change(User, :count).by(1)

      brand_user = service.brand_user
      expect(brand_user.email).to eq("brand@example.com")
      expect(brand_user.username).to eq("mybrand")
      expect(brand_user.name).to eq("My Brand")
      expect(brand_user.account_created_ip).to eq("1.2.3.4")
      expect(brand_user.confirmed?).to eq(false)
    end

    it "records a TOS agreement for the new account" do
      service = build_service

      expect(service.perform).to eq(true)
      expect(service.brand_user.tos_agreements.count).to eq(1)
      expect(service.brand_user.tos_agreements.first.ip).to eq("1.2.3.4")
    end

    it "sends the confirmation email to the new account's email" do
      service = build_service

      expect do
        service.perform
      end.to have_enqueued_mail(UserSignupMailer, :confirmation_instructions)
    end

    it "makes the creator an admin of the brand account and creates their owner membership" do
      service = build_service

      expect(service.perform).to eq(true)

      expect(creator.user_memberships.not_deleted.find { _1.role_owner? }).to be_present

      membership = service.team_membership
      expect(membership.user).to eq(creator)
      expect(membership.seller).to eq(service.brand_user)
      expect(membership.role).to eq(TeamMembership::ROLE_ADMIN)
    end

    it "does not duplicate the creator's owner membership when it already exists" do
      creator.create_owner_membership_if_needed!

      service = build_service

      expect do
        expect(service.perform).to eq(true)
      end.to change { creator.user_memberships.role_owner.count }.by(0)
    end

    context "when the email is already taken" do
      it "returns false with a validation message and creates nothing" do
        create(:user, email: "brand@example.com")

        service = build_service

        expect do
          expect(service.perform).to eq(false)
        end.to not_change(User, :count).and not_change(TeamMembership, :count)

        expect(service.error_message).to be_present
      end
    end

    context "when the username is already taken" do
      it "returns false with a validation message" do
        create(:user, username: "mybrand")

        service = build_service

        expect(service.perform).to eq(false)
        expect(service.error_message).to match(/Username/i)
      end
    end

    context "when a concurrent request hits the database's unique index" do
      it "returns false with a friendly message instead of raising" do
        service = build_service

        # Simulate the race where another request creates the same email or
        # username between our model-level validation and the INSERT — the
        # database's unique index then raises RecordNotUnique.
        allow_any_instance_of(User).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique)

        expect do
          expect(service.perform).to eq(false)
        end.to not_change(User, :count).and not_change(TeamMembership, :count)

        expect(service.error_message).to eq("An account with that email or username already exists.")
      end
    end

    context "when the email is the same as the creator's email" do
      it "returns false with a message explaining a different email is needed" do
        service = build_service(email: creator.email.upcase)

        expect do
          expect(service.perform).to eq(false)
        end.to not_change(User, :count).and not_change(TeamMembership, :count)

        expect(service.error_message).to eq("The new account needs its own email address, different from your current account.")
      end
    end

    context "when the username has an invalid format" do
      it "returns false with a validation message" do
        service = build_service(username: "My Brand!")

        expect(service.perform).to eq(false)
        expect(service.error_message).to be_present
      end
    end

    describe "porting the existing payout setup" do
      def build_service_with_port
        described_class.new(
          creator:,
          email: "brand@example.com",
          username: "mybrand",
          name: "My Brand",
          account_created_ip: "1.2.3.4",
          use_existing_payout_setup: true,
        )
      end

      it "copies the creator's payout currency and PayPal address" do
        creator.update!(currency_type: Currency::GBP, payment_address: "paypal@example.com")

        service = build_service_with_port

        expect(service.perform).to eq(true)
        expect(service.brand_user.currency_type).to eq(Currency::GBP)
        expect(service.brand_user.payment_address).to eq("paypal@example.com")
      end

      it "copies the creator's compliance info without enqueueing the Stripe sync job" do
        create(:user_compliance_info, user: creator)

        service = build_service_with_port

        expect(service.perform).to eq(true)

        copy = service.brand_user.alive_user_compliance_info
        expect(copy).to be_present
        expect(copy.first_name).to eq("Chuck")
        expect(copy.last_name).to eq("Bartowski")
        expect(copy.country).to eq("United States")
        expect(HandleNewUserComplianceInfoWorker.jobs.map { _1["args"] }).not_to include([copy.id])
      end

      it "copies the creator's bank account with the Stripe identifiers cleared and enqueues Connect account creation" do
        create(:user_compliance_info, user: creator)
        create(:ach_account, user: creator, stripe_bank_account_id: "ba_123", stripe_fingerprint: "fp_123", stripe_connect_account_id: "acct_123")

        service = build_service_with_port

        expect(service.perform).to eq(true)

        copy = service.brand_user.active_bank_account
        expect(copy).to be_present
        expect(copy.account_number_last_four).to eq("1234")
        expect(copy.account_holder_full_name).to eq("Gumbot Gumstein I")
        expect(copy.stripe_bank_account_id).to be_nil
        expect(copy.stripe_fingerprint).to be_nil
        expect(copy.stripe_connect_account_id).to be_nil
        expect(copy.state).to eq("unverified")

        expect(CreateStripeMerchantAccountWorker.jobs.map { _1["args"] }).to include([service.brand_user.id])
      end

      it "does not copy a debit-card payout account", :vcr do
        create(:user_compliance_info, user: creator)
        create(:card_bank_account, user: creator)

        service = build_service_with_port

        expect(service.perform).to eq(true)
        expect(service.brand_user.active_bank_account).to be_nil
        expect(CreateStripeMerchantAccountWorker.jobs.map { _1["args"] }).not_to include([service.brand_user.id])
      end

      it "does not enqueue Connect account creation when there is no bank account to port" do
        create(:user_compliance_info, user: creator)

        service = build_service_with_port

        expect(service.perform).to eq(true)
        expect(CreateStripeMerchantAccountWorker.jobs.map { _1["args"] }).not_to include([service.brand_user.id])
      end

      it "copies nothing when the flag is off" do
        creator.update!(payment_address: "paypal@example.com")
        create(:user_compliance_info, user: creator)
        create(:ach_account, user: creator)

        service = build_service

        expect(service.perform).to eq(true)
        expect(service.brand_user.payment_address).to be_blank
        expect(service.brand_user.alive_user_compliance_info).to be_nil
        expect(service.brand_user.active_bank_account).to be_nil
      end

      it "creates nothing when the bank account copy fails" do
        create(:user_compliance_info, user: creator)
        create(:ach_account, user: creator)

        # Force the bank account copy to fail so the whole transaction — user,
        # membership, and compliance info copy — must roll back together.
        allow_any_instance_of(AchAccount).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(AchAccount.new))

        service = build_service_with_port

        expect do
          expect(service.perform).to eq(false)
        end.to not_change(User, :count).and not_change(TeamMembership, :count).and not_change(UserComplianceInfo, :count)
      end
    end
  end
end
