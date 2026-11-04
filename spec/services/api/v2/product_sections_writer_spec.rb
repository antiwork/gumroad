# frozen_string_literal: true

require "spec_helper"

describe Api::V2::ProductSectionsWriter do
  let(:seller) { create(:user) }
  let!(:product) { create(:product, user: seller) }

  def write!(sections, **options)
    described_class.new(product).write!(sections:, **options)
  end

  def products_section(header: "Kept", for_product: product, owner: seller)
    create(:seller_profile_products_section, seller: owner, product: for_product, header:)
  end

  describe "creating a products section" do
    it "saves the dashboard editor's defaults and lists only the seller's live, unarchived products" do
      live = create(:product, user: seller)
      create(:product, user: seller, archived: true)
      create(:product, user: seller, deleted_at: Time.current)
      create(:product, user: seller, purchase_disabled_at: Time.current)
      create(:product, user: seller, banned_at: Time.current)
      create(:product)

      result = write!([{ "type" => "products" }])

      expect(result).to be_success
      section = product.reload.seller_profile_sections.sole
      expect(section).to be_a(SellerProfileProductsSection)
      expect(section.header).to eq("")
      expect(section.hide_header).to eq(true)
      expect(section.shown_products).to contain_exactly(product.id, live.id)
      expect(section.json_data.except("shown_products")).to eq(
        "default_product_sort" => "page_layout",
        "show_filters" => false,
        "add_new_products" => true,
      )
      expect(product.sections).to eq([section.id])
    end
  end

  describe "ownership" do
    it "refuses a section of another of the seller's products and changes nothing" do
      kept = products_section
      product.update!(sections: [kept.id])
      foreign = products_section(header: "Other product", for_product: create(:product, user: seller))

      result = write!([{ "type" => "products" }, { "id" => foreign.external_id, "header" => "Stolen" }])

      expect(result.error).to eq(described_class::OWNERSHIP_MESSAGE)
      expect(product.reload.seller_profile_sections).to eq([kept])
      expect(product.sections).to eq([kept.id])
      expect(foreign.reload.header).to eq("Other product")
    end

    it "refuses the seller's profile-level sections and another seller's sections" do
      profile_section = products_section(header: "Profile", for_product: nil)
      other_seller = create(:user)
      other_sellers_section = products_section(header: "Theirs", for_product: create(:product, user: other_seller), owner: other_seller)

      [profile_section, other_sellers_section].each do |section|
        result = write!([{ "id" => section.external_id, "header" => "Changed" }])

        expect(result.error).to eq(described_class::OWNERSHIP_MESSAGE)
      end
      expect(profile_section.reload.header).to eq("Profile")
      expect(other_sellers_section.reload.header).to eq("Theirs")
    end

    it "refuses another seller's product as a featured product or listed product" do
      section = products_section
      featured = create(:seller_profile_featured_product_section, seller:, product:, featured_product_id: product.id)
      not_theirs = create(:product).external_id

      expect(write!([{ "id" => featured.external_id, "featured_product" => not_theirs }]).error).to eq("The featured product must be one of your own live products.")
      expect(write!([{ "id" => section.external_id, "shown_products" => [not_theirs] }]).error).to eq("Every listed product must be one of your own live products.")
      expect(featured.reload.featured_product_id).to eq(product.id)
      expect(section.reload.shown_products).to eq([])
    end
  end

  describe "products a section already lists" do
    it "keeps listing a product that is no longer live, but refuses adding one" do
      draft = create(:product, user: seller, purchase_disabled_at: Time.current)
      archived = create(:product, user: seller, archived: true)
      section = products_section
      section.update!(shown_products: [draft.id])
      featured = create(:seller_profile_featured_product_section, seller:, product:, featured_product_id: draft.id)

      result = write!([
                        { "id" => section.external_id, "shown_products" => [draft.external_id, product.external_id] },
                        { "id" => featured.external_id, "featured_product" => draft.external_id, "header" => "Pick" },
                      ])

      expect(result).to be_success
      expect(section.reload.shown_products).to eq([draft.id, product.id])
      expect(featured.reload.featured_product_id).to eq(draft.id)
      expect(featured.header).to eq("Pick")

      expect(write!([{ "id" => section.external_id, "shown_products" => [draft.external_id, archived.external_id] }]).error).to eq("Every listed product must be one of your own live products.")
      expect(write!([{ "id" => featured.external_id, "featured_product" => archived.external_id }]).error).to eq("The featured product must be one of your own live products.")
      expect(section.reload.shown_products).to eq([draft.id, product.id])
      expect(featured.reload.featured_product_id).to eq(draft.id)
    end
  end

  describe "stale-change protection" do
    it "re-checks known_section_ids under the lock, so a section added after the read is never destroyed" do
      kept = products_section
      product.update!(sections: [kept.id])
      added_later = nil
      # Simulates another writer adding a section after the caller's read but before this write takes
      # the product lock: only a check made under the lock can see it.
      allow(product).to receive(:with_lock).and_wrap_original do |original, *args, &block|
        added_later = products_section(header: "Added later")
        original.call(*args, &block)
      end

      result = write!([{ "type" => "products" }], known_section_ids: [kept.external_id])

      expect(result.error).to start_with("A section was added after this change was prepared.")
      expect(result.stale).to eq(true)
      expect(product.reload.seller_profile_sections).to contain_exactly(kept, added_later)
      expect(product.sections).to eq([kept.id])
    end
  end

  describe "locking" do
    it "takes the seller row, then the product row, then the profile lock, the order the permalink claim takes them" do
      create(:seller_profile, seller:)
      taken = []
      allow(User).to receive(:where).and_wrap_original do |original, *args|
        relation = original.call(*args)
        taken << :seller if args.first == { id: seller.id }
        relation
      end
      allow(product).to receive(:with_lock).and_wrap_original do |original, *args, &block|
        taken << :product
        original.call(*args, &block)
      end
      allow(product.user).to receive(:with_profile_sections_lock).and_wrap_original do |original, *args, **kwargs, &block|
        taken << :profile
        original.call(*args, **kwargs, &block)
      end

      expect(write!([{ "type" => "products" }])).to be_success
      expect(taken.first(3)).to eq([:seller, :product, :profile])
    end
  end

  describe "atomicity" do
    it "rolls back the created sections and content changes when a later step fails" do
      kept = products_section
      dropped = products_section(header: "Dropped")
      product.update!(sections: [kept.id, dropped.id])
      # Fails the final product save, after the create and the content update have run.
      product.update_column(:name, "")

      result = write!([{ "type" => "products" }, { "id" => kept.external_id, "header" => "Renamed" }], known_section_ids: [kept.external_id, dropped.external_id])

      expect(result.error).to eq("Name can't be blank")
      expect(product.reload.seller_profile_sections).to contain_exactly(kept, dropped)
      expect(product.sections).to eq([kept.id, dropped.id])
      expect(kept.reload.header).to eq("Kept")
    end
  end

  describe "headers" do
    it "refuses a header longer than the column holds instead of raising" do
      section = products_section

      result = write!([{ "id" => section.external_id, "header" => "a" * 256 }])

      expect(result.error).to eq("header must be at most 255 characters.")
      expect(section.reload.header).to eq("Kept")
      expect(write!([{ "id" => section.external_id, "header" => "a" * 255 }])).to be_success
    end
  end

  describe "clearing a featured product" do
    it "removes the featured product from the section" do
      section = create(:seller_profile_featured_product_section, seller:, product:, featured_product_id: product.id)

      result = write!([{ "id" => section.external_id, "featured_product" => "" }])

      expect(result).to be_success
      expect(section.reload.json_data).not_to have_key("featured_product_id")
      expect(section.featured_product_id).to be_nil
    end
  end
end
