# frozen_string_literal: true

require "spec_helper"

describe AffiliateRequest do
  describe "validations" do
    subject(:affiliate_request) { build(:affiliate_request) }

    it "validates without any error" do
      expect(affiliate_request).to be_valid
    end

    describe "presence" do
      subject(:affiliate_request) { described_class.new }

      it "validates presence of attributes" do
        expect(affiliate_request).to be_invalid
        expect(affiliate_request.errors.messages).to eq(
          seller: ["can't be blank"],
          name: ["can't be blank"],
          email: ["can't be blank", "is invalid"],
          promotion_text: ["can't be blank"]
        )
      end
    end

    describe "name length" do
      it "validates length of name" do
        affiliate_request.name = Faker::String.random(length: 101)

        expect(affiliate_request).to be_invalid
        expect(affiliate_request.errors.messages).to eq(
          name: ["Your name is too long. Please try again with a shorter one."],
        )
      end
    end

    describe "email format" do
      it "validates email format" do
        affiliate_request.email = "invalid-email"

        expect(affiliate_request).to be_invalid
        expect(affiliate_request.errors.full_messages.first).to eq("Email is invalid")
      end
    end

    describe "duplicate_request_validation" do
      let(:existing_affiliate_request) { create(:affiliate_request, email: "requester@example.com") }
      let(:duplicate_affiliate_request) { build(:affiliate_request, seller: existing_affiliate_request.seller, email: "requester@example.com") }

      context "when requester's previous request is unattended" do
        it "doesn't allow new request from the same requester" do
          expect(duplicate_affiliate_request).to be_invalid
          expect(duplicate_affiliate_request.errors.full_messages.first).to eq("You have already requested to become an affiliate of this creator.")
        end
      end

      context "when requester's previous request is approved" do
        let(:existing_affiliate_request) { create(:affiliate_request, email: "requester@example.com", state: :approved) }

        it "doesn't allow new request from the same requester" do
          expect(duplicate_affiliate_request).to be_invalid
          expect(duplicate_affiliate_request.errors.full_messages.first).to eq("You have already requested to become an affiliate of this creator.")
        end
      end

      context "when requester's previous request is ignored" do
        let(:existing_affiliate_request) { create(:affiliate_request, email: "requester@example.com", state: :ignored) }

        it "allows new request from the same requester" do
          expect(duplicate_affiliate_request).to be_valid
        end
      end
    end

    describe "requester_is_not_seller" do
      let(:creator) { create(:user) }
      subject(:affiliate_request) { build(:affiliate_request, seller: creator, email: creator.email) }

      it "doesn't allow the creator to become an affiliate of oneself" do
        expect(affiliate_request).to be_invalid
        expect(affiliate_request.errors.full_messages.first).to eq("You cannot request to become an affiliate of yourself.")
      end
    end
  end

  describe "scopes" do
    describe "unattended_or_approved_but_awaiting_requester_to_sign_up" do
      let!(:unattended_request_one) { create(:affiliate_request) }
      let!(:unattended_request_two) { create(:affiliate_request) }
      let!(:ignored_request) { create(:affiliate_request, state: "ignored") }
      let!(:approved_request_of_signed_up_requester) { create(:affiliate_request, state: "approved", email: create(:user).email) }
      let!(:approved_request_of_not_signed_up_requester) { create(:affiliate_request, state: "approved") }

      it "returns both unattended requests and approved requests whose requester hasn't signed up yet" do
        result = described_class.unattended_or_approved_but_awaiting_requester_to_sign_up
        expect(result.size).to eq(3)
        expect(result).to match_array([unattended_request_one, unattended_request_two, approved_request_of_not_signed_up_requester])
      end
    end
  end

  describe "#as_json" do
    it "returns JSON representation" do
      seller = create(:user, timezone: "Mumbai")

      travel_to DateTime.new(2021, 01, 15).in_time_zone(seller.timezone) do
        affiliate_request = create(:affiliate_request, seller:)

        expect(affiliate_request.as_json).to eq(
          id: affiliate_request.external_id,
          name: affiliate_request.name,
          email: affiliate_request.email,
          promotion: affiliate_request.promotion_text,
          date: "2021-01-15T05:30:00+05:30",
          state: "created",
          can_update: false
        )
      end
    end
  end

  describe "#to_param" do
    subject(:affiliate_request) { create(:affiliate_request) }

    it "uses 'external_id' instead of 'id' for constructing URLs to the objects of this model" do
      expect(affiliate_request.to_param).to eq(affiliate_request.external_id)
    end
  end

  describe "#can_perform_action?" do
    let(:affiliate_request) { create(:affiliate_request) }

    context "when action is 'approve'" do
      let(:action) { AffiliateRequest::ACTION_APPROVE }

      context "when request is already attended" do
        before do
          affiliate_request.approve!
        end

        it "returns false" do
          expect(affiliate_request.can_perform_action?(action)).to eq(false)
        end
      end

      context "when request is not attended" do
        it "returns true" do
          expect(affiliate_request.can_perform_action?(action)).to eq(true)
        end
      end
    end

    context "when action is 'ignore'" do
      let(:action) { AffiliateRequest::ACTION_IGNORE }

      context "when request is already approved" do
        before do
          affiliate_request.approve!
        end

        it "returns true when the affiliate doesn't have an account" do
          expect(affiliate_request.can_perform_action?(action)).to eq(true)
        end

        it "returns false when the affiliate has an account" do
          create(:user, email: affiliate_request.email)

          expect(affiliate_request.can_perform_action?(action)).to eq(false)
        end
      end

      context "when request is already ignored" do
        before do
          affiliate_request.ignore!
        end

        it "returns false" do
          expect(affiliate_request.can_perform_action?(action)).to eq(false)
        end
      end

      context "when request is not attended" do
        it "returns true" do
          expect(affiliate_request.can_perform_action?(action)).to eq(true)
        end
      end
    end
  end

  describe "#approve!" do
    subject(:affiliate_request) { create(:affiliate_request) }

    it "marks the request as approved and makes the requester an affiliate" do
      expect(affiliate_request).to receive(:make_requester_an_affiliate!)

      expect do
        affiliate_request.approve!
      end.to change { affiliate_request.reload.approved? }.from(false).to(true)
    end

    it "schedules workflow posts for the newly approved affiliate" do
      creator = create(:user)
      affiliate_user = create(:user)
      published_product_one = create(:product, user: creator)
      create(:self_service_affiliate_product, enabled: true, seller: creator, product: published_product_one, affiliate_basis_points: 1000)
      affiliate_request = create(:affiliate_request, seller: creator, email: affiliate_user.email)

      affiliate_workflow = create(:workflow, seller: creator, link: nil, workflow_type: Workflow::AFFILIATE_TYPE, published_at: 1.week.ago)
      installment1 = create(:installment, workflow: affiliate_workflow)
      create(:installment_rule, installment: installment1, delayed_delivery_time: 3.days)
      installment2 = create(:installment, workflow: affiliate_workflow)
      create(:installment_rule, installment: installment2, delayed_delivery_time: 10.days)

      expect_any_instance_of(DirectAffiliate).to receive(:schedule_workflow_jobs).and_call_original
      expect do
        expect do
          affiliate_request.approve!
        end.to change { affiliate_request.reload.approved? }.from(false).to(true)
      end.to change { DirectAffiliate.count }.by(1)
      expect(SendWorkflowInstallmentWorker.jobs.size).to eq(2)
    end
  end

  describe "#ignore!" do
    let(:affiliate_request) { create(:affiliate_request) }

    context "when request is already ignored" do
      before do
        affiliate_request.ignore!
      end

      it "does not allow to ignore again" do
        expect do
          affiliate_request.ignore!
        end.to raise_error(StateMachines::InvalidTransition)
      end
    end

    context "when request is already approved" do
      before do
        affiliate_request.approve!
      end

      it "ignores the request when the affiliate doesn't have an account" do
        expect do
          affiliate_request.ignore!
        end.to change { affiliate_request.reload.ignored? }.from(false).to(true)
      end

      it "notifies the requester of the ignored request" do
        expect do
          affiliate_request.ignore!
        end.to have_enqueued_mail(AffiliateRequestMailer, :notify_requester_of_ignored_request).with(affiliate_request.id)
      end

      it "does not allow to ignore the request when the affiliate has an account" do
        create(:user, email: affiliate_request.email)

        expect do
          affiliate_request.ignore!
        end.to raise_error(StateMachines::InvalidTransition)
      end
    end

    context "when request is not attended yet" do
      it "marks the request as ignored" do
        expect do
          affiliate_request.ignore!
        end.to change { affiliate_request.reload.ignored? }.from(false).to(true)
      end

      it "notifies the requester of the ignored request" do
        expect do
          affiliate_request.ignore!
        end.to have_enqueued_mail(AffiliateRequestMailer, :notify_requester_of_ignored_request).with(affiliate_request.id)
      end
    end
  end

  describe "#make_requester_an_affiliate!" do
    let(:creator) { create(:named_user) }
    let(:requester_email) { "requester@example.com" }
    let(:affiliate_request) { create(:affiliate_request, email: requester_email, seller: creator, state: :approved) }
    let(:published_product_one) { create(:product, user: creator) }
    let(:published_product_two) { create(:product, user: creator) }
    let!(:published_product_three) { create(:product, user: creator) }
    let(:published_product_four) { create(:product, user: creator) }
    let(:deleted_product) { create(:product, user: creator, deleted_at: 1.day.ago) }
    let!(:enabled_self_service_affiliate_product_for_published_product_one) { create(:self_service_affiliate_product, enabled: true, seller: creator, product: published_product_one) }
    let!(:enabled_self_service_affiliate_product_for_published_product_two) { create(:self_service_affiliate_product, enabled: true, seller: creator, product: published_product_two, destination_url: "https://example.com") }
    let!(:enabled_self_service_affiliate_product_for_published_product_four) { create(:self_service_affiliate_product, enabled: true, seller: creator, product: published_product_four, affiliate_basis_points: 1000) }
    let!(:enabled_self_service_affiliate_product_for_deleted_product) { create(:self_service_affiliate_product, enabled: true, seller: creator, product: deleted_product) }

    context "when requester doesn't have an account" do
      it "sends request approval email to the requester but does not make them an affiliate" do
        expect do
          expect do
            expect do
              affiliate_request.make_requester_an_affiliate!
            end.to_not change { creator.direct_affiliates.count }
          end.to_not have_enqueued_mail(AffiliateRequestMailer, :notify_requester_of_request_approval)
        end.to have_enqueued_mail(AffiliateRequestMailer, :notify_unregistered_requester_of_request_approval)
      end
    end

    context "when requester is already an affiliate of some of the self-service affiliate products" do
      let(:requester) { create(:user, email: requester_email) }
      let(:affiliate) { create(:direct_affiliate, seller: creator, affiliate_user: requester, affiliate_basis_points: 45_00) }

      it "makes the requester an affiliate of all the enabled products with the configured commission fee" do
        create(:product_affiliate, affiliate:, product: published_product_four, affiliate_basis_points: 10_00)
        expect do
          expect do
            affiliate_request.make_requester_an_affiliate!
          end.to change { creator.direct_affiliates.count }.by(0)
             .and change { affiliate.reload.product_affiliates.count }.from(1).to(3)
             .and have_enqueued_mail(AffiliateRequestMailer, :notify_requester_of_request_approval).with(affiliate_request.id)
        end.to_not have_enqueued_mail(AffiliateMailer, :direct_affiliate_invitation)

        expect(affiliate.reload.send_posts).to eq(true)
        expect(affiliate.affiliate_basis_points).to eq(45_00)
        expect(affiliate.product_affiliates.count).to eq(3)
        affiliate_product_1 = affiliate.reload.product_affiliates.find_by(link_id: published_product_one.id)
        expect(affiliate_product_1.affiliate_basis_points).to eq(5_00)
        expect(affiliate_product_1.destination_url).to be_nil
        affiliate_product_2 = affiliate.reload.product_affiliates.find_by(link_id: published_product_two.id)
        expect(affiliate_product_2.affiliate_basis_points).to eq(5_00)
        expect(affiliate_product_2.destination_url).to eq("https://example.com")
        affiliate_product_3 = affiliate.reload.product_affiliates.find_by(link_id: published_product_four.id)
        expect(affiliate_product_3.affiliate_basis_points).to eq(10_00)
        expect(affiliate_product_3.destination_url).to be_nil
      end
    end

    context "when requester is already an affiliate of all of the self-service affiliate products" do
      let(:requester) { create(:user, email: requester_email) }

      before do
        affiliate = create(:direct_affiliate, seller: creator, affiliate_user: requester)
        create(:product_affiliate, affiliate:, product: published_product_one)
        create(:product_affiliate, affiliate:, product: published_product_two)
        create(:product_affiliate, affiliate:, product: published_product_three)
        create(:product_affiliate, affiliate:, product: published_product_four)
      end

      it "does nothing" do
        expect do
          expect do
            expect do
              expect do
                affiliate_request.make_requester_an_affiliate!
              end.to_not change { creator.direct_affiliates.count }
            end.to_not change { requester.directly_affiliated_products.count }
          end.to_not have_enqueued_mail(AffiliateRequestMailer, :notify_requester_of_request_approval)
        end.to_not have_enqueued_mail(AffiliateMailer, :direct_affiliate_invitation)
      end
    end
  end

  describe "after_commit callbacks" do
    it "sends emails to both requester and seller about the submitted affiliate request" do
      expect do
        create(:affiliate_request)
      end.to have_enqueued_mail(AffiliateRequestMailer, :notify_requester_of_request_submission)
       .and have_enqueued_mail(AffiliateRequestMailer, :notify_seller_of_new_request)
    end
  end
end
