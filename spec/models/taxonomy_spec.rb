# frozen_string_literal: true

require "spec_helper"

describe Taxonomy do
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

  describe ".find_or_create_by!" do
    let!(:parent) { create(:taxonomy, slug: "parent-slug") }

    it "creates the taxonomy when none exists" do
      result = Taxonomy.find_or_create_by!(slug: "brand-new-slug", parent:)
      expect(result).to be_persisted
      expect(result.slug).to eq("brand-new-slug")
      expect(result.parent).to eq(parent)
    end

    it "returns the existing taxonomy without creating a duplicate" do
      existing = create(:taxonomy, slug: "already-there", parent:)
      expect do
        result = Taxonomy.find_or_create_by!(slug: "already-there", parent:)
        expect(result).to eq(existing)
      end.not_to change { Taxonomy.count }
    end

    it "handles concurrent creation for the same slug and parent" do
      ready = Queue.new
      start = Queue.new
      taxonomies = []
      errors = []
      mutex = Mutex.new

      threads = 2.times.map do
        Thread.new do
          Taxonomy.connection_pool.with_connection do
            ready << true
            start.pop
            taxonomy = Taxonomy.find_or_create_by!(slug: "race-slug", parent:)

            mutex.synchronize do
              taxonomies << taxonomy
            end
          end
        rescue StandardError => e
          mutex.synchronize do
            errors << e
          end
        end
      end

      2.times { ready.pop }
      2.times { start << true }
      threads.each(&:join)

      expect(errors).to be_empty
      expect(taxonomies.map(&:id).uniq.size).to eq(1)

      taxonomy = Taxonomy.find_by!(slug: "race-slug", parent:)

      expect(Taxonomy.where(slug: "race-slug", parent:).count).to eq(1)
      expect(taxonomy.parent).to eq(parent)
      expect(taxonomy.self_and_ancestors.map(&:id)).to match_array([parent.id, taxonomy.id])
    end
  end

  describe ".find_or_create_by" do
    let!(:parent) { create(:taxonomy, slug: "parent-slug") }

    it "handles concurrent creation for the same slug and parent" do
      ready = Queue.new
      start = Queue.new
      taxonomies = []
      errors = []
      mutex = Mutex.new

      threads = 2.times.map do
        Thread.new do
          Taxonomy.connection_pool.with_connection do
            ready << true
            start.pop
            taxonomy = Taxonomy.find_or_create_by(slug: "race-slug-nonbang", parent:)

            mutex.synchronize do
              taxonomies << taxonomy
            end
          end
        rescue StandardError => e
          mutex.synchronize do
            errors << e
          end
        end
      end

      2.times { ready.pop }
      2.times { start << true }
      threads.each(&:join)

      expect(errors).to be_empty
      expect(taxonomies).to all(be_a(Taxonomy))
      expect(taxonomies.map(&:id).uniq.size).to eq(1)

      taxonomy = Taxonomy.find_by!(slug: "race-slug-nonbang", parent:)

      expect(Taxonomy.where(slug: "race-slug-nonbang", parent:).count).to eq(1)
      expect(taxonomy.parent).to eq(parent)
      expect(taxonomies).to all(eq(taxonomy))
    end
  end
end
