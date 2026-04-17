# frozen_string_literal: true

require "spec_helper"

RSpec.describe ContentModeration::ModerateRecordService, :freeze_time do
  let(:result_class) { Struct.new(:status, :reasoning, keyword_init: true) }

  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_ENABLED").and_return("true")
    allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_PERCENTAGE").and_return("100")
    allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_SUSPENSION_THRESHOLD").and_return("5")
    allow(InternalNotificationWorker).to receive(:perform_async)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:error)
  end

  describe "#perform" do
    context "when moderation is disabled" do
      let(:product) { create(:product) }

      it "returns early" do
        allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_ENABLED").and_return("false")
        expect(ContentModeration::ContentExtractor).not_to receive(:new)

        described_class.new(product, :product).perform
      end
    end

    context "for products" do
      let(:seller) { create(:user) }
      let(:product) { create(:product, user: seller) }
      let(:service) { described_class.new(product, :product) }

      before do
        allow_any_instance_of(ContentModeration::ContentExtractor)
          .to receive(:extract_from_product)
          .and_return(ContentModeration::ContentExtractor::Result.new(text: "product text", image_urls: []))
        allow(seller).to receive(:vip_creator?).and_return(false)
      end

      it "unpublishes flagged products and marks them content moderated" do
        expect(ContentModeration::ModerateProductJob).not_to receive(:perform_async)
        allow(service).to receive(:run_strategies).and_return([result_class.new(status: "flagged", reasoning: ["blocked"])])

        service.perform

        expect(product.reload).to be_is_unpublished_by_admin
        expect(product.reload).to be_content_moderated
      end

      it "republishes compliant products that were unpublished by admin" do
        product.unpublish!(is_unpublished_by_admin: true)
        product.update_attribute(:content_moderated, true)
        allow(service).to receive(:run_strategies).and_return([result_class.new(status: "compliant", reasoning: [])])
        expect(described_class).not_to receive(:check)

        service.perform

        expect(product.reload).not_to be_is_unpublished_by_admin
        expect(product.reload).not_to be_content_moderated
      end

      it "does not republish admin-unpublished products that were not content moderated" do
        product.unpublish!(is_unpublished_by_admin: true)
        allow(service).to receive(:run_strategies).and_return([result_class.new(status: "compliant", reasoning: [])])

        service.perform

        expect(product.reload).to be_is_unpublished_by_admin
      end

      it "does not unpublish flagged products for VIP creators" do
        allow(service).to receive(:run_strategies).and_return([result_class.new(status: "flagged", reasoning: ["blocked"])])
        allow(seller).to receive(:vip_creator?).and_return(true)

        service.perform

        expect(product.reload).not_to be_is_unpublished_by_admin
      end

      it "suspends creators once their flagged record count reaches the threshold" do
        allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_SUSPENSION_THRESHOLD").and_return("1")
        allow(service).to receive(:run_strategies).and_return([result_class.new(status: "flagged", reasoning: ["blocked"])])
        allow(service).to receive(:user_flagged_record_count).and_return(1)

        service.perform

        expect(seller.reload).to be_suspended_for_tos_violation
        expect(seller.tos_violation_reason).to eq("Content policy violation")
      end

      it "marks suspended creators compliant once the flagged count drops below the threshold" do
        product.unpublish!(is_unpublished_by_admin: true)
        product.update_attribute(:content_moderated, true)
        seller.suspend_for_tos_violation!(author_name: "ContentModeration")
        allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_SUSPENSION_THRESHOLD").and_return("1")
        allow(service).to receive(:run_strategies).and_return([result_class.new(status: "compliant", reasoning: [])])

        service.perform

        expect(seller.reload).to be_compliant
        expect(product.reload).not_to be_is_unpublished_by_admin
      end
    end

    context "for posts" do
      let(:seller) { create(:user) }
      let(:post) { create(:audience_post, seller:) }
      let(:service) { described_class.new(post, :post) }

      before do
        allow(post).to receive(:user).and_return(seller)
        allow(seller).to receive(:vip_creator?).and_return(false)
        allow_any_instance_of(ContentModeration::ContentExtractor)
          .to receive(:extract_from_post)
          .and_return(ContentModeration::ContentExtractor::Result.new(text: "post text", image_urls: []))
      end

      it "unpublishes flagged posts" do
        allow(service).to receive(:run_strategies).and_return([result_class.new(status: "flagged", reasoning: ["blocked"])])

        service.perform

        expect(post.reload).to be_is_unpublished_by_admin
      end

      it "republishes compliant posts that were unpublished by admin" do
        post.publish!
        post.unpublish!(is_unpublished_by_admin: true)
        allow(service).to receive(:run_strategies).and_return([result_class.new(status: "compliant", reasoning: [])])
        expect(described_class).not_to receive(:check)

        service.perform

        expect(post.reload).to be_published
        expect(post.reload).not_to be_is_unpublished_by_admin
      end
    end

    context "for profiles" do
      let(:user) { create(:user, name: "Creator") }
      let(:service) { described_class.new(user, :profile) }

      before do
        allow(user).to receive(:vip_creator?).and_return(false)
        allow(user).to receive(:can_flag_for_tos_violation?).and_return(true)
        allow_any_instance_of(ContentModeration::ContentExtractor)
          .to receive(:extract_from_profile)
          .and_return(ContentModeration::ContentExtractor::Result.new(text: "profile text", image_urls: []))
      end

      it "flags violating profiles" do
        allow(service).to receive(:run_strategies).and_return([result_class.new(status: "flagged", reasoning: ["blocked"])])

        service.perform

        expect(user.reload).to be_flagged_for_tos_violation
        expect(user.tos_violation_reason).to eq("Content policy violation")
      end

      it "marks flagged profiles compliant when moderation passes" do
        user.update!(user_risk_state: "flagged_for_tos_violation")
        allow(service).to receive(:run_strategies).and_return([result_class.new(status: "compliant", reasoning: [])])

        service.perform

        expect(user.reload).to be_compliant
      end

      it "does not flag violating profiles for VIP creators" do
        allow(service).to receive(:run_strategies).and_return([result_class.new(status: "flagged", reasoning: ["blocked"])])
        allow(user).to receive(:vip_creator?).and_return(true)

        service.perform

        expect(user.reload).not_to be_flagged
      end
    end
  end

  describe ".check" do
    let(:product) { create(:product) }

    before do
      allow_any_instance_of(ContentModeration::ContentExtractor)
        .to receive(:extract_from_product)
        .and_return(ContentModeration::ContentExtractor::Result.new(text: "product text", image_urls: []))
    end

    it "returns passed: true when moderation is disabled" do
      allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_ENABLED").and_return("false")

      result = described_class.check(product, :product)

      expect(result.passed).to eq(true)
      expect(result.reasons).to eq([])
    end

    it "returns passed: true when content is empty" do
      allow_any_instance_of(ContentModeration::ContentExtractor)
        .to receive(:extract_from_product)
        .and_return(ContentModeration::ContentExtractor::Result.new(text: "", image_urls: []))

      result = described_class.check(product, :product)

      expect(result.passed).to eq(true)
      expect(result.reasons).to eq([])
    end

    it "returns passed: false with reasons when any strategy flags content" do
      allow_any_instance_of(described_class).to receive(:run_strategies).and_return(
        [
          result_class.new(status: "compliant", reasoning: []),
          result_class.new(status: "flagged", reasoning: ["policy violation"]),
        ]
      )

      result = described_class.check(product, :product)

      expect(result.passed).to eq(false)
      expect(result.reasons).to eq(["policy violation"])
    end

    it "returns passed: true when all strategies are compliant" do
      allow_any_instance_of(described_class).to receive(:run_strategies).and_return(
        [result_class.new(status: "compliant", reasoning: [])]
      )

      result = described_class.check(product, :product)

      expect(result.passed).to eq(true)
      expect(result.reasons).to eq([])
    end

    it "does not take actions (record stays published, user stays compliant)" do
      seller = product.user
      allow_any_instance_of(described_class).to receive(:run_strategies).and_return(
        [result_class.new(status: "flagged", reasoning: ["bad"])]
      )

      described_class.check(product, :product)

      expect(product.reload).not_to be_is_unpublished_by_admin
      expect(seller.reload).not_to be_suspended
    end
  end

  describe "#should_moderate?" do
    let(:service) { described_class.new(create(:product), :product) }

    it "always moderates when the percentage is 100" do
      allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_PERCENTAGE").and_return("100")

      expect(service.send(:should_moderate?)).to eq(true)
    end

    it "never moderates when the percentage is 0" do
      allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_PERCENTAGE").and_return("0")

      expect(service.send(:should_moderate?)).to eq(false)
    end

    it "samples based on the configured percentage" do
      allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_PERCENTAGE").and_return("50")
      allow(service).to receive(:rand).with(100).and_return(49, 50)

      expect(service.send(:should_moderate?)).to eq(true)
      expect(service.send(:should_moderate?)).to eq(false)
    end
  end

  describe "#run_strategies" do
    let(:service) { described_class.new(create(:product), :product) }
    let(:content) { ContentModeration::ContentExtractor::Result.new(text: "content", image_urls: []) }

    it "rescues failures within strategy threads and returns a compliant fallback" do
      success_strategy_class = Class.new do
        def perform
          self.class::Result.new(status: "compliant", reasoning: [])
        end
      end
      success_strategy_class.const_set(:Result, Struct.new(:status, :reasoning, keyword_init: true))

      error_strategy_class = Class.new do
        def perform
          raise StandardError, "boom"
        end
      end
      error_strategy_class.const_set(:Result, Struct.new(:status, :reasoning, keyword_init: true))

      allow(ContentModeration::Strategies::BlocklistStrategy).to receive(:new).and_return(success_strategy_class.new)
      allow(ContentModeration::Strategies::ClassifierStrategy).to receive(:new).and_return(error_strategy_class.new)
      allow(ContentModeration::Strategies::PromptStrategy).to receive(:new).and_return(success_strategy_class.new)

      results = service.send(:run_strategies, content)

      expect(results.map(&:status)).to eq(["compliant", "compliant", "compliant"])
      expect(Rails.logger).to have_received(:error).with("ContentModeration strategy error: boom")
    end
  end

  describe "#user_flagged_record_count" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let(:service) { described_class.new(product, :product) }

    it "counts only moderated products and alive flagged posts" do
      moderated_product = create(:product, user: seller)
      moderated_product.unpublish!(is_unpublished_by_admin: true)
      moderated_product.update_attribute(:content_moderated, true)

      unmoderated_product = create(:product, user: seller)
      unmoderated_product.unpublish!(is_unpublished_by_admin: true)

      alive_post = create(:audience_post, seller: seller)
      alive_post.update!(is_unpublished_by_admin: true)

      deleted_post = create(:audience_post, seller: seller)
      deleted_post.update!(is_unpublished_by_admin: true)
      deleted_post.mark_deleted!

      expect(service.send(:user_flagged_record_count)).to eq(2)
    end
  end

  describe "#log_moderation_result" do
    let(:product) { create(:product) }
    let(:service) { described_class.new(product, :product) }

    it "skips internal notifications for compliant results" do
      service.send(:log_moderation_result, "compliant", nil)

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
    end
  end
end
