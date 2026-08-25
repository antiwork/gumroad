# frozen_string_literal: true

require "spec_helper"

describe SaveFilesService do
  before do
    @product = create(:product)
  end

  subject(:service) { described_class }

  describe ".perform" do
    context "when params is empty" do
      it "does not raise an error" do
        service.perform(@product, {})
      end
    end

    it "updates files" do
      file_1 = create(:product_file, link: @product, description: "pencil", url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png")
      file_2 = create(:product_file, link: @product, description: "manual", url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf")

      @product.product_files << file_1
      @product.product_files << file_2

      service.perform(@product, {
                        files: [{
                          external_id: file_2.external_id,
                          url: file_2.url,
                          display_name: "new manual",
                          description: "new manual description",
                          position: 2
                        },
                                {
                                  external_id: SecureRandom.uuid,
                                  url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/book.pdf",
                                  display_name: "new book",
                                  description: "new book description",
                                  position: 1
                                },
                                {
                                  external_id: SecureRandom.uuid,
                                  url: "https://www.gumroad.com",
                                  display_name: "new link",
                                  description: "new link description",
                                  extension: "URL",
                                  position: 0
                                }]
                      })

      expect(@product.product_files.count).to eq(4)
      expect(@product.product_files.alive.count).to eq(3)

      manual_file = @product.product_files.alive[0].reload
      expect(manual_file.display_name).to eq("new manual")
      expect(manual_file.description).to eq("new manual description")
      expect(manual_file.position).to eq(2)

      book_file = @product.product_files.alive[1].reload
      expect(book_file.url).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/book.pdf")
      expect(book_file.unique_url_identifier).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/book.pdf")
      expect(book_file.display_name).to eq("new book")
      expect(book_file.description).to eq("new book description")
      expect(book_file.position).to eq(1)

      link_file = @product.product_files.alive[2].reload
      expect(link_file.url).to eq("https://www.gumroad.com")
      expect(link_file.unique_url_identifier).to eq("https://www.gumroad.com")
      expect(link_file.display_name).to eq("new link")
      expect(link_file.description).to eq("new link description")
      expect(link_file.external_link?).to eq(true)
      expect(link_file.position).to eq(0)

      pencil_file = @product.product_files[0].reload
      expect(pencil_file.deleted?).to eq(true)
    end

    it "updates subtitles" do
      @product.product_files << create(:streamable_video)
      @product.product_files << create(:listenable_audio)
      @product.product_files << create(:non_streamable_video)
      @product.product_files << create(:readable_document)
      video_1 = @product.product_files.first
      video_2 = @product.product_files.third
      video_1.subtitle_files << create(:subtitle_file)
      video_2.subtitle_files << create(:subtitle_file)
      video_2.subtitle_files << create(:subtitle_file)

      service.perform(@product, {
                        files: [{
                          external_id: @product.product_files.first.external_id,
                          url: @product.product_files.first.url,
                          subtitle_files: [{
                            "url" => "https://newurl1.srt",
                            "language" => "new-language1"
                          }]
                        },
                                {
                                  external_id: @product.product_files.second.external_id,
                                  url: @product.product_files.second.url
                                },
                                {
                                  external_id: @product.product_files.third.external_id,
                                  url: @product.product_files.third.url,
                                  subtitle_files: [{
                                    "url" => "https://newurl2.srt",
                                    "language" => "new-language2"
                                  }]
                                },
                                {
                                  external_id: @product.product_files.fourth.external_id,
                                  url: @product.product_files.fourth.url
                                },
                        ]
                      })

      expect(@product.product_files.count).to eq(4)

      video_1_subtitles = video_1.subtitle_files.reload.alive
      expect(video_1_subtitles.count).to eq(1)
      expect(video_1_subtitles.first.url).to eq("https://newurl1.srt")
      expect(video_1_subtitles.first.language).to eq("new-language1")

      video_2_subtitles = video_2.subtitle_files.reload.alive
      expect(video_2_subtitles.count).to eq(1)
      expect(video_2_subtitles.first.url).to eq("https://newurl2.srt")
      expect(video_2_subtitles.first.language).to eq("new-language2")
    end

    it "maps 'name' param to 'display_name' for product files" do
      file = create(:product_file, link: @product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png")
      @product.product_files << file

      service.perform(@product, {
                        files: [{
                          external_id: file.external_id,
                          url: file.url,
                          name: "renamed file",
                        }]
                      })

      expect(file.reload.display_name).to eq("renamed file")
    end

    it "prefers 'display_name' over 'name' when both are provided" do
      file = create(:product_file, link: @product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png")
      @product.product_files << file

      service.perform(@product, {
                        files: [{
                          external_id: file.external_id,
                          url: file.url,
                          name: "from name",
                          display_name: "from display_name",
                        }]
                      })

      expect(file.reload.display_name).to eq("from display_name")
    end

    it "maps 'file_name' param to 'display_name' for product files round trips" do
      file = create(:product_file, link: @product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png")
      @product.product_files << file

      service.perform(@product, {
                        files: [{
                          external_id: file.external_id,
                          url: file.url,
                          file_name: "renamed file",
                        }]
                      })

      expect(file.reload.display_name).to eq("renamed file")
    end

    it "is a no-op for serializer-only keys a v2 GET->PUT round-trip echoes (file_size etc.)" do
      file = create(:product_file, link: @product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png", size: 1234)
      @product.product_files << file

      service.perform(@product, {
                        files: [{
                          external_id: file.external_id,
                          url: file.url,
                          file_name: "renamed file",
                          file_size: 999_999,
                          extension: "png",
                          is_pdf: false,
                          is_streamable: false,
                          attached_product_name: @product.name,
                          status: { type: "saved" },
                        }]
                      })

      file.reload
      expect(file.size).to eq(1234)
      expect(file.display_name).to eq("renamed file")
    end

    it "drops serializer-only keys from ActionController::Parameters (editor PUT string keys)" do
      file = create(:product_file, link: @product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png", size: 1234)
      @product.product_files << file

      service.perform(@product, ActionController::Parameters.new(
                                  files: [{
                                    "external_id" => file.external_id,
                                    "url" => file.url,
                                    "file_name" => "renamed file",
                                    "file_size" => 999_999,
                                    "extension" => "png",
                                    "is_pdf" => false,
                                    "is_streamable" => false,
                                    "attached_product_name" => @product.name,
                                    "status" => { "type" => "saved" },
                                  }]
                                ).permit!)

      file.reload
      expect(file.size).to eq(1234)
      expect(file.display_name).to eq("renamed file")
    end

    it "still applies writable flag-backed attributes (stream_only) alongside serializer echoes" do
      video = create(:streamable_video, link: @product, size: 4321)
      @product.product_files << video

      service.perform(@product, {
                        files: [{
                          external_id: video.external_id,
                          url: video.url,
                          file_size: video.size,
                          stream_only: true,
                        }]
                      })

      expect(video.reload.stream_only?).to eq(true)
    end

    it "supports `files` param as an array" do
      installment = create(:installment, workflow: create(:workflow))
      file1 = create(:product_file, installment:, link: nil, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png")
      file2 = create(:product_file, installment:, link: nil, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf")
      service.perform(installment, {
                        files: [
                          {
                            external_id: file1.external_id,
                            url: file2.url,
                            position: 1,
                            stream_only: false,
                            subtitle_files: [],
                          },
                          {
                            external_id: file2.external_id,
                            url: file2.url,
                            position: 2,
                            stream_only: false,
                            subtitle_files: [],
                          },
                        ]
                      })
      expect(installment.product_files.alive.count).to eq(2)
      expect(installment.product_files.pluck(:id, :position, :url)).to match_array([[file1.id, 1, file2.url], [file2.id, 2, file2.url]])
    end

    describe "editor save contract (Product::SaveContract)" do
      let!(:file_1) { create(:product_file, link: @product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png") }
      let!(:file_2) { create(:product_file, link: @product, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf") }

      # A REAL token for the product's current state, not a placeholder: an
      # invented string is never fresh, so under the contract it authorises no
      # deletions at all — a spec built on one passes while proving nothing.
      def current_revision
        Product::EditorRevision.current(@product.reload)
      end

      def contract_for(params)
        # Mirrors the controller wiring (LinksController#product_save_contract):
        # the contract is handed plain, deeply-symbolized hashes because
        # Parameters#to_unsafe_h.symbolize_keys re-stringifies nested keys,
        # breaking the contract's symbol-keyed dig into deletion_operations.
        Product::SaveContract.new(params: params.deep_symbolize_keys, product: @product)
      end

      context "when the flag is OFF" do
        it "preserves old behaviour: [] wipes all alive files even with a contract present" do
          contract = contract_for(files: [], editor_revision: current_revision)
          expect(contract.enforced?).to eq(false)

          service.perform(@product, { files: [] }, contract:)

          expect(@product.product_files.alive.count).to eq(0)
        end

        it "preserves old behaviour: absent files key wipes all alive files" do
          service.perform(@product, {}, contract: contract_for({}))

          expect(@product.product_files.alive.count).to eq(0)
        end
      end

      context "when the flag is ON" do
        # Scoped deactivation, NOT `Feature.deactivate(...)`. Flipper is backed by
        # Redis with no per-worker namespace (config/initializers/feature_toggle.rb),
        # so a global deactivate in an after-hook clears the flag for every other
        # spec process sharing that Redis — which made a sibling run fail with
        # unrelated errors while this suite was green in isolation.
        before { Feature.activate_user(:product_editor_save_contract, @product.user) }
        after { Feature.deactivate_user(:product_editor_save_contract, @product.user) }

        it "does not delete anything when the files key is absent" do
          service.perform(@product, {}, contract: contract_for(editor_revision: current_revision))

          expect(@product.product_files.alive.count).to eq(2)
        end

        it "does not delete anything when files is []" do
          service.perform(@product, { files: [] }, contract: contract_for(files: [], editor_revision: current_revision))

          expect(@product.product_files.alive.count).to eq(2)
        end

        it "does not delete files omitted from a submitted payload, but still applies updates and creates" do
          files_params = [
            { external_id: file_1.external_id, url: file_1.url, display_name: "renamed pencil" },
            { external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/book.pdf", display_name: "new book" },
          ]
          # file_2 is omitted — under the contract that is "no statement", not "delete me".
          service.perform(@product, { files: files_params }, contract: contract_for(files: files_params, editor_revision: current_revision))

          expect(@product.product_files.alive.count).to eq(3)
          expect(file_1.reload.display_name).to eq("renamed pencil")
          expect(file_2.reload.deleted?).to eq(false)
          expect(@product.product_files.alive.map(&:display_name)).to include("new book")
        end

        it "deletes exactly the explicit deleted_ids" do
          contract = contract_for(
            files: [],
            editor_revision: current_revision,
            deletion_operations: { deleted_ids: { files: [file_1.external_id] } }
          )

          service.perform(@product, { files: [] }, contract:)

          expect(file_1.reload.deleted?).to eq(true)
          expect(file_2.reload.deleted?).to eq(false)
        end

        it "deletes everything on an explicit clear-all" do
          contract = contract_for(
            files: [],
            editor_revision: current_revision,
            deletion_operations: { cleared_collections: ["files"] }
          )

          service.perform(@product, { files: [] }, contract:)

          expect(@product.product_files.alive.count).to eq(0)
        end

        it "refuses to delete without an editor_revision (write-only save)" do
          contract = contract_for(
            files: [],
            deletion_operations: { deleted_ids: { files: [file_1.external_id] }, cleared_collections: ["files"] }
          )

          service.perform(@product, { files: [] }, contract:)

          expect(@product.product_files.alive.count).to eq(2)
        end

        it "does not delete files created by the same request via clear-all" do
          new_file_params = [{ external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/book.pdf", display_name: "new book" }]
          contract = contract_for(
            files: new_file_params,
            editor_revision: current_revision,
            deletion_operations: { cleared_collections: ["files"] }
          )

          service.perform(@product, { files: new_file_params }, contract:)

          expect(@product.product_files.alive.map(&:display_name)).to eq(["new book"])
          expect(file_1.reload.deleted?).to eq(true)
          expect(file_2.reload.deleted?).to eq(true)
        end

        it "leaves non-editor callers (no contract passed) on the old behaviour" do
          # Installment/workflow/API v2 call sites construct the service
          # without a contract; the flag being on for the seller must not
          # change them.
          installment = create(:installment, link: @product, seller: @product.user)
          installment_file = create(:product_file, installment:, link: nil, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png")

          service.perform(installment, { files: [] })

          expect(installment_file.reload.deleted?).to eq(true)
        end
      end
    end
  end
end
