# frozen_string_literal: true

require "spec_helper"

RSpec.describe ContentModeration::ModerateRecordService, :vcr do
  let(:strategy_result) { Struct.new(:status, :reasoning, keyword_init: true) }
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, name: "Test", description: "Clean description") }

  before do
    Feature.activate(:content_moderation)
    allow(ContentModeration::Strategies::BlocklistStrategy).to receive(:new).and_return(
      instance_double(ContentModeration::Strategies::BlocklistStrategy, perform: strategy_result.new(status: "compliant", reasoning: []))
    )
    allow(ContentModeration::Strategies::ClassifierStrategy).to receive(:new).and_return(
      instance_double(ContentModeration::Strategies::ClassifierStrategy, perform: strategy_result.new(status: "compliant", reasoning: []))
    )
    allow(ContentModeration::Strategies::PromptStrategy).to receive(:new).and_return(
      instance_double(ContentModeration::Strategies::PromptStrategy, perform: strategy_result.new(status: "compliant", reasoning: []))
    )
  end

  describe ".check" do
    it "returns passed when the feature flag is off" do
      Feature.deactivate(:content_moderation)
      expect(ContentModeration::ContentExtractor).not_to receive(:new)

      result = described_class.check(product, :product)

      expect(result.passed).to eq(true)
      expect(result.reasons).to eq([])
    end

    it "skips moderation for verified sellers" do
      seller.update!(verified: true)
      expect(ContentModeration::ContentExtractor).not_to receive(:new)

      result = described_class.check(product, :product)

      expect(result.passed).to eq(true)
      expect(result.reasons).to eq([])
    end

    it "skips moderation for products with content_moderation_disabled set" do
      product.update!(content_moderation_disabled: true)
      expect(ContentModeration::ContentExtractor).not_to receive(:new)

      result = described_class.check(product, :product)

      expect(result.passed).to eq(true)
      expect(result.reasons).to eq([])
    end

    it "returns passed when content is empty" do
      allow_any_instance_of(ContentModeration::ContentExtractor).to receive(:extract_from_product)
        .and_return(ContentModeration::ContentExtractor::Result.new(text: "", image_urls: []))

      result = described_class.check(product, :product)

      expect(result.passed).to eq(true)
    end

    context "when blocklist flags the content" do
      before do
        allow(ContentModeration::Strategies::BlocklistStrategy).to receive(:new).and_return(
          instance_double(ContentModeration::Strategies::BlocklistStrategy,
                          perform: strategy_result.new(status: "flagged", reasoning: ["Matched blocked word: banned"]))
        )
      end

      it "returns passed: false with reasons" do
        result = described_class.check(product, :product)

        expect(result.passed).to eq(false)
        expect(result.reasons).to eq(["Matched blocked word: banned"])
      end

      it "short-circuits without running AI strategies" do
        expect(ContentModeration::Strategies::ClassifierStrategy).not_to receive(:new)
        expect(ContentModeration::Strategies::PromptStrategy).not_to receive(:new)

        described_class.check(product, :product)
      end

      it "enqueues a note on the user for Gumclaw review" do
        ContentModerationAdminCommentJob.clear

        described_class.check(product, :product)

        expect(ContentModerationAdminCommentJob.jobs.size).to eq(1)
        user_id, content = ContentModerationAdminCommentJob.jobs.last["args"]
        expect(user_id).to eq(seller.id)
        expect(content).to include("Product ##{product.id}")
        expect(content).to include("Matched blocked word: banned")
      end

      it "preserves the note even when the check runs inside a transaction that rolls back" do
        ContentModerationAdminCommentJob.clear
        # Materialize the lazily created records now so the savepoint rollback
        # below only undoes work done during the check itself.
        product

        # Publishing runs this check as a validation inside the record's save
        # transaction, and a blocked publish rolls that transaction back. The
        # note must survive the rollback or blocked publishes leave no trail.
        ActiveRecord::Base.transaction(requires_new: true) do
          described_class.check(product, :product)
          raise ActiveRecord::Rollback
        end

        expect do
          ContentModerationAdminCommentJob.drain
        end.to change { seller.reload.comments.count }.by(1)
        expect(seller.comments.last.content).to include("Matched blocked word: banned")
      end
    end

    context "when an AI strategy flags the content" do
      before do
        allow(ContentModeration::Strategies::ClassifierStrategy).to receive(:new).and_return(
          instance_double(ContentModeration::Strategies::ClassifierStrategy,
                          perform: strategy_result.new(status: "flagged", reasoning: ["OpenAI moderation flagged: sexual"]))
        )
      end

      it "returns passed: false with AI reasons" do
        result = described_class.check(product, :product)

        expect(result.passed).to eq(false)
        expect(result.reasons).to include("OpenAI moderation flagged: sexual")
      end

      it "enqueues a note on the user" do
        ContentModerationAdminCommentJob.clear

        described_class.check(product, :product)

        expect(ContentModerationAdminCommentJob.jobs.size).to eq(1)
        expect(ContentModerationAdminCommentJob.jobs.last["args"].second).to include("OpenAI moderation flagged: sexual")
      end
    end

    context "when all strategies return compliant" do
      it "returns passed: true without enqueuing a comment" do
        ContentModerationAdminCommentJob.clear

        result = described_class.check(product, :product)

        expect(result.passed).to eq(true)
        expect(result.reasons).to eq([])
        expect(ContentModerationAdminCommentJob.jobs).to be_empty
      end
    end

    it "propagates errors raised by AI strategies" do
      classifier = instance_double(ContentModeration::Strategies::ClassifierStrategy)
      allow(classifier).to receive(:perform).and_raise(StandardError, "OpenAI down")
      allow(ContentModeration::Strategies::ClassifierStrategy).to receive(:new).and_return(classifier)

      expect { described_class.check(product, :product) }.to raise_error(StandardError, "OpenAI down")
    end

    context "for posts" do
      let(:post) { create(:installment, seller: seller, name: "Post", message: "<p>Body</p>") }

      it "runs the post extractor" do
        expect_any_instance_of(ContentModeration::ContentExtractor).to receive(:extract_from_post).with(post).and_call_original

        described_class.check(post, :post)
      end
    end
  end

  describe ".humanize_reasons" do
    it "maps prompt strategy spam reasons to an actionable label" do
      reasons = ["spam: aggressive call-to-action phrases ('Watch HERE') without providing substantial information"]

      expect(described_class.humanize_reasons(reasons)).to eq("content that reads as promotional spam")
    end

    it "maps prompt strategy adult content reasons to an actionable label" do
      expect(described_class.humanize_reasons(["adult_content: explicit imagery"])).to eq("adult content")
    end

    it "maps classifier category reasons to category labels" do
      reasons = ["OpenAI moderation flagged: violence (score: 0.95, threshold: 0.9)"]

      expect(described_class.humanize_reasons(reasons)).to eq("violent content")
    end

    it "falls back to a generic phrase for unrecognized reasons" do
      expect(described_class.humanize_reasons(["Matched blocked word: banned"]))
        .to eq("something that may violate our content guidelines")
    end
  end

  describe ".seller_message" do
    it "names the flagged record when a title is given" do
      message = described_class.seller_message(["spam: repetitive CTAs"], "email", title: "Email #7")

      expect(message).to eq("The email \"Email #7\" can’t be saved because it looks like it contains content that reads as promotional spam. Please update the content to follow our content guidelines.")
    end

    it "keeps the generic subject when no title is given" do
      message = described_class.seller_message(["OpenAI moderation flagged: violence"], "product")

      expect(message).to start_with("This product can’t be saved")
    end
  end
end
