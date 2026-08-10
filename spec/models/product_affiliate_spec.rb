# frozen_string_literal: true

require "spec_helper"

describe ProductAffiliate do
  describe "associations" do
    it { is_expected.to belong_to(:affiliate) }
    it { is_expected.to belong_to(:product).class_name("Link") }
  end

  describe "validations" do
    context "when another record exists" do
      it "validates uniqueness of affiliate scoped to product" do
        existing = create(:product_affiliate)
        product_affiliate = build(:product_affiliate, affiliate: existing.affiliate, product: existing.product)
        expect(product_affiliate).not_to be_valid
      end
    end

    context "for a collaborator" do
      let(:collaborator) { create(:collaborator, apply_to_all_products: false) }

      it "validates presence of `affiliate_basis_points` if `apply_to_all_products` is not set" do
        product_affiliate = build(:product_affiliate, affiliate: collaborator, affiliate_basis_points: nil)
        expect(product_affiliate).not_to be_valid

        collaborator.update!(apply_to_all_products: true)
        product_affiliate = build(:product_affiliate, affiliate: collaborator, affiliate_basis_points: nil)
        expect(product_affiliate).to be_valid
      end

      it "validates `affiliate_basis_points` is in the correct range if present" do
        product_affiliate = build(:product_affiliate, affiliate: collaborator, affiliate_basis_points: 51_00)
        expect(product_affiliate).not_to be_valid

        product_affiliate.affiliate_basis_points = 50_00
        expect(product_affiliate).to be_valid

        product_affiliate.affiliate_basis_points = 0
        expect(product_affiliate).not_to be_valid
      end

      it "validates that the product has no other live collaborators" do
        product = create(:product)
        # ignores affiliates
        create(:product_affiliate, product:, affiliate: create(:user).global_affiliate)
        create(:direct_affiliate, products: [product])

        product_affiliate = create(:product_affiliate, affiliate: collaborator, product:)
        expect(product_affiliate).to be_valid

        new_collaborator = create(:collaborator)
        product_affiliate = build(:product_affiliate, affiliate: new_collaborator, product:)
        expect(product_affiliate).not_to be_valid
        collaborator.mark_deleted!
        expect(product_affiliate).to be_valid
      end
    end

    context "for a direct affiliate" do
      it "validates that the product is not a collab" do
        affiliate = create(:direct_affiliate)
        product = create(:product, :is_collab)
        product_affiliate = build(:product_affiliate, affiliate:, product:)
        expect(product_affiliate).not_to be_valid
        expect(product_affiliate.errors.full_messages).to eq ["Collab products cannot have affiliates"]
      end
    end
  end

  describe "lifecycle hooks" do
    describe "workflow scheduling" do
      let(:affiliate) { create(:direct_affiliate) }
      let(:product) { create(:product, user: affiliate.seller) }

      it "enqueues one scheduler for assignments created in one transaction" do
        second_product = create(:product, user: affiliate.seller)
        product_affiliates = []

        expect do
          ProductAffiliate.transaction do
            product_affiliates << create(:product_affiliate, affiliate:, product:)
            product_affiliates << create(:product_affiliate, affiliate:, product: second_product)
          end
        end.to change { ScheduleAffiliateWorkflowJobsJob.jobs.size }.by(1)

        product_affiliates.each(&:reload)
        workflow_schedule_token = product_affiliates.first.workflow_schedule_token
        expect(product_affiliates.map(&:workflow_schedule_token).uniq).to eq([workflow_schedule_token])
        expect(ScheduleAffiliateWorkflowJobsJob).to have_enqueued_sidekiq_job(workflow_schedule_token)
      end

      it "does not enqueue a rolled-back assignment group" do
        expect do
          ProductAffiliate.transaction(requires_new: true) do
            create(:product_affiliate, affiliate:, product:)
            raise ActiveRecord::Rollback
          end
        end.not_to change { ScheduleAffiliateWorkflowJobsJob.jobs.size }

        expect(ProductAffiliate.exists?(affiliate_id: affiliate.id, link_id: product.id)).to be(false)
      end

      it "keeps the assignment pending when Sidekiq returns no job id" do
        allow(ScheduleAffiliateWorkflowJobsJob).to receive(:perform_async).and_return(nil)
        expect(Rails.logger).to receive(:error).with(/Sidekiq did not enqueue/)

        product_affiliate = create(:product_affiliate, affiliate:, product:)

        expect(product_affiliate.reload.workflow_schedule_token).to be_present
      end

      it "keeps the assignment pending when Sidekiq raises an error" do
        allow(ScheduleAffiliateWorkflowJobsJob).to receive(:perform_async).and_raise("Redis is unavailable")
        expect(Rails.logger).to receive(:error).with(/Redis is unavailable/)

        product_affiliate = create(:product_affiliate, affiliate:, product:)

        expect(product_affiliate.reload.workflow_schedule_token).to be_present
      end

      it "does not enqueue assignments for other affiliate types" do
        global_affiliate = create(:user).global_affiliate
        collaborator = create(:collaborator, seller: product.user)

        expect do
          create(:product_affiliate, affiliate: global_affiliate, product:)
          create(:product_affiliate, affiliate: collaborator, product:)
        end.not_to change { ScheduleAffiliateWorkflowJobsJob.jobs.size }
      end
    end

    describe "toggling product is_collab flag" do
      context "for a collaborator" do
        let!(:affiliate) { create(:collaborator) }

        it "enables the is_collab flag when a product affiiate is created, and disables any self service affiliate products and direct affiliates" do
          product = create(:product, is_collab: false)
          self_service_affiliate_product = create(:self_service_affiliate_product, seller: product.user, product: product, enabled: true)
          direct_affiliate = create(:direct_affiliate, seller: product.user, products: [product])

          expect do
            create(:product_affiliate, affiliate:, product:)
          end.to change { product.reload.is_collab }.from(false).to(true)
             .and change { self_service_affiliate_product.reload.enabled }.from(true).to(false)
             .and change { direct_affiliate.product_affiliates.count }.from(1).to(0)
        end

        it "disables the is_collab flag when a product affiliate is deleted" do
          product = create(:product, is_collab: true)
          product_affiliate = create(:product_affiliate, affiliate:, product:)

          expect do
            product_affiliate.destroy
          end.to change { product.reload.is_collab }.from(true).to(false)
        end
      end

      context "for another type of affiliate" do
        let!(:affiliate) { create(:direct_affiliate) }

        it "does not change the is_collab flag when a product affiiate is created" do
          product = create(:product, is_collab: false)

          expect do
            create(:product_affiliate, affiliate:, product:)
          end.not_to change { product.reload.is_collab }
        end

        it "does not change the is_collab flag when a product affiliate is deleted" do
          product = create(:product, is_collab: true)
          product_affiliate = build(:product_affiliate, affiliate:, product:)
          product_affiliate.save(validate: false) # bypass `product_is_not_a_collab` validation

          expect do
            product_affiliate.destroy
          end.not_to change { product.reload.is_collab }
        end
      end
    end
  end

  describe "#affiliate_percentage" do
    let(:product_affiliate) { create(:product_affiliate, affiliate_basis_points:) }

    context "when affiliate_basis_point is nil" do
      let(:affiliate_basis_points) { nil }

      it "returns nil" do
        expect(product_affiliate.affiliate_percentage).to be_nil
      end
    end

    context "when affiliate_basis_point is set" do
      let(:affiliate_basis_points) { 500 }

      it "returns the correct affiliate percentage value" do
        expect(product_affiliate.affiliate_percentage).to eq(5)
      end
    end
  end
end
