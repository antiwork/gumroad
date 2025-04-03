# frozen_string_literal: true

describe TransactionalAttributeChangeTracker do
  before do
    @model = create_mock_model
    @model.include(described_class)
  end

  after do
    destroy_mock_model(@model)
  end

  describe "#attributes_committed" do
    let!(:record) { @model.create! }
    let(:fresh_record) { @model.find(record.id) }

    it "returns nil if no attribute changes were committed" do
      expect(fresh_record.attributes_committed).to eq(nil)

      fresh_record.title = "foo"
      expect(fresh_record.attributes_committed).to eq(nil)
    end

    it "returns attributes changed in the transaction when record was created" do
      expect(record.attributes_committed).to match_array(%w[id created_at updated_at])
    end

    it "returns attributes changed in the transaction when record was updated" do
      record.update!(title: "foo", subtitle: "bar")
      expect(record.attributes_committed).to match_array(%w[title subtitle updated_at])
    end

    it "only returns attributes changed in the transaction when record was last updated" do
      record.update!(title: "foo")
      expect(record.attributes_committed).to match_array(%w[title updated_at])

      record.update!(subtitle: "bar")
      expect(record.attributes_committed).to match_array(%w[subtitle updated_at])
    end

    it "returns attributes changed in the transaction when record was updated several times" do
      expect(record.title).to eq(nil)

      ApplicationRecord.transaction do
        record.update!(title: "foo")
        record.update!(subtitle: "bar")
        record.update!(user_id: 1)

        # expected behavior: even if within a transaction an attribute is changed back to the
        # value it had before the commit, it will still be tracked in `attributes_committed`
        record.update!(title: nil)
      end
      expect(record.attributes_committed).to match_array(%w[title subtitle user_id updated_at])
    end

    it "returns attributes changed in the transaction when record was updated and reloaded" do
      ApplicationRecord.transaction do
        record.update!(title: "foo")
        record.update!(subtitle: "bar")
        record.reload
      end
      expect(record.attributes_committed).to match_array(%w[title subtitle updated_at])
    end

    it "does not return attributes changed in the transaction when transaction is rolled back" do
      ApplicationRecord.transaction do
        record.update!(title: "foo")
        raise ActiveRecord::Rollback
      end
      expect(record.attributes_committed).to eq(nil)
    end
  end
end
