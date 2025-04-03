# frozen_string_literal: true

require "spec_helper"

describe SavePublicFilesService do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let!(:public_file1) { create(:public_file, :with_audio, resource: product, display_name: "Audio 1") }
  let!(:public_file2) { create(:public_file, :with_audio, resource: product, display_name: "Audio 2") }
  let(:content) do
    <<~HTML
      <p>Some text</p>
      <public-file-embed id="#{public_file1.public_id}"></public-file-embed>
      <p>Hello world!</p>
      <public-file-embed id="#{public_file2.public_id}"></public-file-embed>
      <p>More text</p>
    HTML
  end

  describe "#process" do
    it "updates existing files and returns cleaned content" do
      files_params = [
        { "id" => public_file1.public_id, "name" => "Updated Audio 1", "status" => { "type" => "saved" } },
        { "id" => public_file2.public_id, "name" => "", "status" => { "type" => "saved" } },
        { "id" => "blob:http://example.com/audio.mp3", "name" => "Audio 3", "status" => { "type" => "uploading" } }
      ]
      service = described_class.new(resource: product, files_params:, content:)

      result = service.process

      expect(public_file1.reload.attributes.values_at("display_name", "scheduled_for_deletion_at")).to eq(["Updated Audio 1", nil])
      expect(public_file2.reload.attributes.values_at("display_name", "scheduled_for_deletion_at")).to eq(["Untitled", nil])
      expect(product.public_files.alive.count).to eq(2)
      expect(result).to eq(content)
    end

    it "schedules unused files for deletion" do
      unused_file = create(:public_file, :with_audio, resource: product)
      files_params = [
        { "id" => public_file1.public_id, "name" => "Audio 1", "status" => { "type" => "saved" } }
      ]
      service = described_class.new(resource: product, files_params:, content:)

      service.process

      expect(product.public_files.alive.count).to eq(3)
      expect(unused_file.reload.scheduled_for_deletion_at).to be_within(5.seconds).of(10.days.from_now)
      expect(public_file1.reload.scheduled_for_deletion_at).to be_nil
      expect(public_file2.reload.scheduled_for_deletion_at).to be_within(5.seconds).of(10.days.from_now)
    end

    it "removes invalid file embeds from content" do
      content_with_invalid_embeds = <<~HTML
        <p>Some text</p>
        <public-file-embed id="#{public_file1.public_id}"></public-file-embed>
        <p>Middle text</p>
        <public-file-embed id="nonexistent"></public-file-embed>
        <public-file-embed></public-file-embed>
        <p>More text</p>
      HTML
      files_params = [
        { "id" => public_file1.public_id, "name" => "Audio 1", "status" => { "type" => "saved" } },
        { "id" => public_file2.public_id, "name" => "Audio 2", "status" => { "type" => "saved" } },
      ]
      service = described_class.new(resource: product, files_params:, content: content_with_invalid_embeds)

      result = service.process

      expect(result).to eq(<<~HTML
        <p>Some text</p>
        <public-file-embed id="#{public_file1.public_id}"></public-file-embed>
        <p>Middle text</p>


        <p>More text</p>
      HTML
      )
      expect(product.public_files.alive.count).to eq(2)
      expect(public_file1.reload.scheduled_for_deletion_at).to be_nil
      expect(public_file2.reload.scheduled_for_deletion_at).to be_within(5.seconds).of(10.days.from_now)
    end

    it "handles empty files_params" do
      service = described_class.new(resource: product, files_params: nil, content:)

      result = service.process

      expect(result).to eq(<<~HTML
        <p>Some text</p>

        <p>Hello world!</p>

        <p>More text</p>
      HTML
      )
      expect(public_file1.reload.scheduled_for_deletion_at).to be_present
      expect(public_file2.reload.scheduled_for_deletion_at).to be_present
    end

    it "handles empty content" do
      files_params = [
        { "id" => public_file1.public_id, "status" => { "type" => "saved" } }
      ]
      service = described_class.new(resource: product, files_params:, content: nil)

      result = service.process

      expect(result).to eq("")
      expect(public_file1.reload.scheduled_for_deletion_at).to be_present
      expect(public_file2.reload.scheduled_for_deletion_at).to be_present
    end

    it "rolls back on error" do
      files_params = [
        { "id" => public_file1.public_id, "name" => "Updated Audio 1", "status" => { "type" => "saved" } }
      ]
      service = described_class.new(resource: product, files_params:, content:)
      allow_any_instance_of(PublicFile).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new)

      expect do
        service.process
      end.to raise_error(ActiveRecord::RecordInvalid)

      expect(public_file1.reload.display_name).to eq("Audio 1")
      expect(public_file1.reload.scheduled_for_deletion_at).to be_nil
      expect(public_file2.reload.scheduled_for_deletion_at).to be_nil
    end
  end
end
