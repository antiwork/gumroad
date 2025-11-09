# frozen_string_literal: true

require "spec_helper"

describe SendAllMissedPostsJob do
  let(:seller) { create(:named_seller) }
  let(:link) { create(:product, user: seller) }
  let(:purchase) { build(:purchase, seller:, link:).tap { |p| p.save!(validate: false) } }
  let(:post1) { create(:installment, link:) }
  let(:post2) { create(:installment, link:) }

  describe "#perform" do
    it "sends each missed post via PostEmailApi" do
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

      described_class.new.perform(seller.id, purchase.id, [post1.id, post2.id])
    end

    it "clears existing email info records for each post" do
      email_info1 = create(:creator_contacting_customers_email_info, purchase:, installment: post1)
      email_info2 = create(:creator_contacting_customers_email_info, purchase:, installment: post2)

      expect(PostEmailApi).to receive(:process).twice

      described_class.new.perform(seller.id, purchase.id, [post1.id, post2.id])

      expect(CreatorContactingCustomersEmailInfo.where(id: email_info1.id)).to be_empty
      expect(CreatorContactingCustomersEmailInfo.where(id: email_info2.id)).to be_empty
    end

    it "clears cache before sending each post" do
      Rails.cache.write("post_email:#{post1.id}:#{purchase.id}", true, expires_in: 8.hours)
      Rails.cache.write("post_email:#{post2.id}:#{purchase.id}", true, expires_in: 8.hours)

      expect(PostEmailApi).to receive(:process).twice

      described_class.new.perform(seller.id, purchase.id, [post1.id, post2.id])

      expect(Rails.cache.read("post_email:#{post1.id}:#{purchase.id}")).to be_nil
      expect(Rails.cache.read("post_email:#{post2.id}:#{purchase.id}")).to be_nil
    end

    it "continues processing other posts if one fails" do
      allow(PostEmailApi).to receive(:process).with(
        post: post1,
        recipients: anything
      ).and_raise(StandardError.new("Email failed"))

      expect(PostEmailApi).to receive(:process).with(
        post: post2,
        recipients: anything
      )

      expect(Rails.logger).to receive(:error).with(/Failed to send post #{post1.id}/)

      described_class.new.perform(seller.id, purchase.id, [post1.id, post2.id])
    end

    it "logs completion message" do
      allow(PostEmailApi).to receive(:process)
      expect(Rails.logger).to receive(:info).with(/Completed sending 2 missed posts/)

      described_class.new.perform(seller.id, purchase.id, [post1.id, post2.id])
    end
  end
end
