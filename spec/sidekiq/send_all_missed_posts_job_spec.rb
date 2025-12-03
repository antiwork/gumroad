# frozen_string_literal: true

require "spec_helper"

describe SendAllMissedPostsJob do
  let(:seller) { create(:named_seller) }
  let(:link) { create(:product, user: seller) }
  let!(:purchase) { build(:purchase, seller:, link:).tap { |p| p.save!(validate: false) } }
  let!(:post1) { create(:installment, link:, seller:, published_at: Time.current, send_emails: true) }
  let!(:post2) { create(:installment, link:, seller:, published_at: Time.current, send_emails: true) }

  describe "#perform" do
    before do
      Rails.cache.clear
    end

    it "retrieves missed posts at job execution time and sends them" do
      expect(PostEmailApi).to receive(:process).with(
        post: post1,
        recipients: [{
          email: purchase.email,
          purchase: purchase,
          url_redirect: purchase.url_redirect,
          subscription: purchase.subscription,
        }.compact_blank]
      )
      expect(PostEmailApi).to receive(:process).with(
        post: post2,
        recipients: [{
          email: purchase.email,
          purchase: purchase,
          url_redirect: purchase.url_redirect,
          subscription: purchase.subscription,
        }.compact_blank]
      )

      described_class.new.perform(seller.id, purchase.id)
    end

    it "clears existing email info records before sending each post" do
      email_info1 = create(:creator_contacting_customers_email_info, purchase:, installment: post1)
      email_info2 = create(:creator_contacting_customers_email_info, purchase:, installment: post2)

      allow(PostEmailApi).to receive(:process) do |args|
        expect(CreatorContactingCustomersEmailInfo.where(id: [email_info1.id, email_info2.id])).to be_empty
      end

      described_class.new.perform(seller.id, purchase.id)
    end

    it "respects throttling mechanism and does not send if cache exists" do
      Rails.cache.write("post_email:#{post1.id}:#{purchase.id}", true, expires_in: 8.hours)
      Rails.cache.write("post_email:#{post2.id}:#{purchase.id}", true, expires_in: 8.hours)

      expect(PostEmailApi).to_not receive(:process)

      described_class.new.perform(seller.id, purchase.id)

      expect(Rails.cache.read("post_email:#{post1.id}:#{purchase.id}")).to be_truthy
      expect(Rails.cache.read("post_email:#{post2.id}:#{purchase.id}")).to be_truthy
    end

    it "continues processing other posts if one fails" do
      call_count = 0
      allow(PostEmailApi).to receive(:process) do |args|
        call_count += 1
        if args[:post] == post1
          raise StandardError.new("Email failed")
        end
      end

      expect(Rails.logger).to receive(:error).at_least(:once)

      expect { described_class.new.perform(seller.id, purchase.id) }.not_to raise_error

      expect(call_count).to eq(2)
    end

    it "logs completion message" do
      allow(PostEmailApi).to receive(:process)
      expect(Rails.logger).to receive(:info).with(/Completed processing 2 missed posts/)

      described_class.new.perform(seller.id, purchase.id)
    end
  end
end
