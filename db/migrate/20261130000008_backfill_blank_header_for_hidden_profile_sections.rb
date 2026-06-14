# frozen_string_literal: true

class BackfillBlankHeaderForHiddenProfileSections < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  # Section header visibility is now driven solely by whether `header` is blank
  # (see PR #5388). Legacy rows that used the old `hide_header` flag (flag_shih_tzu
  # bit 2) with a non-blank header would otherwise show their title in the settings
  # preview and the logged-in product layout, even though the public presenter has
  # always hidden them. Reconcile the data: blank the header on those rows (the text
  # was never rendered publicly) and clear the flag bit so the two can't drift again.
  HIDE_HEADER_FLAG = 2

  def up
    SellerProfileSection
      .where("flags & ? != 0", HIDE_HEADER_FLAG)
      .where.not(header: [nil, ""])
      .in_batches(of: 1000) do |batch|
        batch.update_all("header = '', flags = flags & ~#{HIDE_HEADER_FLAG}")
      end
  end

  def down
    # Irreversible: the original header text is intentionally discarded because it
    # was never displayed. No-op so the migration can be rolled back without error.
  end
end
