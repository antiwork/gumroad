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

    it "opts the prompt strategy into spam corroboration" do
      described_class.check(product, :product)

      expect(ContentModeration::Strategies::PromptStrategy).to have_received(:new)
        .with(hash_including(corroborate_judgment_flags: true))
    end

    # The off-platform-fulfillment preset only makes sense for a listing with
    # nothing attached for the buyer, so the emptiness half of that judgment is
    # decided here in code and only then handed to the model.
    describe "off-platform fulfillment opt-in" do
      it "asks about off-platform fulfillment for a product with no files and no content" do
        described_class.check(product, :product)

        expect(ContentModeration::Strategies::PromptStrategy).to have_received(:new)
          .with(hash_including(check_off_platform_fulfillment: true))
      end

      it "does not ask when the product has files buyers can download" do
        product.product_files << create(:product_file)
        product.save!

        described_class.check(product.reload, :product)

        expect(ContentModeration::Strategies::PromptStrategy).to have_received(:new)
          .with(hash_including(check_off_platform_fulfillment: false))
      end

      it "does not ask when the product has rich content buyers can read" do
        create(:rich_content, entity: product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Lesson one" }] }])

        described_class.check(product.reload, :product)

        expect(ContentModeration::Strategies::PromptStrategy).to have_received(:new)
          .with(hash_including(check_off_platform_fulfillment: false))
      end

      it "still asks when the only rich content is the editor's blank placeholder page" do
        # Opening the content tab creates a page holding one empty paragraph.
        # That is not something a buyer can read, so a listing in this shape is
        # still empty and must be asked about.
        create(:rich_content, entity: product, title: nil, description: [{ "type" => "paragraph" }])

        described_class.check(product.reload, :product)

        expect(ContentModeration::Strategies::PromptStrategy).to have_received(:new)
          .with(hash_including(check_off_platform_fulfillment: true))
      end

      it "does not ask when a blank page carries a title the seller wrote" do
        create(:rich_content, entity: product, title: "Week one", description: [{ "type" => "paragraph" }])

        described_class.check(product.reload, :product)

        expect(ContentModeration::Strategies::PromptStrategy).to have_received(:new)
          .with(hash_including(check_off_platform_fulfillment: false))
      end

      it "does not ask when only a variant carries the files" do
        membership = create(:membership_product, user: seller)
        tier = membership.tiers.first
        tier.product_files << create(:product_file, link: membership)
        tier.save!

        described_class.check(membership.reload, :product)

        expect(ContentModeration::Strategies::PromptStrategy).to have_received(:new)
          .with(hash_including(check_off_platform_fulfillment: false))
      end

      it "asks for a membership whose tier has neither files nor content" do
        membership = create(:membership_product, user: seller)

        described_class.check(membership.reload, :product)

        expect(ContentModeration::Strategies::PromptStrategy).to have_received(:new)
          .with(hash_including(check_off_platform_fulfillment: true))
      end

      it "does not ask when the deliverable is a Gumroad-managed Discord integration" do
        community_product = create(:product, user: seller, active_integrations: [create(:discord_integration)])

        described_class.check(community_product.reload, :product)

        expect(ContentModeration::Strategies::PromptStrategy).to have_received(:new)
          .with(hash_including(check_off_platform_fulfillment: false))
      end

      it "does not ask when only a tier carries the Gumroad-managed integration" do
        membership = create(:membership_product, user: seller)
        membership.tiers.first.active_integrations << create(:circle_integration)

        described_class.check(membership.reload, :product)

        expect(ContentModeration::Strategies::PromptStrategy).to have_received(:new)
          .with(hash_including(check_off_platform_fulfillment: false))
      end

      it "does not ask for service products, whose deliverable is the seller's own work" do
        # Service products require an account at least 30 days old.
        seller.update!(created_at: 2.months.ago)
        call_product = create(:call_product, user: seller)

        described_class.check(call_product, :product)

        expect(ContentModeration::Strategies::PromptStrategy).to have_received(:new)
          .with(hash_including(check_off_platform_fulfillment: false))
      end

      it "does not ask for physical products, which ship instead of delivering content" do
        physical = create(:physical_product, user: seller)

        described_class.check(physical, :product)

        expect(ContentModeration::Strategies::PromptStrategy).to have_received(:new)
          .with(hash_including(check_off_platform_fulfillment: false))
      end

      it "does not ask for bundles, which deliver their component products" do
        bundle = create(:product, :bundle, user: seller)

        described_class.check(bundle, :product)

        expect(ContentModeration::Strategies::PromptStrategy).to have_received(:new)
          .with(hash_including(check_off_platform_fulfillment: false))
      end

      it "does not ask for posts, which have no attachable deliverable of their own" do
        post = create(:installment, seller: seller, name: "Post", message: "<p>Body</p>")

        described_class.check(post, :post)

        expect(ContentModeration::Strategies::PromptStrategy).to have_received(:new)
          .with(hash_including(check_off_platform_fulfillment: false))
      end
    end

    context "when the prompt strategy downgrades an uncorroborated spam flag" do
      before do
        allow(ContentModeration::Strategies::PromptStrategy).to receive(:new).and_return(
          instance_double(ContentModeration::Strategies::PromptStrategy,
                          perform: ContentModeration::Strategies::PromptStrategy::Result.new(
                            status: "compliant",
                            reasoning: [],
                            audit_reasoning: ["spam (uncorroborated, 1/3 samples flagged): repetitive CTAs"]
                          ))
        )
      end

      it "passes but records the downgraded flag in a non-blocking note" do
        ContentModerationAdminCommentJob.clear

        result = described_class.check(product, :product)

        expect(result.passed).to eq(true)
        expect(result.reasons).to eq([])
        expect(ContentModerationAdminCommentJob.jobs.size).to eq(1)
        user_id, content = ContentModerationAdminCommentJob.jobs.last["args"]
        expect(user_id).to eq(seller.id)
        expect(content).to include("flagged but did not block")
        expect(content).to include("spam (uncorroborated, 1/3 samples flagged): repetitive CTAs")
      end

      it "still blocks and leaves both notes when another strategy flags" do
        ContentModerationAdminCommentJob.clear
        allow(ContentModeration::Strategies::ClassifierStrategy).to receive(:new).and_return(
          instance_double(ContentModeration::Strategies::ClassifierStrategy,
                          perform: strategy_result.new(status: "flagged", reasoning: ["OpenAI moderation flagged: sexual"]))
        )

        result = described_class.check(product, :product)

        expect(result.passed).to eq(false)
        expect(result.reasons).to eq(["OpenAI moderation flagged: sexual"])
        contents = ContentModerationAdminCommentJob.jobs.map { |j| j["args"].second }
        expect(contents).to include(a_string_including("blocked publish of"))
        expect(contents).to include(a_string_including("flagged but did not block"))
      end
    end

    # A corroborated spam flag is still a judgment call about the seller's
    # intent, and it fires on the writing style of the info-product genre. On a
    # listing that actually delivers something we keep it as a reviewable note
    # rather than blocking the publish.
    context "when the spam preset flags a product that has a deliverable" do
      before do
        allow(ContentModeration::Strategies::PromptStrategy).to receive(:new).and_return(
          instance_double(ContentModeration::Strategies::PromptStrategy,
                          perform: ContentModeration::Strategies::PromptStrategy::Result.new(
                            status: "flagged",
                            reasoning: ["spam: reads like a sales pitch and lacks coherent prose"],
                            audit_reasoning: []
                          ))
        )
      end

      it "publishes and records the flag as a non-blocking note when files are attached" do
        ContentModerationAdminCommentJob.clear
        product.product_files << create(:product_file)
        product.save!

        result = described_class.check(product.reload, :product)

        expect(result.passed).to eq(true)
        expect(result.reasons).to eq([])
        contents = ContentModerationAdminCommentJob.jobs.map { |j| j["args"].second }
        expect(contents).to contain_exactly(
          a_string_including("flagged but did not block").and(
            a_string_including("not blocked: listing has content attached")
          )
        )
      end

      it "publishes when the deliverable is readable content instead of files" do
        create(:rich_content, entity: product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Lesson one" }] }])

        expect(described_class.check(product.reload, :product).passed).to eq(true)
      end

      it "publishes when the deliverable is a Gumroad-managed community invite" do
        community_product = create(:product, user: seller, active_integrations: [create(:discord_integration)])

        expect(described_class.check(community_product.reload, :product).passed).to eq(true)
      end

      it "still blocks an empty listing, where a spam flag has no real product behind it" do
        result = described_class.check(product, :product)

        expect(result.passed).to eq(false)
        expect(result.reasons).to eq(["spam: reads like a sales pitch and lacks coherent prose"])
      end

      it "still blocks a post, which has no deliverable of its own" do
        post = create(:installment, seller: seller, name: "Post", message: "<p>Body</p>")

        expect(described_class.check(post, :post).passed).to eq(false)
      end

      it "still blocks on a non-spam reason flagged alongside the spam one" do
        product.product_files << create(:product_file)
        product.save!
        allow(ContentModeration::Strategies::ClassifierStrategy).to receive(:new).and_return(
          instance_double(ContentModeration::Strategies::ClassifierStrategy,
                          perform: strategy_result.new(status: "flagged", reasoning: ["OpenAI moderation flagged: sexual"]))
        )

        result = described_class.check(product.reload, :product)

        expect(result.passed).to eq(false)
        expect(result.reasons).to eq(["OpenAI moderation flagged: sexual"])
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

    it "explains what is missing for an off-platform fulfillment flag" do
      message = described_class.seller_message(["off_platform_fulfillment: buyer must DM on Telegram"], "product")

      expect(message).to eq(
        "Buyers need to receive what they paid for on Gumroad. This product has no content attached and " \
        "directs buyers to message you on another platform to get it, which we don’t allow. Add the files, " \
        "videos, or written content buyers should get when they buy, then publish again."
      )
    end

    # Otherwise the seller adds the missing files, republishes, and is blocked
    # again for a reason we knew about but withheld the first time.
    it "also names a violation that flagged alongside off-platform fulfillment" do
      message = described_class.seller_message(
        ["off_platform_fulfillment: buyer must DM on Telegram", "OpenAI moderation flagged: sexual"],
        "product"
      )

      expect(message).to start_with("Buyers need to receive what they paid for on Gumroad.")
      expect(message).to end_with("It also looks like this product contains sexual content.")
    end
  end
end
