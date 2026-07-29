# frozen_string_literal: true

require "spec_helper"

describe RichContent do
  describe "validations" do
    describe "description" do
      context "invalid descriptions" do
        let(:invalid_descriptions) { ["not valid", ["also not valid"], [{ "type" => 2 }]] }

        it "adds error when the description is invalid" do
          invalid_descriptions.each do |invalid_description|
            rich_content = build(:product_rich_content, description: invalid_description)
            expect(rich_content).to be_invalid
            expect(rich_content.errors.full_messages).to eq(["Content is invalid"])
          end
        end
      end

      context "valid descriptions" do
        let(:valid_descriptions) { [[], [{ "type": "text", "text": "Trace" }], [{ "type": "text", "text": "Trace" }, { "type": "text", "marks": [{ "type": "italic" }], "text": "Q" }]] }

        it "does not add errors for valid descriptions" do
          valid_descriptions.each do |valid_description|
            rich_content = build(:product_rich_content, description: valid_description)
            expect(rich_content).to be_valid
          end
        end
      end
    end
  end

  describe "#embedded_product_file_ids_in_order" do
    let(:product) { create(:product) }
    let(:rich_content) { create(:product_rich_content, entity: product) }

    it "returns the ids of the embedded product files in order" do
      file1 = create(:listenable_audio, link: product, position: 0)
      file2 = create(:product_file, link: product, position: 1, created_at: 2.days.ago)
      file3 = create(:readable_document, link: product, position: 2)
      file4 = create(:streamable_video, link: product, position: 3, created_at: 1.day.ago)
      file5 = create(:listenable_audio, link: product, position: 4, created_at: 3.days.ago)

      rich_content.update!(description: [
                             { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] },
                             { "type" => "image", "attrs" => { "src" => "https://example.com/album.jpg", "link" => nil } },
                             { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
                             { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "World" }] },
                             { "type" => "blockquote", "content" => [
                               { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Inside blockquote" }] },
                               { "type" => "fileEmbed", "attrs" => { "id" => file5.external_id, "uid" => SecureRandom.uuid } },
                             ] },
                             { "type" => "orderedList", "content" => [
                               { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ordered list item 1" }] }] },
                               { "type" => "listItem", "content" => [
                                 { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ordered list item 2" }] },
                                 { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
                               ] },
                               { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ordered list item 3" }] }] },
                             ] },
                             { "type" => "bulletList", "content" => [
                               { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Bullet list item 1" }] }] },
                               { "type" => "listItem", "content" => [
                                 { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Bullet list item 2" }] },
                                 { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
                               ] },
                               { "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Bullet list item 3" }] }] },
                             ] },
                             { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Lorem ipsum" }] },
                             { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
                           ])

      expect(rich_content.embedded_product_file_ids_in_order).to eq([file2.id, file5.id, file1.id, file4.id, file3.id])
    end
  end

  describe "rejecting cross-product file embeds" do
    let(:product) { create(:product) }
    let(:own_file) { create(:product_file, link: product) }
    let(:foreign_file) { create(:product_file, link: create(:product, user: product.user)) }

    def embed(file)
      { "type" => "fileEmbed", "attrs" => { "id" => file.external_id, "uid" => SecureRandom.uuid } }
    end

    it "rejects a product's content embedding a file owned by another product" do
      rich_content = build(:product_rich_content, entity: product, description: [embed(own_file), embed(foreign_file)])
      expect(rich_content).to be_invalid
      expect(rich_content.errors.full_messages.first).to include("not belonging to this product")
      # The message names the file and its owning product rather than an
      # obfuscated id, which is not visible anywhere in the seller's UI.
      expect(rich_content.errors.full_messages.first).to include(foreign_file.name_displayable)
      expect(rich_content.errors.full_messages.first).to include(foreign_file.link.name)
    end

    it "does not expose another seller's file or product names" do
      other_product = create(:product, name: "Private product")
      other_seller_file = create(:product_file, link: other_product, display_name: "Private file")
      rich_content = build(:product_rich_content, entity: product, description: [embed(other_seller_file)])

      expect(rich_content).to be_invalid
      expect(rich_content.errors.full_messages.first).to include(other_seller_file.external_id)
      expect(rich_content.errors.full_messages.first).not_to include(other_seller_file.name_displayable)
      expect(rich_content.errors.full_messages.first).not_to include(other_product.name)
    end

    it "does not expose the seller's other file or product names to a product collaborator" do
      collaborator = create(:collaborator, seller: product.user, apply_to_all_products: false)
      create(:product_affiliate, affiliate: collaborator, product:, affiliate_basis_points: 30_00)
      rich_content = build(:product_rich_content, entity: product, description: [embed(foreign_file)])

      expect(rich_content).to be_invalid
      expect(rich_content.errors.full_messages.first).to include(foreign_file.external_id)
      expect(rich_content.errors.full_messages.first).not_to include(foreign_file.name_displayable)
      expect(rich_content.errors.full_messages.first).not_to include(foreign_file.link.name)
    end

    it "rejects a variant's content embedding a file owned by another product" do
      variant = create(:variant, variant_category: create(:variant_category, link: product))
      rich_content = build(:rich_content, entity: variant, description: [embed(own_file), embed(foreign_file)])
      expect(rich_content).to be_invalid
      expect(rich_content.errors.full_messages.first).to include("not belonging to this product")
    end

    it "rejects a foreign embed nested inside a file embed group" do
      description = [{ "type" => "fileEmbedGroup", "attrs" => { "uid" => SecureRandom.uuid, "name" => "Files" }, "content" => [embed(foreign_file)] }]
      rich_content = build(:product_rich_content, entity: product, description:)
      expect(rich_content).to be_invalid
      expect(rich_content.errors.full_messages.first).to include("not belonging to this product")
    end

    it "allows content that only embeds the product's own files" do
      another_own_file = create(:product_file, link: product)
      rich_content = create(:product_rich_content, entity: product, description: [embed(own_file), embed(another_own_file)])
      expect(rich_content.reload.embedded_product_file_ids_in_order).to match_array([own_file.id, another_own_file.id])
    end

    it "allows content with no file embeds" do
      rich_content = build(:product_rich_content, entity: product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])
      expect(rich_content).to be_valid
    end

    context "when the foreign file has been soft-deleted" do
      # These rows predate the validation above (usually copy-pasted content
      # pages), so they already exist in the database. Once the foreign file is
      # soft-deleted its embed renders as nothing in the editor, leaving the
      # seller no node to remove and no way to ever save the product again.
      let!(:dead_foreign_file) { create(:product_file, link: create(:product), deleted_at: Time.current) }

      def persist_with_foreign_embed(nodes)
        rich_content = build(:product_rich_content, entity: product, description: nodes)
        rich_content.save!(validate: false)
        rich_content
      end

      it "drops a stale dead embed at the product-save boundary" do
        rich_content = persist_with_foreign_embed([embed(own_file), embed(dead_foreign_file)])

        rich_content.description = [embed(own_file), embed(dead_foreign_file), { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "An unrelated edit" }] }]
        removed_file_ids = rich_content.remove_stale_dead_cross_product_file_embeds
        expect(rich_content.save).to be(true)

        # The seller's own file and their new edit both survive; only the dead
        # foreign embed is gone.
        expect(removed_file_ids).to eq([dead_foreign_file.external_id])
        expect(rich_content.reload.embedded_product_file_ids_in_order).to eq([own_file.id])
        expect(rich_content.description.last["content"].first["text"]).to eq("An unrelated edit")
      end

      it "saves a page whose only embed is a dead foreign one" do
        rich_content = persist_with_foreign_embed([embed(dead_foreign_file)])

        rich_content.description = [embed(dead_foreign_file), { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }]
        rich_content.remove_stale_dead_cross_product_file_embeds
        expect(rich_content.save).to be(true)
        expect(rich_content.reload.embedded_product_file_ids_in_order).to eq([])
      end

      it "drops a dead foreign embed nested inside a file embed group" do
        group = { "type" => "fileEmbedGroup", "attrs" => { "uid" => SecureRandom.uuid, "name" => "Files" }, "content" => [embed(own_file), embed(dead_foreign_file)] }
        rich_content = persist_with_foreign_embed([group])

        rich_content.description = [group.merge("attrs" => group["attrs"].merge("name" => "Renamed"))]
        rich_content.remove_stale_dead_cross_product_file_embeds
        expect(rich_content.save).to be(true)
        expect(rich_content.reload.embedded_product_file_ids_in_order).to eq([own_file.id])
      end

      it "still rejects an ALIVE foreign embed on the same page" do
        # Only dead embeds are safe to drop silently. An alive foreign file is
        # still content the seller may have meant to include, so it stays a
        # validation failure rather than being deleted for them.
        alive_foreign_file = create(:product_file, link: create(:product, user: product.user))
        rich_content = persist_with_foreign_embed([embed(dead_foreign_file), embed(alive_foreign_file)])

        rich_content.description = [embed(dead_foreign_file), embed(alive_foreign_file), { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Edit" }] }]
        rich_content.remove_stale_dead_cross_product_file_embeds
        expect(rich_content.save).to be(false)
        expect(rich_content.errors.full_messages.first).to include(alive_foreign_file.name_displayable)
        expect(rich_content.errors.full_messages.first).not_to include(dead_foreign_file.name_displayable)
        # The explicit cleanup changes the in-memory candidate, but a rejected save must
        # not persist a partial cleanup.
        expect(rich_content.reload.embedded_product_file_ids_in_order).to match_array([dead_foreign_file.id, alive_foreign_file.id])
      end

      it "does not drop a newly submitted dead foreign embed" do
        rich_content = create(:product_rich_content, entity: product, description: [embed(own_file)])

        rich_content.description = [embed(own_file), embed(dead_foreign_file)]
        removed_file_ids = rich_content.remove_stale_dead_cross_product_file_embeds

        expect(removed_file_ids).to eq([])
        expect(rich_content.save).to be(false)
        expect(rich_content.errors.full_messages.first).to include("not belonging to this product")
        expect(rich_content.embedded_product_file_ids_in_order).to include(dead_foreign_file.id)
      end

      it "drops a dead embed from a new destination only with stored source provenance" do
        source = persist_with_foreign_embed([embed(dead_foreign_file)])
        destination = build(
          :product_rich_content,
          entity: product,
          description: [embed(dead_foreign_file), { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Copied" }] }]
        )

        removed_file_ids = destination.remove_stale_dead_cross_product_file_embeds(
          legacy_dead_file_ids: source.stored_stale_dead_cross_product_file_embed_ids
        )

        expect(removed_file_ids).to eq([dead_foreign_file.external_id])
        expect(destination.save).to be(true)
        expect(destination.reload.embedded_product_file_ids_in_order).to eq([])
      end

      it "drops the dead embed for a variant's content page too" do
        variant = create(:variant, variant_category: create(:variant_category, link: product))
        rich_content = build(:rich_content, entity: variant, description: [embed(own_file), embed(dead_foreign_file)])
        rich_content.save!(validate: false)

        rich_content.description = [embed(own_file), embed(dead_foreign_file), { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Edit" }] }]
        rich_content.remove_stale_dead_cross_product_file_embeds
        expect(rich_content.save).to be(true)
        expect(rich_content.reload.embedded_product_file_ids_in_order).to eq([own_file.id])
      end
    end
  end

  describe ".reject_file_embeds" do
    let(:product) { create(:product) }
    let(:keep_file) { create(:product_file, link: product) }
    let(:drop_file) { create(:product_file, link: product) }

    def embed(file)
      { "type" => "fileEmbed", "attrs" => { "id" => file.external_id, "uid" => SecureRandom.uuid } }
    end

    it "removes embeds whose decrypted id is in the rejection set" do
      nodes = [embed(keep_file), embed(drop_file)]
      result = described_class.reject_file_embeds(nodes, Set[drop_file.id])
      expect(result.length).to eq(1)
      expect(ObfuscateIds.decrypt(result.first.dig("attrs", "id"))).to eq(keep_file.id)
    end

    it "prunes a file embed group left empty after removal" do
      nodes = [{ "type" => "fileEmbedGroup", "attrs" => { "uid" => SecureRandom.uuid }, "content" => [embed(drop_file)] }]
      expect(described_class.reject_file_embeds(nodes, Set[drop_file.id])).to eq([])
    end
  end

  describe "#has_license_key?" do
    let(:product) { create(:product) }

    it "returns false if it does not contain license key" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])
      expect(rich_content.has_license_key?).to be(false)
    end

    it "returns true if it contains license key" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "licenseKey" }])
      expect(rich_content.has_license_key?).to be(true)
    end

    it "returns true if it contains license key nested inside a list item" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "orderedList", "content" => [{ "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ordered list item 2" }] }, { "type" => "licenseKey" }] }] }])
      expect(rich_content.has_license_key?).to be(true)
    end

    it "returns true if it contains license key nested inside a blockquote" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "blockquote", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Inside blockquote" }] }, { "type" => "licenseKey" }] }])
      expect(rich_content.has_license_key?).to be(true)
    end
  end

  describe "link href scheme validation" do
    let(:product) { create(:product) }

    def build_content(href, node_type: "button")
      build(:rich_content, entity: product, description: [{ "type" => node_type, "attrs" => { "href" => href }, "content" => [{ "type" => "text", "text" => "Go" }] }])
    end

    it "allows https links" do
      expect(build_content("https://example.com/activate?key=__license_key__")).to be_valid
    end

    it "allows custom app schemes so sellers can deep-link into their own app" do
      expect(build_content("goodsnooze://activate?key=__license_key__")).to be_valid
      expect(build_content("my-app.desktop://open", node_type: "tiptap-link")).to be_valid
    end

    it "rejects schemes that can execute script or read local files" do
      %w[javascript:alert(1) data:text/html,<script>alert(1)</script> vbscript:msgbox(1) file:///etc/passwd blob:https://example.com/x].each do |href|
        content = build_content(href)
        expect(content).not_to be_valid, "expected #{href} to be rejected"
        expect(content.errors.full_messages.join).to include("URL schemes")
      end
    end

    it "rejects a blocked scheme in a link mark nested inside a list" do
      content = build(:rich_content, entity: product, description: [
                        { "type" => "bulletList", "content" => [
                          { "type" => "listItem", "content" => [
                            { "type" => "paragraph", "content" => [
                              { "type" => "text", "text" => "Click", "marks" => [{ "type" => "link", "attrs" => { "href" => "javascript:alert(1)" } }] }
                            ] }
                          ] }
                        ] }
                      ])
      expect(content).not_to be_valid
    end

    it "rejects a blocked scheme on an image's click-through link" do
      content = build(:rich_content, entity: product, description: [{ "type" => "image", "attrs" => { "src" => "https://example.com/a.png", "link" => "javascript:alert(1)" } }])
      expect(content).not_to be_valid
    end

    it "allows a custom scheme on an image's click-through link" do
      content = build(:rich_content, entity: product, description: [{ "type" => "image", "attrs" => { "src" => "https://example.com/a.png", "link" => "goodsnooze://activate?key=__license_key__" } }])
      expect(content).to be_valid
    end

    it "rejects a blocked scheme on a media embed's source URL" do
      content = build(:rich_content, entity: product, description: [{ "type" => "mediaEmbed", "attrs" => { "html" => "<iframe></iframe>", "title" => "Demo", "url" => "javascript:alert(1)" } }])
      expect(content).not_to be_valid
    end

    it "is case-insensitive about the blocked scheme" do
      expect(build_content("JavaScript:alert(1)")).not_to be_valid
    end

    # A browser throws away leading control characters and strips tabs/newlines from anywhere in a
    # URL before parsing it, so all of these load as plain `javascript:alert(1)` and run the script
    # when clicked. The validation has to clean the value the same way the browser will, otherwise
    # an API write can store a link that looks inert here and executes in the buyer's browser.
    it "rejects a blocked scheme hidden behind characters a browser strips from the URL" do
      [
        "\u0000javascript:alert(1)",
        "\u0001javascript:alert(1)",
        "\u001Fjavascript:alert(1)",
        " \tjavascript:alert(1)",
        "\njavascript:alert(1)",
        "java\tscript:alert(1)",
        "java\nscript:alert(1)",
        "java\rscript:alert(1)",
        "j\ta\nv\ra\rscript:alert(1)",
      ].each do |href|
        content = build_content(href)
        expect(content).not_to be_valid, "expected #{href.inspect} to be rejected"
        expect(content.errors.full_messages.join).to include("URL schemes")
      end
    end

    it "rejects the same hidden scheme on an image's click-through link" do
      content = build(:rich_content, entity: product, description: [{ "type" => "image", "attrs" => { "src" => "https://example.com/a.png", "link" => "\u0001java\tscript:alert(1)" } }])
      expect(content).not_to be_valid
    end

    it "still allows a custom scheme that merely has surrounding whitespace" do
      expect(build_content("  goodsnooze://activate?key=__license_key__  ")).to be_valid
    end
  end

  describe "#has_posts?" do
    let(:product) { create(:product) }

    it "returns false if it does not contain posts" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])
      expect(rich_content.has_posts?).to be(false)
    end

    it "returns true if it contains posts" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "posts" }])
      expect(rich_content.has_posts?).to be(true)
    end

    it "returns true if it contains posts nested inside a list item" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "orderedList", "content" => [{ "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Ordered list item 2" }] }, { "type" => "posts" }] }] }])
      expect(rich_content.has_posts?).to be(true)
    end

    it "returns true if it contains posts nested inside a blockquote" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "blockquote", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Inside blockquote" }] }, { "type" => "posts" }] }])
      expect(rich_content.has_posts?).to be(true)
    end
  end

  describe "#custom_field_nodes" do
    let(:product) { create(:product) }

    let(:paragraph_node) do
      {
        "type" => "paragraph",
        "content" => [{ "type" => "text", "text" => "Item 1" }]
      }
    end
    let(:short_answer_node_1) do
      {
        "type" => "shortAnswer",
        "attrs" => {
          "id" => "short-answer-id",
          "label" => "Short answer field",
        }
      }
    end
    let(:short_answer_node_2) do
      {
        "type" => "shortAnswer",
        "attrs" => {
          "id" => "short-answer-id-2",
          "label" => "Short answer field 2",
        }
      }
    end
    let(:long_answer_node_1) do
      {
        "type" => "longAnswer",
        "attrs" => {
          "id" => "long-answer-id",
          "label" => "Long answer field",
        }
      }
    end
    let(:file_upload_node) do
      {
        "type" => "fileUpload",
        "attrs" => {
          "id" => "file-upload-id",
        }
      }
    end

    it "parses out deeply nested custom field nodes in order" do
      description = [
        {
          "type" => "orderedList",
          "attrs" => { "start" => 1 },
          "content" => [
            {
              "type" => "listItem",
              "content" => [
                paragraph_node,
                short_answer_node_1,
              ]
            },
          ]
        },
        {
          "type" => "bulletList",
          "content" => [
            {
              "type" => "listItem",
              "content" => [
                paragraph_node,
                long_answer_node_1,
              ]
            },
          ]
        },
        {
          "type" => "blockquote",
          "content" => [
            paragraph_node,
            short_answer_node_2,
          ]
        },
        paragraph_node,
        file_upload_node,
      ]
      rich_content = create(:rich_content, entity: product, description:)

      expect(rich_content.custom_field_nodes).to eq(
        [
          short_answer_node_1,
          long_answer_node_1,
          short_answer_node_2,
          file_upload_node,
        ]
      )
    end
  end

  describe "#has_editor_content?" do
    let(:product) { create(:product) }

    it "returns false for an empty description" do
      expect(create(:rich_content, entity: product, description: []).has_editor_content?).to be(false)
    end

    it "returns false for the editor's blank placeholder (a single bare paragraph)" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "paragraph" }])
      expect(rich_content.has_editor_content?).to be(false)
    end

    it "returns false for empty paragraphs and headings" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "paragraph", "content" => [] }, { "type" => "heading" }])
      expect(rich_content.has_editor_content?).to be(false)
    end

    it "returns true when a node has text" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Hello" }] }])
      expect(rich_content.has_editor_content?).to be(true)
    end

    it "returns true for content-bearing leaf nodes like file embeds" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "fileEmbed", "attrs" => { "id" => "abc", "uid" => "def" } }])
      expect(rich_content.has_editor_content?).to be(true)
    end

    it "returns true when content is nested inside containers" do
      rich_content = create(:rich_content, entity: product, description: [{ "type" => "orderedList", "content" => [{ "type" => "listItem", "content" => [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Item" }] }] }] }])
      expect(rich_content.has_editor_content?).to be(true)
    end

    it "returns true for a title-only page with an empty body" do
      # A title renders in the buyer's page list, so a titled page is
      # seller-authored work even when its body is only a blank placeholder.
      rich_content = create(:rich_content, entity: product, title: "Bonus resources", description: [{ "type" => "paragraph" }])
      expect(rich_content.has_editor_content?).to be(true)
    end
  end

  describe "#has_body_content?" do
    let(:product) { create(:product) }

    it "ignores the title" do
      rich_content = create(:rich_content, entity: product, title: "Bonus resources", description: [{ "type" => "paragraph" }])
      expect(rich_content.has_body_content?).to be(false)
    end

    it "returns true for a body with text" do
      rich_content = create(:rich_content, entity: product, title: nil, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Lesson one" }] }])
      expect(rich_content.has_body_content?).to be(true)
    end

    context "with excluding_node_types" do
      it "treats an excluded leaf node as no content" do
        rich_content = create(:rich_content, entity: product, title: nil, description: [{ "type" => "posts" }])

        expect(rich_content.has_body_content?).to be(true)
        expect(rich_content.has_body_content?(excluding_node_types: described_class::NODE_TYPES_WITHOUT_OWN_CONTENT)).to be(false)
      end

      it "treats a container holding only excluded nodes as no content" do
        rich_content = create(:rich_content, entity: product, title: nil, description: [
                                { "type" => "fileEmbedGroup", "content" => [{ "type" => "fileEmbed", "attrs" => { "id" => "abc" } }] }
                              ])

        expect(rich_content.has_body_content?(excluding_node_types: described_class::NODE_TYPES_WITHOUT_OWN_CONTENT)).to be(false)
      end

      it "still sees the seller's own writing alongside an excluded node" do
        rich_content = create(:rich_content, entity: product, title: nil, description: [
                                { "type" => "posts" },
                                { "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Read these in order" }] }
                              ])

        expect(rich_content.has_body_content?(excluding_node_types: described_class::NODE_TYPES_WITHOUT_OWN_CONTENT)).to be(true)
      end

      # Covers the whole list at once so a node type added to
      # NODE_TYPES_WITHOUT_OWN_CONTENT can't be added without actually taking
      # effect here.
      it "treats a page holding only excluded nodes as no content, for every excluded type" do
        described_class::NODE_TYPES_WITHOUT_OWN_CONTENT.each do |node_type|
          rich_content = create(:rich_content, entity: product, title: nil, description: [{ "type" => node_type }])

          expect(rich_content.has_body_content?(excluding_node_types: described_class::NODE_TYPES_WITHOUT_OWN_CONTENT)).to be(false), "expected a lone #{node_type} node not to count as body content"
        end
      end

      # The guard against the opposite mistake: over-excluding would start
      # blocking listings that really do deliver something. A license key is
      # generated by Gumroad but it IS what the buyer receives, so unlike the
      # nodes above it has to keep counting.
      it "keeps counting a license key, which is itself the thing the buyer receives" do
        rich_content = create(:rich_content, entity: product, title: nil, description: [{ "type" => described_class::LICENSE_KEY_NODE_TYPE }])

        expect(rich_content.has_body_content?(excluding_node_types: described_class::NODE_TYPES_WITHOUT_OWN_CONTENT)).to be(true)
      end
    end
  end
end
