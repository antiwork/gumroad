# frozen_string_literal: true

require "spec_helper"

# `deleted_ids[:variants]` carries version ids only, never grouping ids
# (gumroad-private#1503).
#
# External ids are `ObfuscateIds.encrypt(primary_key)` with no table
# discriminator, and `base_variants`/`variant_categories` have independent
# auto-increment counters — so one id string can name both a version and a
# grouping. The deletion paths in Product::VariantCategoryUpdaterService resolve
# every id in `deleted_ids(:variants)` against VERSION external ids with no
# collision check. That is correct today only because no client can put a
# grouping id in that array; it is not a tie-break the server wins on merit.
#
# The first example pins what the collision actually costs, so nobody has to
# re-derive it. The rest are the tripwire: they fail the moment the editor grows
# a way to name a grouping in that collection.
describe "deleted_ids[:variants] kind invariant" do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  before { Feature.activate_user(Product::SaveContract::FEATURE_NAME, seller) }
  after { Feature.deactivate_user(Product::SaveContract::FEATURE_NAME, seller) }

  describe "the damage a grouping id would do if one ever reached the server" do
    it "deletes the colliding version, leaves the named grouping alive, and reports success" do
      category = create(:variant_category, link: product, title: "Groupings")
      version = create(:variant, variant_category: category, name: "V1")

      # Force the collision the id scheme permits: a grouping whose primary key
      # equals the version's, so both encrypt to the same string. Move BOTH rows
      # onto an id free in both tables rather than reusing whatever grouping
      # already sits at the version's id — when the two counters line up that row
      # is `category` itself, and the example then asserts the grouping under
      # test both survives and gets swept.
      collision_id = [BaseVariant.maximum(:id), VariantCategory.maximum(:id)].compact.max + 1
      BaseVariant.where(id: version.id).update_all(id: collision_id)
      version = Variant.find(collision_id)
      spare = create(:variant_category, link: product, title: "Collides")
      VariantCategory.where(id: spare.id).update_all(id: collision_id)
      colliding_category = VariantCategory.find(collision_id)

      expect(colliding_category.external_id).to eq(version.external_id)

      contract = Product::SaveContract.new(
        params: {
          editor_revision: Product::EditorRevision.current(product.reload),
          deletion_operations: { deleted_ids: { variants: [colliding_category.external_id] } },
        },
        product: product.reload
      )

      # The seller means "remove that grouping". The server has no way to know.
      Product::VariantCategoryUpdaterService.new(
        product: product,
        category_params: { id: category.external_id, name: "Groupings", options: nil },
        confirmed_removed_variant_ids: [colliding_category.external_id],
        contract: contract
      ).perform

      expect(version.reload.alive?).to eq(false), "the unrelated VERSION was deleted"
      expect(colliding_category.reload.alive?).to eq(true), "the grouping the seller named survived"
    end
  end

  describe "the client cannot construct that request" do
    javascript_root = Rails.root.join("app", "javascript")

    source_cache = {}
    files_matching = ->(pattern) do
      Dir.glob(javascript_root.join("**", "*.{ts,tsx}")).filter_map do |path|
        next if path.end_with?(".test.ts", ".test.tsx")

        next unless (source_cache[path] ||= File.read(path)).match?(pattern)

        Pathname.new(path).relative_path_from(javascript_root).to_s
      end.sort
    end

    # Every file that APPENDS to confirmed_removed_variant_ids — the sole
    # upstream of deleted_ids[:variants]. Each of these four is a per-row
    # deletion modal for one kind of version row (versions, durations, tiers,
    # suggested amounts); none of them can hold a grouping.
    permitted_producers = %w[
      components/ProductEdit/ProductTab/VersionsEditor.tsx
      components/ProductEdit/ProductTab/DurationsEditor.tsx
      components/ProductEdit/ProductTab/TiersEditor.tsx
      components/ProductEdit/ProductTab/SuggestedAmountsEditor.tsx
    ]

    # Plumbing that reads the list, or shrinks it after a save, but never adds
    # to it: the type declaration, the post-save reconciliation, the save
    # serializer, and the contract builder.
    permitted_readers = %w[
      components/ProductEdit/state.ts
      components/server-components/ProductEditPage.tsx
      data/product_edit.ts
      data/product_save_contract.ts
    ]

    mutators = %w[push pop shift unshift splice sort reverse fill copyWithin]

    # Any spelling that can WRITE the collection — dot or bracket property
    # assignment on any receiver, logical assignment, element assignment
    # through an index, or in-place array mutation reached either through
    # `.`/`?.`/`!.` or through a bracket-accessed method name that is
    # immediately called (`ids["push"](id)`). A producer can rename its
    # variable or switch notation, but it still has to spell the property name
    # and the mutator name.
    #
    # Regex, not an AST walk, on purpose: this tripwire has to survive without
    # a TypeScript parser in the Ruby suite, so it is deliberately WIDER than
    # the real grammar — it prefers flagging a read over missing a write. The
    # classification example below is what keeps that width honest in both
    # directions.
    bracket_mutator_call = /(?:\?\.)?\s*\[\s*["'`](?:#{Regexp.union(mutators).source})["'`]\s*\]\s*(?:\?\.)?\s*\(/
    write_pattern = /confirmed_removed_variant_ids["'\]\s!]*(?:#{bracket_mutator_call}|(?:\[[^\[\]]*\]\s*)*(?:\|\|=|&&=|\?\?=|=(?![=>])|\??\.\s*(?:#{Regexp.union(mutators).source})\b))/

    it "has no producer of confirmed_removed_variant_ids outside the version-row editors" do
      expect(files_matching.call(/confirmed_removed_variant_ids/)).to eq((permitted_producers + permitted_readers).sort),
                                                                      "A new file references confirmed_removed_variant_ids. If it can put a VariantCategory " \
                                                                      "(grouping) id in there, a colliding VERSION gets deleted instead — see " \
                                                                      "gumroad-private#1503. Give grouping deletion its own collection."

      reconciler = "components/server-components/ProductEditPage.tsx"
      expect(files_matching.call(write_pattern)).to eq((permitted_producers + [reconciler]).sort),
                                                    "A new writer of confirmed_removed_variant_ids appeared. If it can name a " \
                                                    "VariantCategory (grouping), it will delete a colliding VERSION instead — see " \
                                                    "gumroad-private#1503. Give grouping deletion its own collection."

      # The reconciler may clear the list or drop the ids a save consumed;
      # anything else makes it a fifth producer. Capture each assignment's
      # WHOLE expression (to the semicolon, across lines) and anchor-match it —
      # a prefix check would wave through a trailing `.concat(groupingIds)`.
      # Paren-free arguments only, so wrapping any call around the result (or
      # feeding one in) trips this and forces review.
      reconciler_source = File.read(javascript_root.join(reconciler))
      reconciler_writes = reconciler_source.scan(/confirmed_removed_variant_ids["'\]\s]*=(?![=>])\s*([^;]+);/).flatten
      expect(reconciler_writes).not_to be_empty
      expect(reconciler_writes).to all(match(/\A(?:\[\]|reconcileConfirmedRemovalIds\(\s*[^()]*\))\s*\z/)),
                                   "The reconciler assigns confirmed_removed_variant_ids something other than [] or a " \
                                   "bare reconcileConfirmedRemovalIds(...) call. Anything appended to that expression " \
                                   "can smuggle a grouping id into deleted_ids[:variants] — see gumroad-private#1503."

      # Every write the wide pattern sees in the reconciler must be one of the
      # plain assignments checked above — a `.push` or indexed write here would
      # otherwise hide inside the allowed-writer file.
      expect(reconciler_source.scan(write_pattern).size).to eq(reconciler_writes.size)
    end

    it "classifies every write spelling, including indexed and optional-chain forms" do
      writes = [
        "product.confirmed_removed_variant_ids = ids",
        'product["confirmed_removed_variant_ids"] = ids',
        "product.confirmed_removed_variant_ids ||= []",
        "product.confirmed_removed_variant_ids ??= []",
        "product.confirmed_removed_variant_ids &&= ids",
        "confirmed_removed_variant_ids.push(id)",
        "confirmed_removed_variant_ids?.push(id)",
        "confirmed_removed_variant_ids!.push(id)",
        "product.confirmed_removed_variant_ids[index] = id",
        'product["confirmed_removed_variant_ids"][0] = id',
        "confirmed_removed_variant_ids.splice(index, 1)",
        # Bracket-accessed mutator names: valid TypeScript, and the shape a
        # writer would reach for to duck a `.push` scan.
        'confirmed_removed_variant_ids["push"](id)',
        "confirmed_removed_variant_ids['unshift'](id)",
        'confirmed_removed_variant_ids["splice"](0, 1)',
        'product["confirmed_removed_variant_ids"]["push"](id)',
        'confirmed_removed_variant_ids?.["push"](id)',
      ]
      reads = [
        "product.confirmed_removed_variant_ids ?? []",
        "confirmed_removed_variant_ids.includes(id)",
        "confirmed_removed_variant_ids?.length",
        "confirmed_removed_variant_ids[0] === id",
        "confirmed_removed_variant_ids: string[]",
        "const ids = product.confirmed_removed_variant_ids.map((id) => id)",
        # Bracket access that is NOT a call, and a bracket name that is not a
        # mutator — neither can change the collection.
        'const fn = confirmed_removed_variant_ids["push"];',
        'confirmed_removed_variant_ids["includes"](id)',
        'confirmed_removed_variant_ids["length"]',
      ]

      expect(writes.grep(write_pattern)).to eq(writes)
      expect(reads.grep(write_pattern)).to be_empty
    end

    it "gives deleted_ids.variants exactly one producer, fed only by confirmed_removed_variant_ids" do
      contract_source = File.read(javascript_root.join("data", "product_save_contract.ts"))

      # One touch of the variants key, total — dot or bracket, read or write.
      variants_key = /deletedIds\s*(?:\.\s*variants\b|\[\s*["'`]variants["'`]\s*\])/
      expect(contract_source.scan(variants_key).size).to eq(1)
      expect(contract_source).to match(/#{variants_key}\s*=\s*\[\.\.\.new Set\(removedVariants\)\]/)
      expect(contract_source).to include("const removedVariants = product.confirmed_removed_variant_ids ?? [];")

      # A second producer does not need this file at all if it can hand the save
      # a ready-made operations object whose ids never passed through
      # confirmed_removed_variant_ids. That fallback used to exist
      # (`product.deletion_operations ?? buildDeletionOperations(product)`) and
      # is gone: the property is no longer a field on Product, so nothing can
      # set it and the serializer always derives. Limiting WHICH files may name
      # the property is not enough — it must have no writer and no declaration.
      expect(files_matching.call(/deletion_operations/)).to eq(%w[components/ProductEdit/state.ts data/product_edit.ts])

      deletion_ops_write = /deletion_operations["'\]\s!?]*(?:#{bracket_mutator_call}|(?:\[[^\[\]]*\]\s*)*(?:\|\|=|&&=|\?\?=|=(?![=>])))/
      expect(files_matching.call(deletion_ops_write)).to be_empty,
                                                         "Something now assigns product.deletion_operations. The save serializer must " \
                                                         "always derive the payload from buildDeletionOperations, because any prebuilt " \
                                                         "object bypasses confirmed_removed_variant_ids entirely and a grouping id can " \
                                                         "reach deleted_ids[:variants] — see gumroad-private#1503."

      # state.ts must not even DECLARE the property: an optional field is what
      # made a prebuilt payload expressible in the first place (#1508).
      state_source = File.read(javascript_root.join("components", "ProductEdit", "state.ts"))
      expect(state_source).not_to match(/^\s*deletion_operations\??:/)
      expect(state_source.scan(/deletion_operations/).size).to eq(1) # the comment only

      serializer_source = File.read(javascript_root.join("data", "product_edit.ts"))
      expect(serializer_source.scan(/deletion_operations/).size).to eq(1)
      expect(serializer_source).to match(/deletion_operations:\s*buildDeletionOperations\(product\),/)
    end

    # A row leaving a list without a confirmed-removal id is the silent no-op of
    # gumroad-private#1508. Reorder was that route: it rebuilt the list from
    # whatever the sortable reported, so an omitted row was dropped. Pin the
    # call sites, not just the helpers — reverting a call site is invisible to a
    # unit test of the helper alone.
    it "reorders the version editors without letting a row leave the list" do
      %w[VersionsEditor DurationsEditor TiersEditor].each do |editor|
        source = File.read(javascript_root.join("components", "ProductEdit", "ProductTab", "#{editor}.tsx"))

        expect(source).to match(/onReorder=\{\(newOrder\) => onChange\(reorderPreservingMembership\(\w+, newOrder\)\)\}/),
                          "#{editor} must reorder through reorderPreservingMembership. Rebuilding the list from " \
                          "newOrder drops any row the order omits, with no confirmed-removal id — see " \
                          "gumroad-private#1508."
        expect(source).not_to match(/onReorder=\{[^}]*newOrder\.(?:flatMap|map|filter)/m),
                              "#{editor} derives its new list from newOrder directly, which cannot preserve a row " \
                              "the order omitted."
      end
    end

    # Same defect class, different sortable: the content tab's page list reports
    # row objects rather than ids. A page dropped here has no confirmed-removal
    # id either, so the server keeps the row while the seller watches the page
    # vanish — and no report can see it, because there is no contradiction.
    it "reorders the content page list without letting a page leave the list" do
      source = File.read(javascript_root.join("components", "ProductEdit", "ContentTab", "index.tsx"))

      expect(source).to match(/const currentPages = pagesRef\.current/),
                        "The content page list must snapshot pagesRef before reordering. A stale or " \
                        "inline-only read can drop a page the sortable omitted — see gumroad-private#1508."
      expect(source).to match(/reorderRowsPreservingMembership\(reportedPages, currentPages\)/),
                        "The content page list must reorder through reorderRowsPreservingMembership. Assigning " \
                        "the sortable's list straight to rich_content drops any page it omits — see " \
                        "gumroad-private#1508."
      expect(source).not_to match(/setList=\{setPages\}/),
                            "The page sortable writes its reported list straight to state, which cannot preserve " \
                            "a page that report omitted. Route it through reorderPages."
    end

    it "exposes no grouping as a deletable object in the product editor" do
      editor_sources = (Dir.glob(javascript_root.join("components", "ProductEdit", "**", "*.{ts,tsx}")) +
                        permitted_readers.map { javascript_root.join(_1).to_s }).uniq

      naming_groupings = editor_sources.filter_map do |path|
        next if path.end_with?(".test.ts", ".test.tsx")

        next unless File.read(path).match?(/variant.?categor|grouping.?id/i)

        Pathname.new(path).relative_path_from(javascript_root).to_s
      end

      expect(naming_groupings).to be_empty,
                                  "The editor now references variant categories. A grouping still cannot be " \
                                  "named in deleted_ids[:variants] — see gumroad-private#1503."
    end
  end
end
