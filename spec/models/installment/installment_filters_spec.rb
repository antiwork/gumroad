# frozen_string_literal: true

require "spec_helper"
require "shared_examples/with_filtering_support"

describe "InstallmentFilters"  do
  before do
    @creator = create(:named_user, :with_avatar)
    @installment = create(:installment, call_to_action_text: "CTA", call_to_action_url: "https://www.example.com", seller: @creator)
  end

  describe "#add_and_validate_filters" do
    let(:user) { create(:user) }
    let!(:product) { create(:product, user:) }

    subject(:add_and_validate_filters) { filterable_object.add_and_validate_filters(params, user) }

    it_behaves_like "common customer recipient filter validation behavior", audience_type: "product" do
      let(:filterable_object) { create(:product_installment, seller: user, link: product) }
    end

    it_behaves_like "common customer recipient filter validation behavior", audience_type: "variant" do
      let(:filterable_object) { create(:variant_installment, seller: user, link: product) }
    end

    it_behaves_like "common customer recipient filter validation behavior", audience_type: "seller" do
      let(:filterable_object) { create(:seller_installment, seller: user, link: product) }
    end

    it_behaves_like "common non-customer recipient filter validation behavior", audience_type: "audience" do
      let(:filterable_object) { create(:audience_installment, seller: user, link: product) }
    end

    it_behaves_like "common non-customer recipient filter validation behavior", audience_type: "follower" do
      let(:filterable_object) { create(:follower_installment, seller: user, link: product) }
    end

    it_behaves_like "common non-customer recipient filter validation behavior", audience_type: "affiliate" do
      let(:filterable_object) { create(:affiliate_installment, seller: user, link: product) }
    end
  end

  describe "#audience_members_filter_params with a 'has not clicked' filter" do
    let(:product) { create(:product, user: @creator) }
    let(:clicked_post) { create(:audience_installment, seller: @creator, link: product) }
    let(:post_being_sent) { create(:audience_installment, seller: @creator, link: product) }
    let(:clicker_purchase) { create(:free_purchase, link: product, seller: @creator, email: "Clicker@Example.com") }

    it "excludes the buyers who clicked the chosen post, downcased" do
      post_being_sent.update!(not_clicked_post_id: clicked_post.external_id)
      allow(EmailEngagementDynamoStore).to receive(:clicked_recipient_purchase_ids)
        .with(clicked_post.id).and_return([clicker_purchase.id])

      expect(post_being_sent.audience_members_filter_params[:exclude_emails]).to eq(["clicker@example.com"])
    end

    it "reads no click data when the filter is not set" do
      expect(EmailEngagementDynamoStore).not_to receive(:clicked_recipient_purchase_ids)

      expect(post_being_sent.audience_members_filter_params[:exclude_emails]).to be_nil
    end

    it "excludes nobody when the chosen post belongs to another seller" do
      other_sellers_post = create(:audience_installment)
      post_being_sent.update!(not_clicked_post_id: other_sellers_post.external_id)
      expect(EmailEngagementDynamoStore).not_to receive(:clicked_recipient_purchase_ids)

      expect(post_being_sent.audience_members_filter_params[:exclude_emails]).to be_nil
    end

    it "excludes nobody when the chosen post has no clicks yet" do
      post_being_sent.update!(not_clicked_post_id: clicked_post.external_id)
      allow(EmailEngagementDynamoStore).to receive(:clicked_recipient_purchase_ids).and_return([])

      expect(post_being_sent.audience_members_filter_params[:exclude_emails]).to be_nil
    end
  end
end

describe "#member_cancellation_trigger?" do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  it "is true when the installment carries the trigger itself" do
    workflow = create(:workflow, seller:, link: product, workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER)
    installment = create(:installment, link: product, workflow:)
    installment.workflow_trigger = Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER

    expect(installment.member_cancellation_trigger?).to eq(true)
  end

  it "is true from the workflow when the installment's own copy is stale" do
    workflow = create(:workflow, seller:, link: product, workflow_trigger: Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER)
    installment = create(:installment, link: product, workflow:)

    expect(installment.workflow_trigger).to be_nil
    expect(installment.member_cancellation_trigger?).to eq(true)
  end

  it "is false for a new-customer workflow post" do
    workflow = create(:workflow, seller:, link: product)

    expect(create(:installment, link: product, workflow:).member_cancellation_trigger?).to eq(false)
  end

  it "is false for a post with no workflow" do
    expect(create(:installment).member_cancellation_trigger?).to eq(false)
  end
end
