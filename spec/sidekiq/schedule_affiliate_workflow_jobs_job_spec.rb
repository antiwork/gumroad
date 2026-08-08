# frozen_string_literal: true

describe ScheduleAffiliateWorkflowJobsJob do
  let(:affiliate) { create(:direct_affiliate, send_posts: true) }
  let(:product) { create(:product, user: affiliate.seller) }
  let(:product_affiliate) { create(:product_affiliate, affiliate:, product:) }

  it "schedules workflows after the affiliate relationship commits" do
    product_affiliate
    expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).at_least(:once).and_call_original
    expect_any_instance_of(DirectAffiliate).to receive(:schedule_workflow_jobs).with(triggering_product_affiliates: [product_affiliate])

    described_class.new.perform(affiliate.id, product_affiliate.id)
  end

  it "retries while the product relationship is not visible" do
    expect do
      described_class.new.perform(affiliate.id, -1)
    end.to raise_error(described_class::AffiliateNotCommittedError)
  end

  it "does not schedule after the affiliate opts out" do
    product_affiliate
    affiliate.update_posts_subscription(send_posts: false)
    expect_any_instance_of(DirectAffiliate).not_to receive(:schedule_workflow_jobs)

    described_class.new.perform(affiliate.id, product_affiliate.id)
  end
end
