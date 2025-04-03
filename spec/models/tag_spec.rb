# frozen_string_literal: true

require "spec_helper"

describe Tag do
  before { @product = create(:product) }

  it "Creates a new tag by name" do
    expect(@product.has_tag?("bAdger")).to be(false)
    expect { @product.tag!("Badger") }.to change { @product.tags.count }.by(1)
    expect(@product.tags.last.name).to eq("badger")
    expect(@product.has_tag?("bAdGEr")).to be(true)
  end

  describe "clean before validation" do
    it "cleans tag name before save" do
      @product.tag!("  UP   space  ")
      expect(@product.tags.last.name).to eq("up space")
    end

    it "only cleans if name has changed" do
      create(:tag, name: "will be overwritten").update_column(:name, "INVA  LID")

      tag = Tag.all.first
      expect(tag.name).to eq "INVA  LID"
      tag.humanized_name = "invalid-human"
      tag.save!
      expect(tag.name).to eq "INVA  LID"
    end
  end

  describe "validation" do
    it "does not raise exception on tags without names" do
      expect(Tag.new.valid?).to be false
    end

    it "must have name" do
      tag = Tag.new
      tag.name = nil
      expect { tag.save! }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "must be unique, regardless of case" do
      create(:tag, name: "existing")
      expect { create(:tag, name: "existing") }.to raise_error(ActiveRecord::RecordInvalid)
      expect { create(:tag, name: "EXISTING") }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "checks for names longer than max allowed" do
      expect { create(:tag, name: "12345678901234567890_") }.to raise_error(ActiveRecord::RecordInvalid, /A tag is too long/)
    end

    it "checks for names shorter than min allowed" do
      expect { create(:tag, name: "a") }.to raise_error(ActiveRecord::RecordInvalid, /A tag is too short/)
    end

    it "disallows tags starting with hashes" do
      expect { create(:tag, name: "#icon") }.to raise_error(ActiveRecord::RecordInvalid, /cannot start with hashes/)
    end

    it "disallows tags with commas" do
      expect { create(:tag, name: ",icon") }.to raise_error(ActiveRecord::RecordInvalid, /cannot.* contain commas/)
    end
  end

  it "Tags with an existing tag by name" do
    create(:tag, name: "Ocelot")
    expect { @product.tag!("Ocelot") }.to_not change { Tag.count }
    expect(@product.tags.last.name).to eq("ocelot")
  end

  it "Lists tags for a product" do
    @product.tag!("otter")
    @product.tag!("brontosaurus")
    expect(@product.tags.map(&:name)).to eq(%w[otter brontosaurus])
  end

  it "Lists products for a tag" do
    @product.tag!("otter")
    second_product = create(:product)
    second_product.tag!("otter")
    expect(Tag.find_by(name: "otter").products).to eq([@product, second_product])
  end

  it "Finds scoped products by tag list" do
    5.times { create(:product).tag!("fennec") }
    3.times { create(:product).tag!("weasel") }
    other_product = create(:product)
    other_product.tag!("Weasel")
    other_product.tag!("Fennec")
    @product.tag!("Fennec")
    @product.tag!("Weasel")

    expect(Link.with_tags(["fennec"]).length).to eq(7)
    expect(Link.with_tags(%w[fennec weasel]).sort).to eq([other_product, @product].sort)

    expect(@product.user.links.with_tags(["fennec"])).to eq([@product])
    expect(@product.user.links.with_tags(%w[fennec weasel])).to eq([@product])
    expect(@product.user.links.with_tags(%w[fennec weasel hedgehog])).to be_empty
    @product.tag!("Hedgehog")
    expect(@product.user.links.with_tags(%w[fennec weasel hedgehog])).to eq([@product])
    expect(@product.user.links.with_tags(%w[fennec weasel])).to eq([@product])
  end

  it "Untags" do
    expect do
      3.times { |i| create(:tag, name: "Some Tag #{i}") }
      @product.tag!("Wildebeest")
      expect(@product.has_tag?("WILDEBEEST")).to be(true)
      expect { @product.untag!("wIlDeBeeST") }.to change { @product.tags.count }.to(0)
      expect(@product.has_tag?("wildebeest")).to be(false)
    end.to change { Tag.count }.by(4)
  end

  it "Flags" do
    tag = create(:tag)
    expect { tag.flag! }.to change { tag.flagged? }.from(false).to(true)
  end

  it "Unflags" do
    tag = create(:tag, flagged_at: Time.current)
    expect { tag.unflag! }.to change { tag.flagged? }.from(true).to(false)
  end

  describe "#humanized_name" do
    it "capitalizes" do
      expect(create(:tag, name: "photoshop tutorial").humanized_name).to eq("Photoshop Tutorial")
    end

    it "titleizes" do
      expect(create(:tag, name: "raiders_of_stuff").humanized_name).to eq("Raiders Of Stuff")
    end
  end
end
