# frozen_string_literal: true

# Intentionally a no-op.
#
# This originally added a composite `(email(191), link_id)` index to `purchases` to
# speed up the mobile library's "hasn't bought X" existence probes. It never took
# effect in production, and it is no longer worth building. Both halves are worth
# writing down: the first is a trap, and the second is the reason not to simply
# retry it.
#
# It never ran. Production recorded this migration's version, but the index was
# never created. `purchases` schema changes go through the Alterity gem, which hands
# every ALTER to pt-online-schema-change, and pt-osc creates a trigger set named
# after the table it is altering. `purchases` was still carrying an abandoned
# trigger set of exactly those names, left behind by an earlier pt-osc run that was
# killed without cleanup, so pt-osc failed on "Trigger already exists" within
# seconds and left no trace in the database — a migration that reported success and
# produced nothing. Those leftovers have since been removed and `purchases` DDL
# works again; the full investigation is in gumroad-private#1417.
#
# It is no longer worth building, because the query it was written for is gone. The
# per-seller probe loop it targeted (whole-history scans for mega-sellers, because
# MySQL drove off `index_purchases_on_seller_id` and then filtered on link_id/email)
# was replaced in gumroad#6206 by a single prefetch per request in
# Purchase::SellerPostProbeBatch, which reads:
#
#   SELECT seller_id, id, link_id FROM purchases WHERE email = ? AND seller_id IN (...)
#
# `link_id` is selected there but never filtered on, so a `(email, link_id)` index
# adds no selectivity over the `index_purchases_on_email_long` this query already
# uses, and it cannot cover the read either, because `seller_id` is not in it. There
# is no better plan for the optimizer to pick, so the index would cost a large
# amount of storage and a full pt-online-schema-change copy of one of the biggest
# tables in the database in exchange for nothing. Measurements are in
# gumroad-private#1417.
#
# This stays as a no-op rather than being deleted so the version keeps recording
# cleanly across environments — the same treatment 20261201000006 got after its own
# `purchases` ALTER hung a deploy. If some non-production environment did create the
# index (a database loaded from db/schema.rb before this change, for instance), it is
# a harmless unused index, to be dropped out of band and never through a deploy-time
# migration on this table. See docs/migrations.md for why `purchases` and `users` are
# frozen.
class AddEmailAndLinkIdIndexToPurchases < ActiveRecord::Migration[7.1]
  def up
  end

  def down
  end
end
