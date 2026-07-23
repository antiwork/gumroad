# frozen_string_literal: true

# Intentionally a no-op.
#
# This started as a deploy-time backfill of tags.taggings_count from the
# existing product_taggings rows. Running it during the deploy is unsafe with
# rolling deploys: old application processes (which don't know about the
# counter cache yet) can create or destroy a tagging AFTER the migration has
# counted that tag, and the migration never revisits it — leaving the counter
# permanently stale.
#
# The backfill instead runs AFTER the deploy completes, once every process is
# on code whose ProductTagging callbacks maintain the counter, via
# BackfillTaggingsCountOnTagsJob (Onetime::BackfillTaggingsCountOnTags),
# enqueued manually. The service recomputes each tag's count from
# product_taggings, so it is idempotent and safe to re-run if needed.
#
# This migration stays so the version records cleanly across environments; it
# performs no work.
class BackfillTaggingsCountOnTags < ActiveRecord::Migration[7.1]
  def up
  end
end

