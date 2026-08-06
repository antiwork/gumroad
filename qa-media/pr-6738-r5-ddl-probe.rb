# frozen_string_literal: true

# r5 probe: the re-arming head 93b500669 is a main merge + a THIRD migration renumber
# (20261206000023 -> 20261206000025, dodging main's create_product_permalink_redirects at ...024).
# A later main merge forced a FOURTH renumber to 20261206000027, because main's
# add_is_first_party_agent_app_to_oauth_applications claimed ...025 outright.
# The whole point of that commit is that the five credit_cards columns must actually exist in the
# DDL. Read connection.columns, never schema_migrations (which can record a migration whose DDL
# never ran).
require "digest"

puts "MARK rev=#{ENV['REVISION'] || `cat /app/REVISION 2>/dev/null`.strip}"

conn = ActiveRecord::Base.connection
cols = conn.columns("credit_cards").map(&:name)
want = %w[recurring_authorization_verified_at recurring_authorization_currency
          recurring_authorization_max_amount_cents stripe_account_id processor_payment_method_id]
present = want.index_with { |c| cols.include?(c) }
puts "MARK ddl_present=#{present}"
puts "MARK ddl_missing=#{want.reject { |c| cols.include?(c) }}"
raise "ABORT missing credit_cards columns: #{want.reject { |c| cols.include?(c) }}" unless present.values.all?

# The renumber's stated hazard: schema_migrations recording the version without the DDL.
vers = conn.select_values("SELECT version FROM schema_migrations WHERE version LIKE '202612060000%' ORDER BY version")
puts "MARK schema_migrations_2026120600=#{vers.join(',')}"
puts "MARK has_027=#{vers.include?('20261206000027')} has_025=#{vers.include?('20261206000025')} has_024=#{vers.include?('20261206000024')} has_023=#{vers.include?('20261206000023')}"

# main's ...024 companion table must also really exist (same hazard, other direction).
puts "MARK product_permalink_redirects_table=#{conn.table_exists?('product_permalink_redirects')}"

# The predicate the columns exist to serve must ANSWER, not raise.
cc = CreditCard.last
puts "MARK credit_card_id=#{cc&.id} recurring_upi?=#{cc ? cc.recurring_upi? : 'no-rows'}"
puts "MARK CreditCard.instance_methods recurring=#{CreditCard.instance_methods(false).grep(/recurring|upi/).sort}"
puts "MARK StripeChargeableUpi_defined=#{defined?(StripeChargeableUpi) ? true : false}"

# Pending-migration state: a renumber can leave the tree's migration permanently pending.
begin
  ctx = ActiveRecord::Base.connection.migration_context
  pending = ctx.open.pending_migrations.map(&:version)
  puts "MARK pending_migrations=#{pending.inspect}"
rescue => e
  puts "MARK pending_migrations_error=#{e.class}: #{e.message[0, 120]}"
end

# The mailer surface last shot (r4) must still render both branches at this head.
sub = Subscription.find_by(id: 3)
if sub && sub.credit_card_to_charge
  card = sub.credit_card_to_charge
  orig = card.payment_method_type
  begin
    %w[card upi].each do |t|
      card.update_columns(payment_method_type: t)
      sub.reload
      %w[subscription_card_declined subscription_card_declined_warning].each do |m|
        mail = CustomerLowPriorityMailer.public_send(m, sub.id)
        body = mail.body.to_s
        puts "MARK RENDER #{m}-#{t} subject=#{mail.subject.inspect} " \
             "upi_copy=#{body.include?('saved UPI payment method')} " \
             "card_copy=#{body.include?('attempted to charge your card')} " \
             "md5=#{Digest::MD5.hexdigest(body)[0, 10]}"
      end
    end
  ensure
    card.update_columns(payment_method_type: orig)
    puts "MARK fixture_restored=#{card.reload.payment_method_type}"
  end
else
  puts "MARK subscription_3=absent (preview DB was reseeded; r4 fixture gone)"
end

puts "MARK DONE"
