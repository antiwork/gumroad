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

    describe "save contract (Product::SaveContract)" do
      # A REAL token for the product's current state, not a placeholder: an
      # invented string is never fresh, so under the contract it authorises no
      # deletions at all — a spec built on one passes while proving nothing.
      def current_revision
        Product::EditorRevision.current(product.reload)
      end

      def contract_for(contract_params)
        # Mirrors the controller wiring (LinksController#product_save_contract):
        # the contract is handed plain, deeply-symbolized hashes.
        Product::SaveContract.new(params: contract_params.deep_symbolize_keys, product:)
      end

      def process(files_params:, contract:)
        described_class.new(resource: product, files_params:, content:, contract:).process
      end

      context "when the :product_editor_save_contract flag is off" do
        it "preserves today's behaviour: absent public_files still schedules everything and strips embeds" do
          contract = contract_for({ editor_revision: current_revision })
          expect(contract.enforced?).to eq(false)

          result = process(files_params: nil, contract:)

          expect(public_file1.reload.scheduled_for_deletion_at).to be_present
          expect(public_file2.reload.scheduled_for_deletion_at).to be_present
          expect(result).not_to include("public-file-embed")
        end
      end

      context "when the :product_editor_save_contract flag is on" do
        # Scoped deactivation, NOT `Feature.deactivate(...)`. Flipper is backed by
        # Redis with no per-worker namespace (config/initializers/feature_toggle.rb),
        # so a global deactivate in an after-hook clears the flag for every other
        # spec process sharing that Redis — which made a sibling run fail with
        # unrelated errors while this suite was green in isolation.
        before { Feature.activate_user(:product_editor_save_contract, seller) }
        after { Feature.deactivate_user(:product_editor_save_contract, seller) }

        it "does not schedule anything or strip embeds when public_files is absent" do
          contract = contract_for({ editor_revision: current_revision })

          result = process(files_params: nil, contract:)

          expect(public_file1.reload.scheduled_for_deletion_at).to be_nil
          expect(public_file2.reload.scheduled_for_deletion_at).to be_nil
          expect(result).to eq(content)
        end

        it "does not schedule anything or strip embeds when public_files is []" do
          contract = contract_for({ public_files: [], editor_revision: current_revision })

          result = process(files_params: [], contract:)

          expect(public_file1.reload.scheduled_for_deletion_at).to be_nil
          expect(public_file2.reload.scheduled_for_deletion_at).to be_nil
          expect(result).to eq(content)
        end

        it "schedules exactly the explicitly deleted ids and strips only their embeds" do
          files_params = [
            { "id" => public_file1.public_id, "name" => "Audio 1", "status" => { "type" => "saved" } }
          ]
          contract = contract_for(
            {
              public_files: files_params,
              editor_revision: current_revision,
              deletion_operations: { deleted_ids: { public_files: [public_file2.public_id] } },
            }
          )

          result = process(files_params:, contract:)

          expect(public_file1.reload.scheduled_for_deletion_at).to be_nil
          expect(public_file2.reload.scheduled_for_deletion_at).to be_within(5.seconds).of(10.days.from_now)
          expect(result).to include(public_file1.public_id)
          expect(result).not_to include(public_file2.public_id)
        end

        it "does not schedule a file that was merely omitted from a submitted payload" do
          # The exact bug the contract removes: file2 is not in files_params,
          # but nothing explicitly asked to delete it.
          files_params = [
            { "id" => public_file1.public_id, "name" => "Audio 1", "status" => { "type" => "saved" } }
          ]
          contract = contract_for({ public_files: files_params, editor_revision: current_revision })

          result = process(files_params:, contract:)

          expect(public_file1.reload.scheduled_for_deletion_at).to be_nil
          expect(public_file2.reload.scheduled_for_deletion_at).to be_nil
          expect(result).to include(public_file1.public_id)
          expect(result).to include(public_file2.public_id)
        end

        it "ignores deleted_ids when the save carries no editor_revision (write-only save)" do
          contract = contract_for(
            { deletion_operations: { deleted_ids: { public_files: [public_file2.public_id] } } }
          )

          result = process(files_params: nil, contract:)

          expect(public_file1.reload.scheduled_for_deletion_at).to be_nil
          expect(public_file2.reload.scheduled_for_deletion_at).to be_nil
          expect(result).to eq(content)
        end

        it "schedules everything on an explicit clear-all" do
          contract = contract_for(
            {
              editor_revision: current_revision,
              deletion_operations: { cleared_collections: ["public_files"] },
            }
          )

          result = process(files_params: nil, contract:)

          expect(public_file1.reload.scheduled_for_deletion_at).to be_present
          expect(public_file2.reload.scheduled_for_deletion_at).to be_present
          expect(result).not_to include("public-file-embed")
        end
      end
    end
  end
end
