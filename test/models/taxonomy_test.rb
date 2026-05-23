# frozen_string_literal: true

require "test_helper"

class TaxonomyTest < ActiveSupport::TestCase
  self.described_class = Taxonomy



  context_ Taxonomy do
  context_ "validations" do
  context_ "slug presence validation" do
  context_ "when slug is present" do
          subject { build(:taxonomy, slug: "example") }

          it { is_expected.to be_valid }
        end

  context_ "when slug is not present" do
          subject { build(:taxonomy, slug: nil) }

  test "is not valid" do
            expect(subject).not_to be_valid
            expect(subject.errors.full_messages).to include("Slug can't be blank")
          end
        end
      end

  context_ "slug uniqueness validation" do
        subject { build(:taxonomy, slug: "example", parent:) }

  context_ "when parent_id is nil" do
          let(:parent) { nil }

  context_ "when child taxonomy with slug doesn't exist" do
            it { is_expected.to be_valid }
          end

  context_ "when child taxonomy with slug already exists" do
            let!(:existing_taxonomy) { create(:taxonomy, slug: "example", parent:) }

  test "is not valid" do
              expect(subject).not_to be_valid
              expect(subject.errors.full_messages).to include("Slug has already been taken")
            end
          end
        end

  context_ "when parent_id is not nil" do
          let(:parent) { Taxonomy.find_by(slug: "design") }

  context_ "when child taxonomy with slug doesn't exist" do
            it { is_expected.to be_valid }
          end

  context_ "when child taxonomy with slug already exists" do
            let!(:existing_taxonomy) { create(:taxonomy, slug: "example", parent:) }

  test "is not valid" do
              expect(subject).not_to be_valid
              expect(subject.errors.full_messages).to include("Slug has already been taken")
            end
          end
        end
      end
    end
  end
end
