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
  end
end
