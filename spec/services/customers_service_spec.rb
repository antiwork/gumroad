# frozen_string_literal: true

require "spec_helper"
require "shared_examples/customer_drawer_missed_posts_context"

describe CustomersService do
  include_context "customer drawer missed posts setup"

  RSpec.shared_context "with seller eligible to send emails" do
    before do
      create(:payment_completed, user: seller)
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
      PostSendgridApi.mails.clear
    end
  end

  describe ".find_missed_posts_for" do
    it "returns missed posts" do
      expect(Installment).to receive(:missed_for_purchase).with(purchase, workflow_id: nil).and_call_original
      missed_posts = described_class.find_missed_posts_for(purchase:)
      expect(missed_posts).to eq([
                                   seller_post_to_all_customers,
                                   seller_workflow_post_to_all_customers,
                                   seller_post_with_bought_products_filter_product_a_and_c,
                                   regular_post_product_a,
                                   workflow_post_product_a
                                 ])

      expect(Installment).to receive(:missed_for_purchase).with(purchase, workflow_id: workflow_post_product_a.workflow.external_id).and_call_original
      described_class.find_missed_posts_for(purchase:, workflow_id: workflow_post_product_a.workflow.external_id)
    end
  end

  describe ".find_sent_posts_for" do
    context "for regular purchase" do
      let!(:regular_post_product_a_email) { create(:creator_contacting_customers_email_info, installment: regular_post_product_a, purchase:) }
      let!(:other_product_email) { create(:creator_contacting_customers_email_info, installment: regular_post_product_b, purchase:) }

      it "returns only sent posts for the purchase's product, excludes other product posts" do
        sent_posts = described_class.find_sent_posts_for(purchase)

        expect(sent_posts).to eq([regular_post_product_a_email])
        expect(sent_posts).not_to include(other_product_email)
      end

      it "returns only the latest email per installment when multiple emails exist" do
        latest_email_regular_post_product_a = create(:creator_contacting_customers_email_info, installment: regular_post_product_a, purchase:, sent_at: 1.day.ago)
        latest_email_workflow_post_product_a = create(:creator_contacting_customers_email_info, installment: workflow_post_product_a, purchase:, sent_at: 1.day.ago)

        sent_posts = described_class.find_sent_posts_for(purchase)

        expect(sent_posts).to eq([latest_email_regular_post_product_a, latest_email_workflow_post_product_a])
        expect(sent_posts).not_to include(regular_post_product_a_email)
      end
    end

    context "for bundle purchase" do
      include_context "with bundle purchase setup", with_posts: true

      let!(:bundle_email) { create(:creator_contacting_customers_email_info, installment: bundle_post, purchase: bundle_purchase) }
      let!(:product_a_email) { create(:creator_contacting_customers_email_info, installment: regular_post_product_a, purchase: bundle_purchase.product_purchases.find_by(link: product_a)) }
      let!(:product_b_email) { create(:creator_contacting_customers_email_info, installment: regular_post_product_b, purchase: bundle_purchase.product_purchases.find_by(link: product_b)) }

      it "returns only sent posts for bundle purchase" do
        result = described_class.find_sent_posts_for(bundle_purchase)

        expect(result).to eq([bundle_email])
        expect(result).not_to include(product_a_email, product_b_email)
      end

      it "returns only sent posts for bundle purchase product" do
        result = described_class.find_sent_posts_for(bundle_purchase.product_purchases.find_by(link: product_a))

        expect(result).to eq([product_a_email])
        expect(result).not_to include(bundle_email, product_b_email)
      end
    end
  end

  describe ".find_workflow_options_for" do
    let!(:_follower_workflow_post) { create(:follower_installment, workflow: create(:follower_workflow, seller:, published_at: 1.day.ago), seller:, published_at: Time.current) }
    let!(:_deleted_seller_workflow_post) { create(:seller_installment, workflow: create(:seller_workflow, seller:, deleted_at: DateTime.current), seller:, deleted_at: DateTime.current) }
    let!(:_audience_workflow_post) { create(:audience_installment, workflow: create(:audience_workflow, seller:, published_at: 1.day.ago), seller:, published_at: Time.current) }

    let!(:other_seller) { create(:named_seller, username: "othseller#{SecureRandom.alphanumeric(8).downcase}", email: "other_seller_#{SecureRandom.hex(4)}@example.com") }
    let!(:other_seller_installment) { create(:seller_installment, workflow: create(:seller_workflow, seller: other_seller, published_at: Time.current), seller: other_seller, published_at: Time.current) }

    before do
      workflow_post_product_a.workflow.update!(name: "Alpha Workflow")
      seller_workflow.update!(name: "Beta Workflow")
    end

    context "for regular purchase" do
      it "returns alive and published workflows sorted by name" do
        workflow_options = described_class.find_workflow_options_for(purchase)

        expect(workflow_options).to eq([workflow_post_product_a.workflow, seller_workflow])
      end
    end

    context "for bundle purchase" do
      include_context "with bundle purchase setup", with_posts: true

      before do
        bundle_workflow.update!(name: "Gamma Workflow")
        workflow_post_product_a_variant.workflow.update!(name: "Delta Workflow")
      end

      let!(:_workflow_installment_product_c) { create(:workflow_installment, workflow: create(:workflow, seller:, link: product_c, published_at: Time.current), seller:, link: product_c, published_at: Time.current,) }

      it "includes workflows for bundle" do
        workflow_options = described_class.find_workflow_options_for(bundle_purchase)

        expect(workflow_options).to eq([seller_workflow, bundle_workflow])
      end

      it "includes workflows for bundle purchase product" do
        workflow_options = described_class.find_workflow_options_for(bundle_purchase.product_purchases.find_by(link: product_a))

        expect(workflow_options).to eq([workflow_post_product_a.workflow, seller_workflow, workflow_post_product_a_variant.workflow])
      end
    end
  end

  describe ".send_post!" do
    include_context "with seller eligible to send emails"

    it "sends email and creates email record" do
      purchase.create_url_redirect!
      Rails.cache.delete("post_email:#{regular_post_product_a.id}:#{purchase.id}")

      expect(PostEmailApi).to receive(:process).with(
        post: regular_post_product_a,
        recipients: [{
          email: purchase.email,
          purchase:,
          url_redirect: purchase.url_redirect,
          subscription: purchase.subscription,
        }.compact_blank]
      ).and_call_original

      expect do
        result = described_class.send_post!(post: regular_post_product_a, purchase:)
        expect(result).to be true
      end.to change { CreatorContactingCustomersEmailInfo.count }.by(1)

      email_info = CreatorContactingCustomersEmailInfo.last
      expect(email_info.attributes).to include(
        "type" => "CreatorContactingCustomersEmailInfo",
        "installment_id" => regular_post_product_a.id,
        "purchase_id" => purchase.id,
        "state" => "sent",
        "email_name" => "purchase_installment"
      )
      expect(email_info.sent_at).to be_within(1.second).of(Time.current)

      expect(PostSendgridApi.mails.size).to eq(1)
      expect(PostSendgridApi.mails.keys).to include(purchase.email)
    end

    it "raises SellerNotEligibleError when seller is not eligible to send emails" do
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE - 1)

      expect do
        described_class.send_post!(post: regular_post_product_a, purchase:)
      end.to raise_error(CustomersService::SellerNotEligibleError, "You are not eligible to resend this email.")

      expect(PostSendgridApi.mails).to be_empty
      expect(CreatorContactingCustomersEmailInfo.where(purchase:, installment: regular_post_product_a)).to be_empty
    end

    it "raises CustomerDNDEnabledError when user can't be contacted for purchase" do
      purchase.update!(can_contact: false)

      expect do
        described_class.send_post!(post: regular_post_product_a, purchase:)
      end.to raise_error(CustomersService::CustomerDNDEnabledError, "Purchase #{purchase.id} has opted out of receiving emails")

      expect(PostSendgridApi.mails).to be_empty
      expect(CreatorContactingCustomersEmailInfo.where(purchase:, installment: regular_post_product_a)).to be_empty
    end

    it "includes subscription for membership purchases" do
      membership_purchase = create(:membership_purchase, link: create(:membership_product, user: seller))
      membership_purchase.create_url_redirect!
      Rails.cache.delete("post_email:#{regular_post_product_a.id}:#{membership_purchase.id}")

      expect(PostEmailApi).to receive(:process).with(
        post: regular_post_product_a,
        recipients: [{
          email: membership_purchase.email,
          purchase: membership_purchase,
          url_redirect: membership_purchase.url_redirect,
          subscription: membership_purchase.subscription,
        }.compact_blank]
      ).and_call_original

      expect do
        described_class.send_post!(post: regular_post_product_a, purchase: membership_purchase)
      end.to change { CreatorContactingCustomersEmailInfo.count }.by(1)

      email_info = CreatorContactingCustomersEmailInfo.last
      expect(email_info.purchase_id).to eq(membership_purchase.id)
      expect(PostSendgridApi.mails.size).to eq(1)
      expect(PostSendgridApi.mails.keys).to include(membership_purchase.email)
    end
  end

  describe ".send_missed_posts_for!" do
    include_context "with seller eligible to send emails"

    it "passes correct arguments to SendMissedPostsJob" do
      described_class.send_missed_posts_for!(purchase:)
      expect(SendMissedPostsJob).to have_enqueued_sidekiq_job(purchase.external_id, nil).on("default")

      described_class.send_missed_posts_for!(purchase:, workflow_id: workflow_post_product_a.workflow.external_id)
      expect(SendMissedPostsJob).to have_enqueued_sidekiq_job(purchase.external_id, workflow_post_product_a.workflow.external_id).on("default")
    end

    it "raises SellerNotEligibleError when seller is not eligible to send emails" do
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE - 1)

      expect do
        described_class.send_missed_posts_for!(purchase:)
      end.to raise_error(CustomersService::SellerNotEligibleError, "You are not eligible to resend this email.")

      expect(SendMissedPostsJob.jobs).to be_empty
    end

    it "raises CustomerDNDEnabledError when user can't be contacted for purchase" do
      purchase.update!(can_contact: false)

      expect do
        described_class.send_missed_posts_for!(purchase:)
      end.to raise_error(CustomersService::CustomerDNDEnabledError, "Purchase #{purchase.id} has opted out of receiving emails")

      expect(SendMissedPostsJob.jobs).to be_empty
    end
  end

  describe ".deliver_missed_posts_for!" do
    include_context "with seller eligible to send emails"

    before do
      create(:creator_contacting_customers_email_info, installment: regular_post_product_a, purchase:)
      purchase.create_url_redirect!
      [
        seller_post_to_all_customers,
        seller_workflow_post_to_all_customers,
        seller_post_with_bought_products_filter_product_a_and_c,
        workflow_post_product_a
      ].each do |p|
        Rails.cache.delete("post_email:#{p.id}:#{purchase.id}")
      end
    end

    it "sends emails for missed posts" do
      initial_count = CreatorContactingCustomersEmailInfo.count

      expect do
        described_class.deliver_missed_posts_for!(purchase:)
      end.to change { CreatorContactingCustomersEmailInfo.count }.by(4)

      email_infos = CreatorContactingCustomersEmailInfo.where(purchase:).where("id > ?", initial_count).order(:id).last(4)
      expect(email_infos.map(&:installment_id)).to contain_exactly(
        seller_post_to_all_customers.id,
        seller_workflow_post_to_all_customers.id,
        seller_post_with_bought_products_filter_product_a_and_c.id,
        workflow_post_product_a.id
      )

      email_infos.each do |email_info|
        expect(email_info.attributes).to include(
          "type" => "CreatorContactingCustomersEmailInfo",
          "purchase_id" => purchase.id,
          "state" => "sent",
          "email_name" => "purchase_installment"
        )
        expect(email_info.sent_at).to be_within(5.seconds).of(Time.current)
      end

      expect(PostSendgridApi.mails.size).to eq(1)
      expect(PostSendgridApi.mails.keys).to include(purchase.email)

      expect(CreatorContactingCustomersEmailInfo.where(installment: regular_post_product_a, purchase:).count).to eq(1)
    end

    it "passes workflow_id to find_missed_posts_for when provided" do
      expect(described_class).to receive(:find_missed_posts_for).with(purchase:, workflow_id: workflow_post_product_a.workflow.external_id).and_call_original

      described_class.deliver_missed_posts_for!(purchase:, workflow_id: workflow_post_product_a.workflow.external_id)
    end

    it "raises CustomerDNDEnabledError when user can't be contacted for purchase" do
      purchase.update!(can_contact: false)

      expect do
        described_class.deliver_missed_posts_for!(purchase:)
      end.to raise_error(CustomersService::CustomerDNDEnabledError, "Purchase #{purchase.id} has opted out of receiving emails")

      expect(PostSendgridApi.mails).to be_empty
      expect(CreatorContactingCustomersEmailInfo.where(purchase:).where(installment: [
                                                                          seller_post_to_all_customers,
                                                                          seller_workflow_post_to_all_customers,
                                                                          seller_post_with_bought_products_filter_product_a_and_c,
                                                                          workflow_post_product_a
                                                                        ])).to be_empty
    end

    it "raises SellerNotEligibleError when seller is not eligible to send emails" do
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE - 1)

      expect do
        described_class.deliver_missed_posts_for!(purchase:)
      end.to raise_error(CustomersService::SellerNotEligibleError, "You are not eligible to resend this email.")

      expect(PostSendgridApi.mails).to be_empty
      expect(CreatorContactingCustomersEmailInfo.where(purchase:).where(installment: [
                                                                          seller_post_to_all_customers,
                                                                          seller_workflow_post_to_all_customers,
                                                                          seller_post_with_bought_products_filter_product_a_and_c,
                                                                          workflow_post_product_a
                                                                        ])).to be_empty
    end

    it "raises PostNotSentError and aborts batch sending when send_post! raises a StandardError" do
      error_message = "Network error occurred"
      allow(described_class).to receive(:send_post!).and_call_original
      allow(described_class).to receive(:send_post!).with(post: seller_post_to_all_customers, purchase:).and_raise(StandardError.new(error_message))

      expect do
        described_class.deliver_missed_posts_for!(purchase:)
      end.to raise_error(CustomersService::PostNotSentError) do |error|
        expect(error.message).to eq("Missed post #{seller_post_to_all_customers.id} could not be sent. Aborting batch sending for the remaining posts. Original message: #{error_message}")
        expect(error.backtrace).to be_an(Array)
        expect(error.backtrace).not_to be_empty
      end

      expect(PostSendgridApi.mails).to be_empty
      expect(CreatorContactingCustomersEmailInfo.where(purchase:).where(installment: [
                                                                          seller_post_to_all_customers,
                                                                          seller_workflow_post_to_all_customers,
                                                                          seller_post_with_bought_products_filter_product_a_and_c,
                                                                          workflow_post_product_a
                                                                        ])).to be_empty
    end
  end
end
