# frozen_string_literal: true

require "spec_helper"

describe Product::SaveContract do
  let(:product) { create(:product) }
  let(:user) { product.user }
  # A deletion is only allowed when the client proves it edited the CURRENT
  # snapshot, so specs that exercise deletion paths must send a real, fresh
  # revision token — an arbitrary string reads as "stale tab" and is refused.
  let(:fresh_revision) { Product::EditorRevision.current(product) }

  # Build a contract the way the controller does. Payload-container coverage
  # (ActionController::Parameters vs plain Hash) has its own describe below.
  def contract(params)
    described_class.new(params:, product:)
  end

  # Flag activation is scoped to the seller and cleaned up per-seller. We must
  # NOT use the global Feature.deactivate here: Flipper is backed by Redis
  # shared across concurrent test processes, so a global deactivate would rip
  # the flag out from under sibling test runs mid-flight.
  def with_contract_enforced
    Feature.activate_user(described_class::FEATURE_NAME, user)
  end

  after do
    Feature.deactivate_user(described_class::FEATURE_NAME, user)
  end

  describe "#enforced?" do
    it "is false by default (kill switch defaults OFF)" do
      expect(contract({}).enforced?).to eq(false)
    end

    it "is true only once the feature is activated for the product's user" do
      with_contract_enforced
      expect(contract({}).enforced?).to eq(true)
    end

    it "is false when the flag is active for a different user" do
      other_user = create(:user)
      Feature.activate_user(described_class::FEATURE_NAME, other_user)
      expect(contract({}).enforced?).to eq(false)
    ensure
      Feature.deactivate_user(described_class::FEATURE_NAME, other_user)
    end

    it "is false when there is no product to scope the flag to" do
      with_contract_enforced
      expect(described_class.new(params: {}, product: nil).enforced?).to eq(false)
    end
  end

  describe "with the flag OFF (legacy behaviour preserved)" do
    # With the kill switch off, every caller must fall through to the code
    # that existed before the contract — so submitted? answers true no matter
    # what the payload says, and the explicit-deletion machinery stays inert.
    it "reports every collection as submitted regardless of the payload" do
      described_class::COLLECTIONS.each do |collection|
        expect(contract({}).submitted?(collection)).to eq(true), "expected absent #{collection} to be submitted with flag off"
        expect(contract({ collection => [] }).submitted?(collection)).to eq(true), "expected [] #{collection} to be submitted with flag off"
      end
    end

    it "returns no deleted ids even when the client sends some" do
      c = contract(
        editor_revision: fresh_revision,
        deletion_operations: { deleted_ids: { files: ["1", "2"] } }
      )
      expect(c.deleted_ids(:files)).to eq([])
    end

    it "reports no collection as cleared even when the client asks" do
      c = contract(
        editor_revision: fresh_revision,
        deletion_operations: { cleared_collections: ["files"] }
      )
      expect(c.cleared?(:files)).to eq(false)
    end
  end

  describe "with the flag ON" do
    before { with_contract_enforced }

    describe "#submitted?" do
      # Rule 1 of the contract: absent and empty are the same statement —
      # "this request is not about that collection" — for all five
      # collections, including the hash-shaped integrations payload.
      described_class::COLLECTIONS.each do |collection|
        context "for #{collection}" do
          it "is false when the key is absent" do
            expect(contract({}).submitted?(collection)).to eq(false)
          end

          it "is false for an empty array" do
            expect(contract({ collection => [] }).submitted?(collection)).to eq(false)
          end

          it "is false for an empty hash (the integrations shape)" do
            expect(contract({ collection => {} }).submitted?(collection)).to eq(false)
          end

          it "is true for a non-empty value" do
            value = collection == :integrations ? { "circle" => { "api_key" => "x" } } : [{ "id" => "1" }]
            expect(contract({ collection => value }).submitted?(collection)).to eq(true)
          end
        end
      end
    end

    describe "#deleted_ids" do
      it "returns the ids the client explicitly listed for the collection" do
        c = contract(
          editor_revision: fresh_revision,
          deletion_operations: { deleted_ids: { files: ["10", "11"] } }
        )
        expect(c.deleted_ids(:files)).to eq(["10", "11"])
      end

      it "scopes ids to the collection they were sent for" do
        c = contract(
          editor_revision: fresh_revision,
          deletion_operations: { deleted_ids: { files: ["10"] } }
        )
        expect(c.deleted_ids(:variants)).to eq([])
      end

      it "dedupes, drops blanks, and coerces ids to strings" do
        c = contract(
          editor_revision: fresh_revision,
          deletion_operations: { deleted_ids: { variants: [1, "1", 2, nil, "", "  ", 3] } }
        )
        expect(c.deleted_ids(:variants)).to eq(["1", "2", "3"])
      end

      it "returns [] when the editor revision is missing, because a save that cannot prove its snapshot may not delete" do
        c = contract(deletion_operations: { deleted_ids: { files: ["10"] } })
        expect(c.deleted_ids(:files)).to eq([])
      end
    end

    describe "#cleared?" do
      it "is true when the collection is named in cleared_collections and a fresh revision is present" do
        c = contract(
          editor_revision: fresh_revision,
          deletion_operations: { cleared_collections: ["files"] }
        )
        expect(c.cleared?(:files)).to eq(true)
      end

      it "matches collection names sent as symbols or strings" do
        c = contract(
          editor_revision: fresh_revision,
          deletion_operations: { cleared_collections: [:variants] }
        )
        expect(c.cleared?(:variants)).to eq(true)
      end

      it "is false for collections not named" do
        c = contract(
          editor_revision: fresh_revision,
          deletion_operations: { cleared_collections: ["files"] }
        )
        expect(c.cleared?(:integrations)).to eq(false)
      end

      it "is false without a revision, even when the collection is named" do
        c = contract(deletion_operations: { cleared_collections: ["files"] })
        expect(c.cleared?(:files)).to eq(false)
      end

      it "refuses a bare-string clear list rather than wrapping it into a clear-all" do
        # Array("files") would happily turn a malformed scalar into a
        # legitimate-looking instruction to empty the collection — precisely
        # the accidental-wipe class this contract exists to remove.
        c = contract(
          editor_revision: fresh_revision,
          deletion_operations: { cleared_collections: "files" }
        )
        expect(c.cleared?(:files)).to eq(false)
      end
    end

    describe "#may_delete?" do
      it "is false when editor_revision is absent" do
        expect(contract({}).may_delete?).to eq(false)
      end

      it "is false when editor_revision is nil" do
        expect(contract(editor_revision: nil).may_delete?).to eq(false)
      end

      it "is false when editor_revision is an empty string" do
        expect(contract(editor_revision: "").may_delete?).to eq(false)
      end

      it "is false for a stale or junk token — a contract-unaware or out-of-date tab may write but not delete" do
        expect(contract(editor_revision: "junk-token").may_delete?).to eq(false)
      end

      it "is true when the client echoes the current revision token" do
        expect(contract(editor_revision: fresh_revision).may_delete?).to eq(true)
      end

      it "is decided against the state at construction time, so the save's own writes cannot revoke a legitimate deletion" do
        c = contract(editor_revision: fresh_revision)
        # Simulate the save mutating the product mid-request (creating a page
        # moves the fingerprint). The answer must not flip underneath the
        # later deletion steps of the same request.
        travel_to(1.minute.from_now) { product.touch }
        expect(c.may_delete?).to eq(true)
      end
    end

    describe "malformed deletion_operations" do
      # A malformed payload must never blow up mid-save. The safe reading of
      # "we could not make sense of the deletion block" is Rule 1: no explicit
      # deletions were legible, so nothing is deleted. A fresh revision is
      # supplied so these examples get past may_delete? and genuinely
      # exercise the malformed-shape handling.
      [
        ["a string", "not-a-hash"],
        ["an array", ["not", "a", "hash"]],
        ["nil", nil],
        ["a number", 42],
        ["a deeply wrong shape (deleted_ids is a string)", { deleted_ids: "junk" }],
        ["a deeply wrong shape (deleted_ids is an array)", { deleted_ids: ["junk"] }],
        ["a deeply wrong shape (cleared_collections is a hash)", { cleared_collections: { files: true } }],
      ].each do |label, malformed|
        it "degrades to no explicit deletions when deletion_operations is #{label}" do
          c = contract(editor_revision: fresh_revision, deletion_operations: malformed)
          expect(c.may_delete?).to eq(true) # proves we are past the revision gate
          described_class::COLLECTIONS.each do |collection|
            expect { c.deleted_ids(collection) }.not_to raise_error
            expect(c.deleted_ids(collection)).to eq([])
            expect { c.cleared?(collection) }.not_to raise_error
            expect(c.cleared?(collection)).to eq(false)
          end
        end
      end
    end
  end

  describe "unknown collections" do
    # This guard is what makes adding a sixth deletable collection a
    # deliberate act: an unregistered name fails loudly in submitted? — the
    # question every caller asks first — instead of silently answering "not
    # submitted" and skipping the contract.
    it "raises ArgumentError from submitted?" do
      expect { contract({}).submitted?(:reviews) }.to raise_error(ArgumentError, /Unknown save-contract collection/)
    end

    # deleted_ids and cleared? sit behind the malformed-payload rescue, which
    # also absorbs the guard's ArgumentError. They must still never treat an
    # unknown collection as deletable: the safe degrade is "nothing to
    # delete", never an exception mid-save.
    it "degrades to no deletions from deleted_ids without raising" do
      with_contract_enforced
      c = contract(
        editor_revision: fresh_revision,
        deletion_operations: { deleted_ids: { reviews: ["1"] } }
      )
      expect { c.deleted_ids(:reviews) }.not_to raise_error
      expect(c.deleted_ids(:reviews)).to eq([])
    end

    it "degrades to not-cleared from cleared? without raising" do
      with_contract_enforced
      c = contract(
        editor_revision: fresh_revision,
        deletion_operations: { cleared_collections: ["reviews"] }
      )
      expect { c.cleared?(:reviews) }.not_to raise_error
      expect(c.cleared?(:reviews)).to eq(false)
    end
  end

  describe "payload container types" do
    before { with_contract_enforced }

    # The class must not blow up when handed ActionController::Parameters —
    # top-level reads (submitted?, editor_revision, cleared_collections) work
    # directly. Note the one caveat, and why: `to_unsafe_h.symbolize_keys`
    # symbolizes only TOP-level keys, so the nested `deleted_ids` hash keeps
    # string keys and `dig(:deleted_ids, collection_symbol)` cannot see them.
    # That is why the controller deliberately hands the contract
    # `to_h.deep_symbolize_keys` plain hashes (see links_controller.rb's
    # product_save_contract). Under Rule 1 the degraded reading is the safe
    # one: illegible deletion ids delete nothing.
    it "accepts ActionController::Parameters for all top-level reads" do
      params = ActionController::Parameters.new(
        editor_revision: fresh_revision,
        files: [{ id: "1" }],
        deletion_operations: {
          deleted_ids: { files: ["7", "7", "8"] },
          cleared_collections: ["variants"],
        }
      )
      c = contract(params)
      expect(c.submitted?(:files)).to eq(true)
      expect(c.submitted?(:variants)).to eq(false)
      expect(c.cleared?(:variants)).to eq(true)
      expect(c.may_delete?).to eq(true)
      expect(c.contract_aware?).to eq(true)
      # Nested deleted_ids arrive with string keys and degrade safely to
      # "nothing deleted" rather than raising — callers wanting them resolved
      # must deep-symbolize first, as the controller does.
      expect { c.deleted_ids(:files) }.not_to raise_error
      expect(c.deleted_ids(:files)).to eq([])
    end

    it "resolves nested deleted_ids when handed the controller's deeply-symbolized shape" do
      params = ActionController::Parameters.new(
        editor_revision: fresh_revision,
        deletion_operations: { deleted_ids: { files: ["7", "7", "8"] } }
      )
      c = contract(params.to_unsafe_h.deep_symbolize_keys)
      expect(c.deleted_ids(:files)).to eq(["7", "8"])
    end

    it "accepts a plain Hash" do
      c = contract(
        editor_revision: fresh_revision,
        files: [{ id: "1" }],
        deletion_operations: {
          deleted_ids: { files: ["7", "7", "8"] },
          cleared_collections: ["variants"],
        }
      )
      expect(c.submitted?(:files)).to eq(true)
      expect(c.submitted?(:variants)).to eq(false)
      expect(c.deleted_ids(:files)).to eq(["7", "8"])
      expect(c.cleared?(:variants)).to eq(true)
      expect(c.may_delete?).to eq(true)
    end

    it "tolerates nil params" do
      c = described_class.new(params: nil, product:)
      expect(c.submitted?(:files)).to eq(false)
      expect(c.may_delete?).to eq(false)
    end
  end

  describe "#contract_aware?" do
    it "is true when the client sent a revision or deletion operations" do
      expect(contract(editor_revision: "rev").contract_aware?).to eq(true)
      expect(contract(deletion_operations: {}).contract_aware?).to eq(true)
    end

    it "is false for a legacy payload that mentions neither" do
      expect(contract(files: []).contract_aware?).to eq(false)
    end
  end
end
