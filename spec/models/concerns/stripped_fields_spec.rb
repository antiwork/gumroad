# frozen_string_literal: true

require "spec_helper"

describe StrippedFields do
  # Use a non-temporary table to avoid connection-scoped lifetime issues.
  # Temporary tables are lost when the DB connection is recycled, which can
  # happen between file load time and test execution in parallel CI.
  before(:all) do
    ActiveRecord::Schema.define do
      create_table :stripped_fields_test, force: true do |t|
        t.string :name
        t.string :email
        t.string :description
        t.string :sql
        t.string :code
      end
    end
  end

  after(:all) do
    ActiveRecord::Schema.define do
      drop_table :stripped_fields_test, if_exists: true
    end
  end

  let(:test_model) do
    Class.new(ApplicationRecord) do
      self.table_name = "stripped_fields_test"

      include StrippedFields

      stripped_fields :name, :email, transform: ->(v) { v&.upcase }
      stripped_fields :description, nilify_blanks: false
      stripped_fields :sql, remove_duplicate_spaces: false
      stripped_fields :code, transform: ->(v) { v&.gsub(/\s/, "") }
    end
  end

  let(:record) do
    test_model.new(
      name: "  my   name ",
      email: "   ",
      description: " ",
      sql: "  keep  extra  spaces   ",
      code: " 1234 56\n78 "
    )
  end

  it "applies transform and default blank nilification" do
    record.validate

    expect(record.name).to eq("MY NAME")
    expect(record.email).to be_nil
  end

  it "keeps blank strings when nilify_blanks is false" do
    record.validate

    expect(record.description).to eq("")
  end

  it "preserves duplicate spaces when remove_duplicate_spaces is false" do
    record.validate

    expect(record.sql).to eq("keep  extra  spaces")
  end

  it "applies custom transform for code" do
    record.validate

    expect(record.code).to eq("12345678")
  end

  describe "invisible and Unicode-space characters" do
    # These are the characters a user cannot see in the field they just filled in. Each
    # example is written so that the expected value is what the person believed they typed.
    def stripped_email(raw)
      test_model.new(email: raw).tap(&:validate).email
    end

    it "removes a leading right-to-left mark from an email address" do
      # gumroad-private#1487: a buyer signed up as "\u200Ffawazadegbite@outlook.com". We
      # stored the mark, and then every email to that account hard-bounced at Outlook while
      # the address looked correct to everyone involved.
      expect(stripped_email("\u200Ffawazadegbite@outlook.com")).to eq("FAWAZADEGBITE@OUTLOOK.COM")
    end

    it "removes a left-to-right mark, zero-width space, word joiner, BOM and soft hyphen" do
      expect(stripped_email("\u200Ea\u200Bb\u2060c\uFEFFd\u00ADe@example.com")).to eq("ABCDE@EXAMPLE.COM")
    end

    it "removes an invisible character from the middle of an address, not just the ends" do
      # String#strip would never have reached this one even if it did know about these
      # characters, because it only touches the ends of the value.
      expect(stripped_email("buyer\u200F@example.com")).to eq("BUYER@EXAMPLE.COM")
    end

    it "folds Unicode spaces to a plain space so surrounding words stay separate words" do
      # A no-break space between the given and family name is a word boundary the user
      # meant. Folding (not deleting) keeps "Ada Lovelace" from becoming "AdaLovelace".
      record = test_model.new(name: "\u00A0Ada\u202FLovelace\u3000")
      record.validate

      expect(record.name).to eq("ADA LOVELACE")
    end

    it "leaves a value that only contained invisible characters blank" do
      # Nothing visible was typed, so the field should behave as empty rather than as a
      # value made of bytes no one can see.
      expect(stripped_email("\u200F\u200B")).to be_nil
    end

    it "keeps the zero-width non-joiner, which is meaningful in Persian and Indic scripts" do
      # U+200C is what keeps "می‌روم" two words. It sits in the same Unicode block as the
      # marks above but it is content, so removing it would corrupt a real name.
      record = test_model.new(name: "می\u200Cروم")
      record.validate

      expect(record.name).to eq("می\u200Cروم")
    end

    it "keeps the zero-width joiner that holds a multi-codepoint emoji together" do
      # Sellers put emoji in their display name. U+200D is the glue inside a family
      # sequence; drop it and the single glyph breaks apart into separate people.
      family = "\u{1F468}\u200D\u{1F469}\u200D\u{1F467}"
      record = test_model.new(name: "Store #{family}")
      record.validate

      expect(record.name).to eq("STORE #{family}")
    end

    it "leaves a value with no invisible characters untouched" do
      expect(stripped_email("  buyer@example.com  ")).to eq("BUYER@EXAMPLE.COM")
    end
  end
end
