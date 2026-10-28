# frozen_string_literal: true

require "spec_helper"

describe ProductBuildSave do
  let(:purchase) { create(:purchase) }

  describe ".apply_changes!" do
    it "creates the purchase's save on the first write" do
      save = described_class.apply_changes!(purchase, set: { "level" => "3", "name" => "Ana" })

      expect(save.reload.data).to eq("level" => "3", "name" => "Ana")
      expect(save.byte_size).to eq("level3nameAna".bytesize)
    end

    it "updates the same save on later writes" do
      described_class.apply_changes!(purchase, set: { "level" => "3", "name" => "Ana" })
      described_class.apply_changes!(purchase, set: { "level" => "4" }, remove: ["name"])

      expect(described_class.where(purchase:).count).to eq(1)
      expect(described_class.find_by(purchase:).data).to eq("level" => "4")
    end

    it "clears, then removes, then sets, so one batch can replace the whole save" do
      described_class.apply_changes!(purchase, set: { "a" => "1", "b" => "2" })
      save = described_class.apply_changes!(purchase, clear: true, remove: ["c"], set: { "c" => "3" })

      expect(save.reload.data).to eq("c" => "3")
      expect(save.byte_size).to eq(2)
    end

    it "keeps saves of different purchases apart" do
      other_purchase = create(:purchase)
      described_class.apply_changes!(purchase, set: { "level" => "3" })
      described_class.apply_changes!(other_purchase, set: { "level" => "9" })

      expect(described_class.find_by(purchase:).data).to eq("level" => "3")
      expect(described_class.find_by(purchase: other_purchase).data).to eq("level" => "9")
    end

    it "rejects values that are not strings" do
      expect do
        described_class.apply_changes!(purchase, set: { "level" => 3 })
      end.to raise_error(described_class::LimitError, "Keys and values must be strings.")
      expect(described_class.count).to eq(0)
    end

    it "rejects strings that are not valid UTF-8" do
      expect do
        described_class.apply_changes!(purchase, set: { "level" => "\xED\xA0\x80".dup.force_encoding(Encoding::UTF_8) })
      end.to raise_error(described_class::LimitError, "Keys and values must be valid UTF-8.")
    end

    it "rejects a key longer than the key limit" do
      expect do
        described_class.apply_changes!(purchase, set: { "k" * (described_class::MAX_KEY_BYTES + 1) => "1" })
      end.to raise_error(described_class::LimitError, "A key can be at most #{described_class::MAX_KEY_BYTES} bytes.")
    end

    it "rejects a batch that takes the save past the key count and keeps the stored save" do
      stub_const("#{described_class}::MAX_KEYS", 2)
      described_class.apply_changes!(purchase, set: { "a" => "1", "b" => "2" })

      expect do
        described_class.apply_changes!(purchase, set: { "c" => "3" })
      end.to raise_error(described_class::LimitError, "A save can hold at most 2 keys.")
      expect(described_class.find_by(purchase:).data).to eq("a" => "1", "b" => "2")
    end

    it "rejects a batch that takes the save past the total size and keeps the stored save" do
      stub_const("#{described_class}::MAX_BYTE_SIZE", 10)
      described_class.apply_changes!(purchase, set: { "a" => "12345" })

      expect do
        described_class.apply_changes!(purchase, set: { "b" => "12345" })
      end.to raise_error(described_class::LimitError, /at most/)
      expect(described_class.find_by(purchase:).data).to eq("a" => "12345")
    end

    it "accepts a batch that frees room before it adds" do
      stub_const("#{described_class}::MAX_BYTE_SIZE", 10)
      described_class.apply_changes!(purchase, set: { "a" => "12345" })

      save = described_class.apply_changes!(purchase, remove: ["a"], set: { "b" => "12345" })

      expect(save.reload.data).to eq("b" => "12345")
    end
  end
end
