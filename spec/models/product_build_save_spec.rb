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

    it "rejects a batch with the wrong shape and keeps the stored save" do
      described_class.apply_changes!(purchase, set: { "level" => "3" })

      [
        { set: ["level", "4"], clear: true },
        { remove: "level" },
        { clear: "yes" },
      ].each do |batch|
        expect do
          described_class.apply_changes!(purchase, **batch)
        end.to raise_error(described_class::LimitError, /A batch needs/)
      end
      expect(described_class.find_by(purchase:).data).to eq("level" => "3")
    end

    def data = described_class.find_by(purchase:).data

    it "applies a late batch from the same page only to keys no later batch changed" do
      described_class.apply_changes!(purchase, set: { "b" => "new" }, writer: "page1", sequence: 2)

      described_class.apply_changes!(purchase, set: { "a" => "1", "b" => "old" }, writer: "page1", sequence: 1)

      expect(data).to eq("a" => "1", "b" => "new")
    end

    it "does not bring back a key that a later batch from the same page removed" do
      described_class.apply_changes!(purchase, set: { "a" => "1" }, writer: "page1", sequence: 1)
      described_class.apply_changes!(purchase, remove: ["a"], writer: "page1", sequence: 3)

      described_class.apply_changes!(purchase, set: { "a" => "2" }, writer: "page1", sequence: 2)

      expect(data).to eq({})
    end

    it "skips a late batch older than a clear from the same page, even for keys the clear never saw" do
      described_class.apply_changes!(purchase, clear: true, set: { "b" => "2" }, writer: "page1", sequence: 2)

      described_class.apply_changes!(purchase, set: { "a" => "1" }, writer: "page1", sequence: 1)

      expect(data).to eq("b" => "2")
    end

    it "keeps keys a later batch set when a late clear from the same page arrives" do
      described_class.apply_changes!(purchase, set: { "old" => "1" })
      described_class.apply_changes!(purchase, set: { "b" => "2" }, writer: "page1", sequence: 2)

      described_class.apply_changes!(purchase, clear: true, writer: "page1", sequence: 1)

      expect(data).to eq("b" => "2")
    end

    it "orders a page's batches per key even after another page saved in between" do
      described_class.apply_changes!(purchase, set: { "level" => "4" }, writer: "page1", sequence: 2)
      described_class.apply_changes!(purchase, set: { "coins" => "10" }, writer: "page2", sequence: 1)

      described_class.apply_changes!(purchase, set: { "level" => "3" }, writer: "page1", sequence: 1)

      expect(data).to eq("level" => "4", "coins" => "10")
    end

    it "keeps a clear and the batch after it, at the key limit, in either arrival order" do
      stub_const("#{described_class}::MAX_KEYS", 2)
      hide = { clear: true, set: { "a" => "1" }, writer: "page1", sequence: 1 }
      # The leave beacon after a hide beacon that cleared carries the clear and all its changes.
      leave = { clear: true, set: { "a" => "1", "b" => "2" }, writer: "page1", sequence: 2 }

      [[hide, leave], [leave, hide]].each do |batches|
        described_class.where(purchase:).delete_all
        described_class.apply_changes!(purchase, set: { "x" => "1", "y" => "1" })
        batches.each { described_class.apply_changes!(purchase, **_1) }

        expect(data).to eq("a" => "1", "b" => "2")
      end
    end

    it "keeps removals and the keys added after them, at the key limit, in either arrival order" do
      stub_const("#{described_class}::MAX_KEYS", 2)
      hide = { remove: ["x"], set: { "a" => "1" }, writer: "page1", sequence: 1 }
      # The leave beacon repeats the hide beacon's removals with the new key.
      leave = { remove: ["x"], set: { "b" => "2" }, writer: "page1", sequence: 2 }

      [[hide, leave], [leave, hide]].each do |batches|
        described_class.where(purchase:).delete_all
        described_class.apply_changes!(purchase, set: { "x" => "1" })
        batches.each { described_class.apply_changes!(purchase, **_1) }

        expect(data).to eq("a" => "1", "b" => "2")
      end
    end

    it "applies batches from different pages in arrival order" do
      described_class.apply_changes!(purchase, set: { "level" => "4" }, writer: "page1", sequence: 5)
      described_class.apply_changes!(purchase, set: { "level" => "2" }, writer: "page2", sequence: 1)

      expect(data).to eq("level" => "2")
    end

    it "rejects a writer or sequence it cannot store" do
      [["page-1", 1], ["page1", 0], ["page1", "2"], ["page1", described_class::MAX_SEQUENCE + 1], ["a" * 33, 1], ["page1", nil]].each do |writer, sequence|
        expect do
          described_class.apply_changes!(purchase, set: { "level" => "1" }, writer:, sequence:)
        end.to raise_error(described_class::LimitError, /writer/)
      end
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
