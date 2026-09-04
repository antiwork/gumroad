# frozen_string_literal: true

require "spec_helper"

RSpec.describe ContentModeration::ModerateRecordService, :vcr do
  let(:strategy_result) { Struct.new(:status, :reasoning, keyword_init: true) }
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, name: "Test", description: "Clean description") }
  # A file whose upload finished: `analyze` only sets analyze_completed after it
  # has successfully read the stored object.
  let(:uploaded_file) { create(:product_file, analyze_completed: true) }

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

  # An unfinished upload leaves a ProductFile row whose storage key was never
  # written, which is what `exists? == false` stands for here.
  def stub_missing_storage_objects
    allow_any_instance_of(ProductFile).to receive(:s3_object).and_return(double("s3_object", exists?: false))
  end

  describe ".check" do
    it "returns passed when the feature flag is off" do
      Feature.deactivate(:content_moderation)
      expect(ContentModeration::ContentExtractor).not_to receive(:new)

      result = described_class.check(product, :product)

      expect(result.passed).to eq(true)
      expect(result.reasons).to eq([])
    end

    it "runs AI strategy threads inside the Rails executor" do
      wraps = 0
      allow(Rails.application.executor).to receive(:wrap).and_wrap_original do |method, *args, &block|
        wraps += 1
        method.call(*args, &block)
      end
      permits = 0
      allow(ActiveSupport::Dependencies.interlock).to receive(:permit_concurrent_loads).and_wrap_original do |method, *args, &block|
        # AR checkout also yields the interlock; count only this service's join wrapper.
        if block&.source_location&.first&.end_with?("moderate_record_service.rb")
          permits += 1
        end
        method.call(*args, &block)
      end
      checkout = lambda do
        User.first
        strategy_result.new(status: "compliant", reasoning: [])
      end
      %w[ClassifierStrategy PromptStrategy].each do |name|
        klass = ContentModeration::Strategies.const_get(name)
        allow(klass).to receive(:new).and_return(instance_double(klass, perform: nil).tap { |d| allow(d).to receive(:perform, &checkout) })
      end

      described_class.check(product, :product)

      expect(wraps).to eq(2)
      expect(permits).to eq(1)
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

    it "skips moderation for every product of a seller with account-level content_moderation_disabled" do
      product.user.update!(content_moderation_disabled: true)
      expect(ContentModeration::ContentExtractor).not_to receive(:new)

      result = described_class.check(create(:product, user: product.user), :product)

      expect(result.passed).to eq(true)
      expect(result.reasons).to eq([])
    end

    # The exemption is granted over a seller's catalogue, so it must not silently also
    # exempt their posts. A skip would return passed, so a block proves moderation ran.
    it "still moderates a post by a seller with account-level content_moderation_disabled" do
      seller.update!(content_moderation_disabled: true)
      post = create(:installment, seller: seller, name: "Post", message: "<p>Body</p>")
      allow(ContentModeration::Strategies::ClassifierStrategy).to receive(:new).and_return(
        instance_double(ContentModeration::Strategies::ClassifierStrategy,
                        perform: strategy_result.new(status: "flagged", reasoning: ["OpenAI moderation flagged: sexual"]))
      )

      expect(described_class.check(post, :post).passed).to eq(false)
    end

    it "returns passed when content is empty" do
      allow_any_instance_of(ContentModeration::ContentExtractor).to receive(:extract_from_product)
        .and_return(ContentModeration::ContentExtractor::Result.new(text: "", image_urls: []))

      result = described_class.check(product, :product)

      expect(result.passed).to eq(true)
    end

    context "when the record is a storefront page" do
      let(:page) { Page.create!(pageable: seller, slug: "about", title: "About", custom_html: "<p>Copy</p>") }

      # Creating the fixture is itself a moderated save now, so it has to happen
      # under the compliant stubs from the outer `before` — lazily, it would run
      # under whichever flagged stub the example installed and either raise
      # RecordInvalid or spend the admin-note expectation on the fixture.
      before { page }

      it "reads the page through the page extractor" do
        expect_any_instance_of(ContentModeration::ContentExtractor).to receive(:extract_from_page).with(page).and_call_original

        expect(described_class.check(page, :page).passed).to eq(true)
      end

      it "records a flag against the seller naming the page" do
        allow(ContentModeration::Strategies::BlocklistStrategy).to receive(:new).and_return(
          instance_double(ContentModeration::Strategies::BlocklistStrategy,
                          perform: strategy_result.new(status: "flagged", reasoning: ["Matched blocked word: forbidden"]))
        )

        expect(ContentModerationAdminCommentJob).to receive(:perform_async).with(
          seller.id, a_string_including("Page ##{page.id} (about — About)")
        )

        expect(described_class.check(page, :page).passed).to eq(false)
      end

      it "keeps a spam flag as a note instead of blocking for a seller with a live storefront" do
        create(:product, user: seller)
        allow(ContentModeration::Strategies::PromptStrategy).to receive(:new).and_return(
          instance_double(ContentModeration::Strategies::PromptStrategy,
                          perform: strategy_result.new(status: "flagged", reasoning: ["spam: reads like a sales pitch"]))
        )

        expect(ContentModerationAdminCommentJob).to receive(:perform_async).with(
          seller.id, a_string_including("flagged but did not block")
        )

        expect(described_class.check(page, :page).passed).to eq(true)
      end

      it "blocks a spam flag when the seller has no products and no sales, the link-farm shape" do
        expect(seller.links.alive).to be_empty
        allow(ContentModeration::Strategies::PromptStrategy).to receive(:new).and_return(
          instance_double(ContentModeration::Strategies::PromptStrategy,
                          perform: strategy_result.new(status: "flagged", reasoning: ["spam: outbound link farm"]))
        )

        result = described_class.check(page, :page)

        expect(result.passed).to eq(false)
        expect(result.reasons).to eq(["spam: outbound link farm"])
      end

      it "leaves no admin note for a dry-run preview candidate, which was never published" do
        allow(ContentModeration::Strategies::BlocklistStrategy).to receive(:new).and_return(
          instance_double(ContentModeration::Strategies::BlocklistStrategy,
                          perform: strategy_result.new(status: "flagged", reasoning: ["Matched blocked word: forbidden"]))
        )
        candidate = Page.new(pageable: seller, custom_html: "<p>forbidden</p>", moderation_preview: true)

        expect(ContentModerationAdminCommentJob).not_to receive(:perform_async)

        expect(described_class.check(candidate, :page).passed).to eq(false)
      end

      it "still blocks a page on a flag that keys on concrete content" do
        allow(ContentModeration::Strategies::PromptStrategy).to receive(:new).and_return(
          instance_double(ContentModeration::Strategies::PromptStrategy,
                          perform: strategy_result.new(status: "flagged", reasoning: ["adult_content: explicit imagery described"]))
        )

        expect(described_class.check(page, :page).passed).to eq(false)
      end

      it "inherits a product's moderation exemption for its landing page takeover" do
        product.update!(content_moderation_disabled: true)
        product_page = Page.new(pageable: product, custom_html: "<p>Copy</p>")
        expect(ContentModeration::ContentExtractor).not_to receive(:new)

        expect(described_class.check(product_page, :page).passed).to eq(true)
      end

      it "asks the classifier to moderate every selected page image" do
        expect(ContentModeration::Strategies::ClassifierStrategy).to receive(:new)
          .with(hash_including(max_images: :all))
          .and_return(instance_double(ContentModeration::Strategies::ClassifierStrategy,
                                      perform: strategy_result.new(status: "compliant", reasoning: [])))

        expect(described_class.check(page, :page).passed).to eq(true)
      end

      context "when the page carries more images than we will review" do
        let(:over_budget_html) do
          count = ContentModeration::ContentExtractor::MAX_PAGE_IMAGE_URLS + 1
          (1..count).map { |n| %(<img src="https://cdn.example.com/#{n}.png">) }.join
        end
        let(:over_budget_page) { Page.new(pageable: seller, slug: "gallery", title: "Gallery", custom_html: over_budget_html) }

        it "blocks the page instead of approving it on a subset of its images" do
          expect(ContentModeration::Strategies::ClassifierStrategy).not_to receive(:new)

          result = described_class.check(over_budget_page, :page)

          expect(result.passed).to eq(false)
          expect(result.reasons).to eq(
            ["#{described_class::TOO_MANY_IMAGES_REASON_PREFIX} " \
             "(#{ContentModeration::ContentExtractor::MAX_PAGE_IMAGE_URLS + 1})"]
          )
        end

        it "tells the seller the limit rather than naming a content violation" do
          message = described_class.seller_message(described_class.check(over_budget_page, :page).reasons, "page")

          expect(message).to include("more images than we can review")
          expect(message).to include(ContentModeration::ContentExtractor::MAX_PAGE_IMAGE_URLS.to_s)
          expect(message).not_to include("content guidelines")
        end

        it "records the block as a note rather than as abuse history" do
          # A big gallery is a size problem, not a content violation, and the admin
          # trail is read as abuse history.
          expect(ContentModerationAdminCommentJob).to receive(:perform_async)
            .with(seller.id, /flagged but did not block/)

          described_class.check(over_budget_page, :page)
        end

        it "lets the seller rename an already-live page that is over the limit" do
          over_budget_page.save!(validate: false)
          over_budget_page.title = "Renamed gallery"

          # A title-only save cannot change the images, so re-running the image
          # phase would trap the rename on a page that predates the budget.
          expect(over_budget_page.valid?).to eq(true)
        end

        it "lets a live over-budget page swap one image src without growing the set" do
          over_budget_page.save!(validate: false)
          swapped = over_budget_html.sub("https://cdn.example.com/1.png", "https://cdn.example.com/swapped.png")
          over_budget_page.custom_html = swapped

          expect(ContentModeration::Strategies::ClassifierStrategy).to receive(:new)
            .with(hash_including(image_urls: ["https://cdn.example.com/swapped.png"]))
            .and_return(instance_double(ContentModeration::Strategies::ClassifierStrategy,
                                        perform: strategy_result.new(status: "compliant", reasoning: [])))

          expect(described_class.check(over_budget_page, :page).passed).to eq(true)
        end

        it "still blocks adding another image to a live over-budget page" do
          over_budget_page.save!(validate: false)
          extra = ContentModeration::ContentExtractor::MAX_PAGE_IMAGE_URLS + 2
          over_budget_page.custom_html = over_budget_html + %(<img src="https://cdn.example.com/#{extra}.png">)

          expect(ContentModeration::Strategies::ClassifierStrategy).not_to receive(:new)

          result = described_class.check(over_budget_page, :page)
          expect(result.passed).to eq(false)
          expect(result.reasons.first).to start_with(described_class::TOO_MANY_IMAGES_REASON_PREFIX)
        end

        it "counts images painted through nested CSS toward the budget" do
          count = ContentModeration::ContentExtractor::MAX_PAGE_IMAGE_URLS + 1
          nested_css = (1..count).map do |n|
            %(.card#{n} { --img#{n}: url("https://cdn.example.com/#{n}.png"); & .hero { background-image: var(--img#{n}) } })
          end.join("\n")
          nested_page = Page.new(pageable: seller, slug: "nested", title: "Nested", custom_html: "<style>#{nested_css}</style>")

          expect(ContentModeration::Strategies::ClassifierStrategy).not_to receive(:new)

          expect(described_class.check(nested_page, :page).passed).to eq(false)
        end

        it "moderates a page that sits exactly at the limit" do
          at_limit = (1..ContentModeration::ContentExtractor::MAX_PAGE_IMAGE_URLS)
                       .map { |n| %(<img src="https://cdn.example.com/#{n}.png">) }.join

          expect(described_class.check(Page.new(pageable: seller, custom_html: at_limit), :page).passed).to eq(true)
        end
      end
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
      # Enough abandoned rows that any fixed-size slice of the file list would
      # have left the genuine file out.
      let(:abandoned_upload_count) { 8 }

      # Only `only` is really in storage; every other file's lookup says missing.
      # Pass `only: nil` for a listing where nothing was ever really uploaded.
      def stub_storage_presence(only:)
        allow_any_instance_of(ProductFile).to receive(:s3_object) do |file|
          double("s3_object", exists?: only.present? && file.id == only.id)
        end
      end

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
        product.product_files << uploaded_file
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

      # A spammer can produce any of these states for free, so they don't count
      # as a deliverable for the purpose of letting a spam flag through — even
      # though the off-platform-fulfillment preset treats them as "not empty".
      it "still blocks when the only content page has a title and an empty body" do
        create(:rich_content, entity: product, title: "Chapter one", description: [{ "type" => "paragraph" }])

        result = described_class.check(product.reload, :product)

        expect(result.passed).to eq(false)
        expect(result.reasons).to eq(["spam: reads like a sales pitch and lacks coherent prose"])
      end

      # These pages look non-empty in the editor, but every block in them renders
      # its content from somewhere else and that somewhere else is empty, so the
      # buyer opens the page and sees nothing.
      it "still blocks when the only content page is a posts block and the seller has published no posts" do
        create(:rich_content, entity: product, title: nil, description: [{ "type" => "posts" }])

        result = described_class.check(product.reload, :product)

        expect(result.passed).to eq(false)
        expect(result.reasons).to eq(["spam: reads like a sales pitch and lacks coherent prose"])
      end

      it "still blocks when the only content page embeds a file that isn't there" do
        create(:rich_content, entity: product, title: nil, description: [
                 { "type" => "fileEmbedGroup", "content" => [{ "type" => "fileEmbed", "attrs" => { "id" => "nonexistent" } }] }
               ])

        expect(described_class.check(product.reload, :product).passed).to eq(false)
      end

      it "still blocks when the only content page recommends other listings" do
        create(:rich_content, entity: product, title: nil, description: [{ "type" => "moreLikeThis" }])

        expect(described_class.check(product.reload, :product).passed).to eq(false)
      end

      it "still blocks when the only content page is a review the buyer may not even be able to load" do
        create(:rich_content, entity: product, title: nil, description: [{ "type" => "reviewCard", "attrs" => { "reviewId" => "missing" } }])

        expect(described_class.check(product.reload, :product).passed).to eq(false)
      end

      it "still blocks when the only content page advertises another product" do
        create(:rich_content, entity: product, title: nil, description: [
                 { "type" => "upsellCard", "attrs" => { "id" => "missing", "productId" => "missing" } }
               ])

        expect(described_class.check(product.reload, :product).passed).to eq(false)
      end

      it "still blocks when the only content page asks the buyer to fill in a form" do
        create(:rich_content, entity: product, title: nil, description: [
                 { "type" => "shortAnswer", "attrs" => { "label" => "Your name" } },
                 { "type" => "fileUpload" }
               ])

        expect(described_class.check(product.reload, :product).passed).to eq(false)
      end

      # The file itself is the deliverable, so an attached file publishes whether
      # or not the seller also embedded it in a page.
      it "publishes when a page embeds a file the seller actually uploaded" do
        product_file = uploaded_file
        product.product_files << product_file
        product.save!
        create(:rich_content, entity: product, title: nil, description: [
                 { "type" => "fileEmbed", "attrs" => { "id" => product_file.external_id } }
               ])

        expect(described_class.check(product.reload, :product).passed).to eq(true)
      end

      # An upload that never finished still leaves an alive ProductFile row
      # pointing at a storage key nothing was written to, and nothing deletes
      # that row afterwards. The row must not stand in for a deliverable.
      it "still blocks when the only attached file's upload never finished" do
        stub_missing_storage_objects
        product.product_files << create(:product_file, analyze_completed: false)
        product.save!

        expect(described_class.check(product.reload, :product).passed).to eq(false)
      end

      it "still blocks when the only file on a tier is an unfinished upload" do
        stub_missing_storage_objects
        membership = create(:membership_product, user: seller, name: "Members", description: "Join us")
        tier = membership.tiers.first
        tier.product_files << create(:product_file, link: membership, analyze_completed: false)
        tier.save!

        expect(described_class.check(membership.reload, :product).passed).to eq(false)
      end

      it "still blocks when the attached file has been purged from storage" do
        product.product_files << create(:product_file, analyze_completed: true, deleted_from_cdn_at: Time.current)
        product.save!

        expect(described_class.check(product.reload, :product).passed).to eq(false)
      end

      it "publishes when the attached file is an external link, which needs nothing in storage" do
        product.product_files << create(:external_link)
        product.save!

        expect(described_class.check(product.reload, :product).passed).to eq(true)
      end

      # Storage being unreachable is our problem, not evidence the seller
      # attached nothing.
      it "publishes when storage can't be reached to confirm the file" do
        allow_any_instance_of(ProductFile).to receive(:s3_object)
          .and_raise(Aws::S3::Errors::ServiceUnavailable.new(nil, "unavailable"))
        product.product_files << create(:product_file, analyze_completed: false)
        product.save!

        expect(described_class.check(product.reload, :product).passed).to eq(true)
      end

      # A seller who abandoned a run of uploads and then finished a real one must
      # not be told their listing delivers nothing just because the dead rows
      # outnumber what we'd previously pay to look up.
      it "publishes when a just-uploaded file sits behind a pile of abandoned uploads" do
        abandoned = Array.new(abandoned_upload_count) do |index|
          create(:product_file, analyze_completed: false, position: index)
        end
        # Created last and ordered last, so the seller's own `position` ordering
        # buries it and only creation order picks it out first.
        finished = create(:product_file, analyze_completed: false, position: abandoned.size)
        stub_storage_presence(only: finished)
        (abandoned + [finished]).each { product.product_files << _1 }
        product.save!

        expect(described_class.check(product.reload, :product).passed).to eq(true)
      end

      # The other way a file goes unanalyzed forever is that it really was stored
      # but analysis never succeeded — retries ran out, or it's a video whose
      # metadata can't be read. That leaves a real deliverable as the oldest row
      # on a listing that has collected abandoned uploads since.
      it "publishes when a long-stored unanalyzed file sits in front of a pile of abandoned uploads" do
        stored = create(:product_file, analyze_completed: false, position: 1)
        abandoned = Array.new(abandoned_upload_count) do |index|
          create(:product_file, analyze_completed: false, position: index + 2)
        end
        stub_storage_presence(only: stored)
        ([stored] + abandoned).each { product.product_files << _1 }
        product.save!

        expect(described_class.check(product.reload, :product).passed).to eq(true)
      end

      # The case no fixed slice of the list can reach: the real file is neither
      # the newest nor the oldest row, because abandoned uploads surround it on
      # both sides. Every file has to stay eligible for a lookup.
      it "publishes when the stored file sits between two runs of abandoned uploads" do
        older = Array.new(abandoned_upload_count) do |index|
          create(:product_file, analyze_completed: false, position: index)
        end
        stored = create(:product_file, analyze_completed: false, position: older.size)
        newer = Array.new(abandoned_upload_count) do |index|
          create(:product_file, analyze_completed: false, position: older.size + 1 + index)
        end
        stub_storage_presence(only: stored)
        (older + [stored] + newer).each { product.product_files << _1 }
        product.save!

        expect(described_class.check(product.reload, :product).passed).to eq(true)
      end

      # The save API takes each file's storage URL from the client, so submitting
      # a long list of never-uploaded rows costs a caller nothing. Attaching many
      # of them must not buy what attaching one doesn't.
      it "still blocks when many attached files are all unfinished uploads" do
        stub_storage_presence(only: nil)
        (abandoned_upload_count + 3).times do
          product.product_files << create(:product_file, analyze_completed: false)
        end
        product.save!

        expect(described_class.check(product.reload, :product).passed).to eq(false)
      end

      # The list length is up to the caller, so a save must not turn into an
      # unbounded run of requests to storage. Once the time budget is gone we
      # stop asking, however many rows are left.
      it "stops checking storage once the time budget is spent" do
        storage_lookups = 0
        # Each lookup burns the whole budget, so the very next one is not made.
        allow_any_instance_of(ProductFile).to receive(:s3_object) do
          storage_lookups += 1
          sleep(described_class::STORAGE_CHECK_TIME_BUDGET_SECONDS)
          double("s3_object", exists?: false)
        end
        5.times { product.product_files << create(:product_file, analyze_completed: false) }
        product.save!

        expect(described_class.check(product.reload, :product).passed).to eq(false)
        expect(storage_lookups).to eq(1)
      end

      # A membership carries a separate file list per tier, so the budget has to
      # cover the whole save rather than being handed out once per list —
      # otherwise a product's worst case multiplies by how many tiers it has.
      it "spends one budget across the product and all of its variants" do
        storage_lookups = 0
        # The first lookup burns the whole budget, so nothing after it is asked,
        # in this tier or any later one.
        allow_any_instance_of(ProductFile).to receive(:s3_object) do
          storage_lookups += 1
          sleep(described_class::STORAGE_CHECK_TIME_BUDGET_SECONDS)
          double("s3_object", exists?: false)
        end
        membership = create(:membership_product_with_preset_tiered_pricing, user: seller)
        membership.tiers.each do |tier|
          2.times { tier.product_files << create(:product_file, link: membership, analyze_completed: false) }
          tier.save!
        end

        expect(described_class.check(membership.reload, :product).passed).to eq(false)
        expect(storage_lookups).to eq(1)
      end

      # Running out of time is one event for the whole save, so it has to be
      # reported once with the total left unchecked. A line per tier would both
      # flood the log and leave nobody able to see how many files that was.
      it "logs a single warning naming the total left unchecked across all tiers" do
        allow_any_instance_of(ProductFile).to receive(:s3_object) do
          sleep(described_class::STORAGE_CHECK_TIME_BUDGET_SECONDS)
          double("s3_object", exists?: false)
        end
        membership = create(:membership_product_with_preset_tiered_pricing, user: seller)
        membership.tiers.each do |tier|
          2.times { tier.product_files << create(:product_file, link: membership, analyze_completed: false) }
          tier.save!
        end
        membership.reload
        # Distinct files, not lookups: a file attached to a tier is also in the
        # product's own list, so both walks reach it and it must be reported once.
        # Everything but the single lookup that burned the budget went unchecked.
        unchecked = membership.alive_product_files.count - 1

        warnings = []
        allow(Rails.logger).to receive(:warn) { |message| warnings << message }

        expect(described_class.check(membership, :product).passed).to eq(false)

        budget_warnings = warnings.grep(/storage check budget spent/)
        expect(budget_warnings.size).to eq(1)
        expect(budget_warnings.first).to include("#{unchecked} unverifiable file(s) left unchecked")
      end

      # Running out of time on the files is only worth reporting if the product
      # ended up with nothing. A content page delivers on its own, so that save
      # passes and must not carry a failure-shaped warning about files nobody
      # needed to look at.
      it "does not warn about a spent budget when the product passes on its page content" do
        allow_any_instance_of(ProductFile).to receive(:s3_object) do
          sleep(described_class::STORAGE_CHECK_TIME_BUDGET_SECONDS)
          double("s3_object", exists?: false)
        end
        3.times { product.product_files << create(:product_file, analyze_completed: false) }
        create(:rich_content, entity: product, description: [
                 { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Here is the course." }] }
               ])
        product.save!

        warnings = []
        allow(Rails.logger).to receive(:warn) { |message| warnings << message }

        expect(described_class.check(product.reload, :product).passed).to eq(true)
        expect(warnings.grep(/storage check budget spent/)).to be_empty
      end

      # A file that finished analyzing is answered from its own row, so a real
      # deliverable sitting behind a pile of unfinished uploads still publishes
      # and still costs nothing to confirm.
      it "publishes without checking storage when one of many attached files has been analyzed" do
        expect_any_instance_of(ProductFile).not_to receive(:s3_object)
        abandoned_upload_count.times do
          product.product_files << create(:product_file, analyze_completed: false)
        end
        product.product_files << uploaded_file
        product.save!

        expect(described_class.check(product.reload, :product).passed).to eq(true)
      end

      it "still blocks a bundle with no products in it" do
        bundle = create(:product, user: seller, is_bundle: true, name: "Bundle", description: "Everything you need")

        expect(described_class.check(bundle.reload, :product).passed).to eq(false)
      end

      it "publishes a bundle that actually contains products" do
        bundle = create(:product, user: seller, is_bundle: true, name: "Bundle", description: "Everything you need")
        create(:bundle_product, bundle:, product: create(:product, user: seller))

        expect(described_class.check(bundle.reload, :product).passed).to eq(true)
      end

      it "still blocks a coffee listing, which has no deliverable by design" do
        coffee = create(:coffee_product, name: "Buy me a coffee", description: "Support my work")

        expect(described_class.check(coffee.reload, :product).passed).to eq(false)
      end

      it "still blocks when the only integration is scheduling plumbing rather than the deliverable" do
        scheduled = create(:product, user: seller, name: "Session", description: "Book a session", active_integrations: [create(:zoom_integration)])

        expect(described_class.check(scheduled.reload, :product).passed).to eq(false)
      end

      it "publishes a commission, where the deliverable is work the seller performs" do
        commission = create(:commission_product, name: "Custom art", description: "I will draw you")

        expect(described_class.check(commission.reload, :product).passed).to eq(true)
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
        product.product_files << uploaded_file
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

      # Whether a listing delivers anything only matters for deciding if a spam
      # flag should stop blocking. With nothing flagged there is no such
      # decision to make, so the save must not go walking the seller's files:
      # it costs storage lookups that change no outcome, and running out of
      # time on them would write a rejection-shaped warning onto a save that
      # published fine.
      it "does not check storage or warn about a spent budget when nothing was flagged" do
        expect_any_instance_of(ProductFile).not_to receive(:s3_object)
        3.times { product.product_files << create(:product_file, analyze_completed: false) }
        product.save!

        warnings = []
        allow(Rails.logger).to receive(:warn) { |message| warnings << message }

        expect(described_class.check(product.reload, :product).passed).to eq(true)
        expect(warnings.grep(/storage check budget spent/)).to be_empty
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

    it "tells the seller to change the image, not to retry, when the block is an unreviewable payload" do
      # The input is static, so the transient "try again in a few minutes" copy
      # sent sellers into an infinite retry loop (gumroad-private#1695).
      message = described_class.seller_message(
        [ContentModeration::Strategies::ClassifierStrategy::UNSUPPORTED_IMAGE_REASON],
        "page"
      )

      expect(message).to eq(
        "This page includes an image we can’t review, because the format is unsupported (such as an SVG data URL) " \
        "or the file is too large. Replace it with a smaller PNG, JPEG, GIF, or WebP and try again."
      )
      expect(message).not_to include("temporary issue")
    end

    it "does not tell a seller whose asset is only oversized to re-encode a format they are already using" do
      # `file_too_large` reaches this branch for a plain PNG on the seller's own
      # CDN (gumroad-private#1728), so copy naming only the format sent them at
      # a property of the file that was never the problem.
      message = described_class.seller_message(
        [ContentModeration::Strategies::ClassifierStrategy::UNSUPPORTED_IMAGE_REASON],
        "page"
      )

      expect(message).to include("too large")
      expect(message).not_to include("inline")
      expect(message).not_to include("Re-encode")
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
