# frozen_string_literal: true

require "spec_helper"

describe Api::V2::LinksController do
  before do
    @user = create(:user)
    @other_user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:product, user: @user)
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
  end

  def create_section(product: @product, seller: @user)
    create(:seller_profile_products_section, seller:, product:)
  end

  def put_sections(sections:, main_section_index: :omitted, known_section_ids: :omitted, product: @product, token: @token)
    params = { format: :json, access_token: token.token, id: product.external_id, sections: }
    params[:main_section_index] = main_section_index unless main_section_index == :omitted
    params[:known_section_ids] = known_section_ids unless known_section_ids == :omitted
    # Only a JSON body can carry an empty `sections` array; form encoding turns `[]` into `[""]`.
    put :update_sections, params:, as: :json
  end

  describe "PUT 'update_sections'" do
    it "reorders the product's sections and sets where the product itself sits" do
      first = create_section
      second = create_section
      @product.update!(sections: [first.id, second.id], main_section_index: 2)

      put_sections(sections: [second.external_id, first.external_id], main_section_index: 1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to eq(true)
      expect(@product.reload.sections).to eq([second.id, first.id])
      expect(@product.main_section_index).to eq(1)
      expect(@product.seller_profile_sections.pluck(:id)).to contain_exactly(first.id, second.id)
      expect(response.parsed_body["product"]["sections"].map { _1["id"] }).to eq([second.external_id, first.external_id])
      expect(response.parsed_body["product"]["main_section_index"]).to eq(1)
    end

    it "destroys the sections the list leaves out" do
      kept = create_section
      dropped = create_section
      @product.update!(sections: [kept.id, dropped.id], main_section_index: 1)

      put_sections(sections: [kept.external_id])

      expect(response).to have_http_status(:ok)
      expect(@product.reload.sections).to eq([kept.id])
      expect(SellerProfileSection.exists?(dropped.id)).to eq(false)
    end

    it "clears every section when the list is empty" do
      only = create_section
      @product.update!(sections: [only.id], main_section_index: 1)

      put_sections(sections: [])

      expect(response).to have_http_status(:ok)
      expect(@product.reload.sections).to eq([])
      expect(@product.seller_profile_sections).to be_empty
      expect(response.parsed_body["product"]["sections"]).to eq([])
      expect(SellerProfileSection.exists?(only.id)).to eq(false)
    end

    it "leaves main_section_index alone when the request does not send one" do
      section = create_section
      @product.update!(sections: [section.id], main_section_index: 3)

      put_sections(sections: [section.external_id])

      expect(response).to have_http_status(:ok)
      expect(@product.reload.main_section_index).to eq(3)
    end

    it "accepts a numeric string for main_section_index" do
      section = create_section
      @product.update!(sections: [section.id], main_section_index: 2)

      put_sections(sections: [section.external_id], main_section_index: "0")

      expect(response).to have_http_status(:ok)
      expect(@product.reload.main_section_index).to eq(0)
    end

    it "refuses a list that is not an array of section ids or objects" do
      section = create_section
      @product.update!(sections: [section.id])

      put_sections(sections: section.external_id)

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("sections must be an array of section ids or objects.")
      expect(@product.reload.sections).to eq([section.id])
    end

    it "refuses a null element instead of clearing every section" do
      section = create_section
      @product.update!(sections: [section.id])

      put_sections(sections: [nil])

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("sections must be an array of section ids or objects.")
      expect(@product.reload.sections).to eq([section.id])
      expect(SellerProfileSection.exists?(section.id)).to eq(true)
    end

    it "refuses a non-string element" do
      section = create_section
      @product.update!(sections: [section.id])

      put_sections(sections: [section.id])

      expect(response.parsed_body["success"]).to eq(false)
      expect(@product.reload.sections).to eq([section.id])
    end

    it "refuses a request without a sections list" do
      section = create_section
      @product.update!(sections: [section.id])

      put :update_sections, params: { format: :json, access_token: @token.token, id: @product.external_id }, as: :json

      expect(response.parsed_body["success"]).to eq(false)
      expect(SellerProfileSection.exists?(section.id)).to eq(true)
    end

    # Sections that never made it into json_data are invisible to get_product, but the dashboard
    # also destroys them when the saved list omits them.
    it "destroys an orphaned section that is not in the product's saved list" do
      kept = create_section
      orphan = create_section
      @product.update!(sections: [kept.id])

      put_sections(sections: [kept.external_id])

      expect(response.parsed_body["success"]).to eq(true)
      expect(SellerProfileSection.exists?(orphan.id)).to eq(false)
    end

    it "refuses a section that belongs to another product" do
      kept = create_section
      @product.update!(sections: [kept.id])
      foreign = create_section(product: create(:product, user: @user))

      put_sections(sections: [kept.external_id, foreign.external_id])

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("One or more sections do not belong to this product.")
      expect(@product.reload.sections).to eq([kept.id])
      expect(SellerProfileSection.exists?(foreign.id)).to eq(true)
    end

    describe "known_section_ids" do
      it "refuses to destroy a section added after the list was read" do
        kept = create_section
        added_later = create_section
        @product.update!(sections: [kept.id, added_later.id])

        put_sections(sections: [kept.external_id], known_section_ids: [kept.external_id])

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("A section was added after this change was prepared. Read the product again and prepare a fresh sections list.")
        expect(response.parsed_body["reason"]).to eq("stale_known_sections")
        expect(@product.reload.sections).to eq([kept.id, added_later.id])
        expect(SellerProfileSection.exists?(added_later.id)).to eq(true)
      end

      it "still destroys a section that was in the list the seller reviewed" do
        kept = create_section
        dropped = create_section
        @product.update!(sections: [kept.id, dropped.id])

        put_sections(sections: [kept.external_id], known_section_ids: [kept.external_id, dropped.external_id])

        expect(response.parsed_body["success"]).to eq(true)
        expect(SellerProfileSection.exists?(dropped.id)).to eq(false)
      end

      it "accepts a known list that includes a section deleted since" do
        kept = create_section
        gone = create_section
        gone_external_id = gone.external_id
        @product.update!(sections: [kept.id, gone.id])
        gone.destroy!

        put_sections(sections: [kept.external_id], known_section_ids: [kept.external_id, gone_external_id])

        expect(response.parsed_body["success"]).to eq(true)
        expect(@product.reload.sections).to eq([kept.id])
      end

      [["not-a-real-id"], "abc", [1]].each do |value|
        it "refuses #{value.inspect} without changing anything" do
          section = create_section
          @product.update!(sections: [section.id])

          put_sections(sections: [], known_section_ids: value)

          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["message"]).to eq("known_section_ids must be an array of section ids.")
          expect(SellerProfileSection.exists?(section.id)).to eq(true)
        end
      end
    end

    it "refuses an id it cannot decrypt" do
      section = create_section
      @product.update!(sections: [section.id])

      put_sections(sections: [section.external_id, "not-a-real-id"])

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("One or more sections were not found.")
      expect(@product.reload.sections).to eq([section.id])
    end

    it "refuses the same section twice" do
      section = create_section
      @product.update!(sections: [section.id])

      put_sections(sections: [section.external_id, section.external_id])

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("sections must not list the same section twice.")
      expect(@product.reload.sections).to eq([section.id])
    end

    it "clamps main_section_index to the number of sections" do
      section = create_section
      @product.update!(sections: [section.id], main_section_index: 0)

      put_sections(sections: [section.external_id], main_section_index: 99)

      expect(response.parsed_body["success"]).to eq(true)
      expect(@product.reload.main_section_index).to eq(1)
    end

    [1.5, [1], nil, "", "1.5", "abc"].each do |value|
      it "refuses #{value.inspect} as main_section_index" do
        section = create_section
        @product.update!(sections: [section.id], main_section_index: 1)

        put_sections(sections: [section.external_id], main_section_index: value)

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("main_section_index must be a non-negative integer.")
        expect(@product.reload.main_section_index).to eq(1)
      end
    end

    it "refuses a negative main_section_index" do
      section = create_section
      @product.update!(sections: [section.id], main_section_index: 1)

      put_sections(sections: [section.external_id], main_section_index: -1)

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("main_section_index must be a non-negative integer.")
      expect(@product.reload.main_section_index).to eq(1)
    end

    it "does not touch another seller's product" do
      other_product = create(:product, user: @other_user)
      other_section = create_section(product: other_product, seller: @other_user)
      other_product.update!(sections: [other_section.id])

      put_sections(sections: [], product: other_product)

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("The product was not found.")
      expect(other_product.reload.sections).to eq([other_section.id])
    end

    it "refuses a token without the edit_products scope" do
      section = create_section
      @product.update!(sections: [section.id])
      read_token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public view_sales")

      put_sections(sections: [], token: read_token)

      expect(response).to have_http_status(:forbidden)
      expect(@product.reload.sections).to eq([section.id])
    end

    describe "creating sections and changing their contents" do
      it "creates a featured product section at the position the list gives it" do
        kept = create_section
        @product.update!(sections: [kept.id], main_section_index: 0)
        featured = create(:product, user: @user)

        put_sections(sections: [
                       { type: "featured_product", featured_product: featured.external_id, header: "Featured" },
                       kept.external_id,
                     ], main_section_index: 1)

        expect(response.parsed_body["success"]).to eq(true)
        created = @product.reload.seller_profile_sections.find { _1.is_a?(SellerProfileFeaturedProductSection) }
        expect(created.featured_product_id).to eq(featured.id)
        expect(created.header).to eq("Featured")
        expect(created.hide_header).to eq(false)
        expect(@product.sections).to eq([created.id, kept.id])
        expect(@product.main_section_index).to eq(1)
        expect(response.parsed_body["product"]["sections"].map { _1["id"] }).to eq([created.external_id, kept.external_id])
        expect(response.parsed_body["product"]["sections"].first["featured_product"]).to eq(featured.external_id)
      end

      it "creates a products section with the listed products, sort order and filters" do
        first = create(:product, user: @user)
        second = create(:product, user: @user)

        put_sections(sections: [{
                       type: "products",
                       header: "More",
                       shown_products: [second.external_id, first.external_id],
                       default_product_sort: "newest",
                       show_filters: true,
                       add_new_products: false,
                     }])

        expect(response.parsed_body["success"]).to eq(true)
        section = @product.reload.seller_profile_sections.sole
        expect(section).to be_a(SellerProfileProductsSection)
        expect(section.product_id).to eq(@product.id)
        expect(section.seller).to eq(@user)
        expect(section.shown_products).to eq([second.id, first.id])
        expect(section.default_product_sort).to eq("newest")
        expect(section.show_filters).to eq(true)
        expect(section.add_new_products).to eq(false)
        expect(section.header).to eq("More")
        expect(@product.sections).to eq([section.id])
      end

      it "starts a created products section with the seller's live catalog and the dashboard defaults" do
        own = create(:product, user: @user)
        foreign = create(:product, user: @other_user)

        put_sections(sections: [{ type: "products" }])

        section = @product.reload.seller_profile_sections.sole
        expect(section.shown_products).to contain_exactly(@product.id, own.id)
        expect(section.shown_products).not_to include(foreign.id)
        expect(section.default_product_sort).to eq("page_layout")
        expect(section.show_filters).to eq(false)
        expect(section.add_new_products).to eq(true)
        expect(section.header).to eq("")
        expect(section.hide_header).to eq(true)
      end

      it "changes an existing products section's products and sort order" do
        section = create(:seller_profile_products_section, seller: @user, product: @product, shown_products: [])
        @product.update!(sections: [section.id])
        listed = create(:product, user: @user)

        put_sections(sections: [{ id: section.external_id, shown_products: [listed.external_id], default_product_sort: "price_asc" }])

        expect(response.parsed_body["success"]).to eq(true)
        expect(section.reload.shown_products).to eq([listed.id])
        expect(section.default_product_sort).to eq("price_asc")
        expect(@product.reload.sections).to eq([section.id])
      end

      it "changes an existing featured section's featured product" do
        section = create(:seller_profile_featured_product_section, seller: @user, product: @product)
        @product.update!(sections: [section.id])
        featured = create(:product, user: @user)

        put_sections(sections: [{ id: section.external_id, featured_product: featured.external_id }])

        expect(response.parsed_body["success"]).to eq(true)
        expect(section.reload.featured_product_id).to eq(featured.id)
      end

      it "clears an existing featured section's featured product" do
        featured = create(:product, user: @user)
        section = create(:seller_profile_featured_product_section, seller: @user, product: @product, featured_product_id: featured.id)
        @product.update!(sections: [section.id])

        put_sections(sections: [{ id: section.external_id, featured_product: "" }])

        expect(response.parsed_body["success"]).to eq(true)
        # Cleared by dropping the key: the schema types featured_product_id as an integer, so a stored
        # nil is refused and the whole write rolls back.
        expect(section.reload.json_data).not_to have_key("featured_product_id")
        expect(section.featured_product_id).to be_nil
        expect(response.parsed_body["product"]["sections"].first["featured_product"]).to be_nil
      end

      it "sets a header and derives the hidden flag from it" do
        section = create_section
        @product.update!(sections: [section.id])
        section.update!(header: "Shown")

        put_sections(sections: [{ id: section.external_id, header: "" }])

        expect(response.parsed_body["success"]).to eq(true)
        expect(section.reload.header).to eq("")
        expect(section.hide_header).to eq(true)
      end

      it "leaves a section's contents alone when the entry only keeps its id" do
        section = create(:seller_profile_products_section, seller: @user, product: @product, shown_products: [])
        @product.update!(sections: [section.id])
        listed = create(:product, user: @user)
        section.update!(shown_products: [listed.id], default_product_sort: "newest")

        put_sections(sections: [section.external_id])

        expect(response.parsed_body["success"]).to eq(true)
        expect(section.reload.shown_products).to eq([listed.id])
        expect(section.default_product_sort).to eq("newest")
      end

      it "creates the new sections next to destroyed ones in one write" do
        dropped = create_section
        @product.update!(sections: [dropped.id])

        put_sections(sections: [{ type: "products" }])

        expect(response.parsed_body["success"]).to eq(true)
        expect(SellerProfileSection.exists?(dropped.id)).to eq(false)
        expect(@product.reload.seller_profile_sections.count).to eq(1)
      end

      it "creates nothing when one entry is refused" do
        kept = create_section
        @product.update!(sections: [kept.id])
        foreign = create(:product, user: @other_user)

        put_sections(sections: [kept.external_id, { type: "products", shown_products: [foreign.external_id] }])

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("Every listed product must be one of your own live products.")
        expect(@product.reload.seller_profile_sections.count).to eq(1)
        expect(@product.sections).to eq([kept.id])
      end

      it "refuses a featured product section without a featured product" do
        put_sections(sections: [{ type: "featured_product" }])

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("A featured product section needs a featured_product.")
        expect(@product.reload.seller_profile_sections).to be_empty
      end

      it "refuses a type it cannot create" do
        put_sections(sections: [{ type: "posts" }])

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("type must be one of: featured_product, products.")
      end

      it "refuses a listed product that is not the seller's" do
        foreign = create(:product, user: @other_user)

        put_sections(sections: [{ type: "products", shown_products: [foreign.external_id] }])

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("Every listed product must be one of your own live products.")
        expect(@product.reload.seller_profile_sections).to be_empty
      end

      it "refuses another seller's product as the featured product" do
        foreign = create(:product, user: @other_user)

        put_sections(sections: [{ type: "featured_product", featured_product: foreign.external_id }])

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("The featured product must be one of your own live products.")
        expect(@product.reload.seller_profile_sections).to be_empty
      end

      it "refuses contents on a section whose type has none to change" do
        rich_text = create(:seller_profile_rich_text_section, seller: @user, product: @product)
        @product.update!(sections: [rich_text.id])

        put_sections(sections: [{ id: rich_text.external_id, shown_products: [] }])

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("Only featured product and products sections can have their contents changed here.")
        expect(@product.reload.sections).to eq([rich_text.id])
      end

      it "refuses a products field on a featured product section" do
        section = create(:seller_profile_featured_product_section, seller: @user, product: @product)
        @product.update!(sections: [section.id])

        put_sections(sections: [{ id: section.external_id, default_product_sort: "newest" }])

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("default_product_sort is not a field of a featured product section.")
        expect(@product.reload.sections).to eq([section.id])
      end

      it "refuses an entry that carries both an id and a type" do
        section = create_section
        @product.update!(sections: [section.id])

        put_sections(sections: [{ id: section.external_id, type: "products" }])

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("A section entry takes either id (an existing section) or type (a new one), not both.")
      end

      it "refuses an entry that carries neither an id nor a type" do
        put_sections(sections: [{ header: "Nope" }])

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("Each object in sections must have an id or a type.")
      end

      it "refuses an unknown field" do
        put_sections(sections: [{ type: "products", shown_product: [] }])

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to include("shown_product is not a section field.")
      end

      it "refuses a sort order the dashboard does not offer" do
        put_sections(sections: [{ type: "products", default_product_sort: "cheapest" }])

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("default_product_sort must be one of: #{SellerProfileProductsSection.json_schema.dig("properties", "default_product_sort", "enum").join(", ")}.")
      end

      it "refuses a non-boolean filter flag" do
        put_sections(sections: [{ type: "products", show_filters: "yes" }])

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("show_filters must be true or false.")
      end

      it "clamps main_section_index to the layout it saves" do
        put_sections(sections: [{ type: "products" }], main_section_index: 99)

        expect(response.parsed_body["success"]).to eq(true)
        expect(@product.reload.main_section_index).to eq(1)
      end

      it "creates a section without tripping the stale-section guard" do
        kept = create_section
        @product.update!(sections: [kept.id])

        put_sections(sections: [kept.external_id, { type: "products" }], known_section_ids: [kept.external_id])

        expect(response.parsed_body["success"]).to eq(true)
        expect(@product.reload.seller_profile_sections.count).to eq(2)
      end

      it "still refuses to touch a section added after the change was prepared" do
        kept = create_section
        added = create_section
        @product.update!(sections: [kept.id, added.id])

        put_sections(sections: [{ id: kept.external_id, header: "Kept" }], known_section_ids: [kept.external_id])

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["reason"]).to eq("stale_known_sections")
        expect(SellerProfileSection.exists?(added.id)).to eq(true)
        expect(kept.reload.header).not_to eq("Kept")
      end
    end
  end
end
