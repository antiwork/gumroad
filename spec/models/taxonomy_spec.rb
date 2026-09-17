# frozen_string_literal: true

require "spec_helper"

describe Taxonomy do
  describe ".software_and_plugins_subtree_ids" do
    let(:software_development) { Taxonomy.find_or_create_by!(slug: "software-development") }
    let(:software_and_plugins) { Taxonomy.find_or_create_by!(slug: "software-and-plugins", parent: software_development) }
    let(:wordpress) { Taxonomy.find_or_create_by!(slug: "wordpress", parent: software_and_plugins) }

    it "covers the node itself and its descendants" do
      expect(Taxonomy.software_and_plugins_subtree_ids).to include(software_and_plugins.id, wordpress.id)
    end

    it "excludes taxonomies outside the subtree" do
      expect(Taxonomy.software_and_plugins_subtree_ids).not_to include(software_development.id)
    end
  end

  describe "validations" do
    describe "slug presence validation" do
      context "when slug is present" do
        subject { build(:taxonomy, slug: "example") }

        it { is_expected.to be_valid }
      end

      context "when slug is not present" do
        subject { build(:taxonomy, slug: nil) }

        it "is not valid" do
          expect(subject).not_to be_valid
          expect(subject.errors.full_messages).to include("Slug can't be blank")
        end
      end
    end

    describe "slug uniqueness validation" do
      subject { build(:taxonomy, slug: "example", parent:) }

      context "when parent_id is nil" do
        let(:parent) { nil }

        context "when child taxonomy with slug doesn't exist" do
          it { is_expected.to be_valid }
        end

        context "when child taxonomy with slug already exists" do
          let!(:existing_taxonomy) { create(:taxonomy, slug: "example", parent:) }

          it "is not valid" do
            expect(subject).not_to be_valid
            expect(subject.errors.full_messages).to include("Slug has already been taken")
          end
        end
      end

      context "when parent_id is not nil" do
        let(:parent) { Taxonomy.find_by(slug: "design") }

        context "when child taxonomy with slug doesn't exist" do
          it { is_expected.to be_valid }
        end

        context "when child taxonomy with slug already exists" do
          let!(:existing_taxonomy) { create(:taxonomy, slug: "example", parent:) }

          it "is not valid" do
            expect(subject).not_to be_valid
            expect(subject.errors.full_messages).to include("Slug has already been taken")
          end
        end
      end
    end
  end
end
