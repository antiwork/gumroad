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

      it "leaves a note on the user for Gumclaw review" do
        expect do
          described_class.check(product, :product)
        end.to change { seller.reload.comments.count }.by(1)

        comment = seller.comments.last
        expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_NOTE)
        expect(comment.author_name).to eq(described_class::AUTHOR_NAME)
        expect(comment.content).to include("Product ##{product.id}")
        expect(comment.content).to include("Matched blocked word: banned")
      end

      it "does not create a duplicate note on rapid retries with identical content" do
        described_class.check(product, :product)

        expect do
          described_class.check(product, :product)
          described_class.check(product, :product)
        end.not_to change { seller.reload.comments.count }
      end

      it "creates a fresh note once the dedup window has elapsed" do
        described_class.check(product, :product)

        travel_to(described_class::ADMIN_COMMENT_DEDUP_WINDOW.from_now + 1.second) do
          expect do
            described_class.check(product, :product)
          end.to change { seller.reload.comments.count }.by(1)
        end
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

      it "leaves a note on the user" do
        expect do
          described_class.check(product, :product)
        end.to change { seller.reload.comments.count }.by(1)

        expect(seller.comments.last.content).to include("OpenAI moderation flagged: sexual")
      end
    end

    context "when all strategies return compliant" do
      it "returns passed: true without creating a comment" do
        result = nil
        expect do
          result = described_class.check(product, :product)
        end.not_to change { seller.reload.comments.count }

        expect(result.passed).to eq(true)
        expect(result.reasons).to eq([])
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
end
