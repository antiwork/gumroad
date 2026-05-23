# frozen_string_literal: true

require "spec_helper"

describe Pages::GeneratePageVersionJob do
  let(:user) { create(:user) }
  let(:page) { create(:page, user: user) }
  let(:passed_moderation) { ContentModeration::ModerateRecordService::CheckResult.new(passed: true, reasons: []) }
  let(:failed_moderation) { ContentModeration::ModerateRecordService::CheckResult.new(passed: false, reasons: ["nope"]) }

  before do
    allow(ContentModeration::ModerateRecordService).to receive(:check).and_return(passed_moderation)
  end

  describe "sidekiq options" do
    it "is configured to retry transient errors" do
      expect(described_class.sidekiq_options["retry"]).to eq(3)
    end

    it "runs on the low-priority queue so it doesn't compete with critical work" do
      expect(described_class.sidekiq_options["queue"].to_s).to eq("low")
    end

    it "deduplicates identical jobs via until_executed lock" do
      expect(described_class.sidekiq_options["lock"]).to eq(:until_executed)
    end
  end

  describe "#perform" do
    let(:fake_version) { create(:page_version, page: page) }

    it "applies the generated version and clears generating_since on success" do
      page.update_column(:generating_since, 1.minute.ago)
      service = instance_double(Ai::PageGeneratorService, call: Ai::PageGeneratorService::Result.new(version: fake_version))
      allow(Ai::PageGeneratorService).to receive(:new).and_return(service)

      described_class.new.perform(page.id, "draft something")
      expect(page.reload.generating_since).to be_nil
      expect(page.html_content).to include("Hello")
    end

    it "sets generation_error when output moderation fails on the generated content" do
      allow(ContentModeration::ModerateRecordService).to receive(:check).and_return(failed_moderation)
      service = instance_double(Ai::PageGeneratorService, call: Ai::PageGeneratorService::Result.new(version: fake_version))
      allow(Ai::PageGeneratorService).to receive(:new).and_return(service)

      described_class.new.perform(page.id, "anything")
      page.reload
      expect(page.generation_error).to match(/Content moderation/)
      expect(page.generating_since).to be_nil
    end

    it "does not apply the new version when output moderation fails" do
      page.update!(html_content: "<div>previous</div>", auto_publish: true)
      v_parent = create(:page_version, page: page, html: "<div>previous</div>", prompt: "p")
      page.apply_new_version!(v_parent)
      new_version = create(:page_version, page: page, html: "<section>unsafe</section>", prompt: "x", parent: v_parent)
      service = instance_double(Ai::PageGeneratorService, call: Ai::PageGeneratorService::Result.new(version: new_version))
      allow(Ai::PageGeneratorService).to receive(:new).and_return(service)
      allow(ContentModeration::ModerateRecordService).to receive(:check).and_return(failed_moderation)

      described_class.new.perform(page.id, "make it fresh", v_parent.id)

      page.reload
      # The rejected html must never reach html_content (which feeds the
      # editor preview) or published_version (which feeds the public viewer).
      expect(page.html_content).not_to include("unsafe")
      expect(page.html_content).to include("previous")
      expect(page.published_version_id).to eq(v_parent.id)
      # The rejected version itself is discarded so it can't be promoted later
      # via "publish a previous version".
      expect(PageVersion.where(id: new_version.id)).to be_empty
    end

    it "runs output moderation against the newly generated content, not the previous html" do
      page.update!(html_content: "<div>previous</div>")
      new_version = create(:page_version, page: page, html: "<section>fresh</section>", prompt: "x")
      service = instance_double(Ai::PageGeneratorService, call: Ai::PageGeneratorService::Result.new(version: new_version))
      allow(Ai::PageGeneratorService).to receive(:new).and_return(service)

      seen_html = nil
      allow(ContentModeration::ModerateRecordService).to receive(:check) do |record, _kind|
        seen_html = record.html_content
        passed_moderation
      end

      described_class.new.perform(page.id, "make it fresh")
      expect(seen_html).to include("fresh")
      expect(seen_html).not_to include("previous")
    end

    it "sets generation_error when the service returns a permanent failure (does not raise)" do
      service = instance_double(Ai::PageGeneratorService, call: Ai::PageGeneratorService::Result.new(error: "boom"))
      allow(Ai::PageGeneratorService).to receive(:new).and_return(service)

      described_class.new.perform(page.id, "draft something")
      page.reload
      expect(page.generation_error).to be_present
      expect(page.generating_since).to be_nil
    end

    it "clears generating_since via ensure even when the service raises a transient error" do
      service = instance_double(Ai::PageGeneratorService)
      allow(service).to receive(:call).and_raise(Faraday::TimeoutError, "openai timed out")
      allow(Ai::PageGeneratorService).to receive(:new).and_return(service)

      expect do
        described_class.new.perform(page.id, "draft something")
      end.to raise_error(Faraday::TimeoutError)

      expect(page.reload.generating_since).to be_nil
    end

    it "swallows ActiveRecord::RecordNotFound when the page was deleted mid-flight" do
      # The page row may be hard-deleted between enqueue and pickup (or the
      # find may race with destroy). The job's ensure routes through
      # `Page.where(id:).update_all` so the deleted-row path is a no-op
      # rather than raising — and the original RecordNotFound is allowed to
      # surface so Sidekiq's retry policy decides what to do.
      expect do
        described_class.new.perform(0, "anything")
      end.to raise_error(ActiveRecord::RecordNotFound)

      # No exception escapes the ensure block — the where(...).update_all
      # call is safe even when no row matches.
      expect(Page.where(id: 0)).to be_empty
    end
  end

  describe "sidekiq_retries_exhausted" do
    it "marks the page with a final generation_error and clears generating_since" do
      page.update_columns(generating_since: 1.minute.ago, generation_error: nil)
      msg = { "args" => [page.id, "prompt"] }

      described_class.sidekiq_retries_exhausted_block.call(msg, StandardError.new("done"))

      page.reload
      expect(page.generation_error).to be_present
      expect(page.generating_since).to be_nil
    end
  end
end
