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

  def put_sections(sections:, main_section_index: :omitted, product: @product, token: @token)
    params = { format: :json, access_token: token.token, id: product.external_id, sections: }
    params[:main_section_index] = main_section_index unless main_section_index == :omitted
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

    # The reported case: a legacy per-product section renders a grid of other products ABOVE the
    # product, and no self-serve surface can remove it.
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

    it "refuses a list that is not an array of ids" do
      section = create_section
      @product.update!(sections: [section.id])

      put_sections(sections: section.external_id)

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("sections must be an array of section ids.")
      expect(@product.reload.sections).to eq([section.id])
    end

    it "refuses a null element instead of clearing every section" do
      section = create_section
      @product.update!(sections: [section.id])

      put_sections(sections: [nil])

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("sections must be an array of section ids.")
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
  end
end
