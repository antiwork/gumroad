# gp#2915 read-only verification probe (replica). Marker: GP2915VEL
puts "GP2915VEL_START #{Time.current.utc.iso8601}"

d = Dispute.unscoped.find_by(id: 24832)
if d
  puts "DISPUTE id=#{d.id} purchase_id=#{d.purchase_id.inspect} charge_id=#{d.charge_id.inspect} state=#{d.state.inspect} reason=#{d.reason.inspect} created_at=#{d.created_at&.utc&.iso8601} lost_at=#{d.lost_at&.utc&.iso8601} won_at=#{d.won_at&.utc&.iso8601} event_created_at=#{(d.respond_to?(:event_created_at) ? d.event_created_at&.utc&.iso8601 : nil).inspect}"
  puts "DISPUTE_METHODS #{(d.respond_to?(:disputable) ? 'has_disputable' : '-')} purch_respond=#{d.respond_to?(:purchase)}"
  begin; puts "DISPUTE_PURCHASE_VIA #{d.purchase&.id.inspect}"; rescue => e; puts "DISPUTE_PURCHASE_ERR #{e.class}"; end
else
  puts "DISPUTE 24832 NOT FOUND"
end

p1 = Purchase.unscoped.find_by(id: 38443819)
if p1
  puts "PURCHASE id=#{p1.id} seller_id=#{p1.seller_id} state=#{p1.state.inspect} price_cents=#{p1.price_cents} created_at=#{p1.created_at&.utc&.iso8601}"
  puts "PURCHASE_CB chargeback_date=#{p1.chargeback_date&.utc&.iso8601.inspect} chargeback_reversed=#{p1.chargeback_reversed.inspect} chargeback_reason=#{p1.chargeback_reason.inspect} purchase_chargeback_balance_id=#{p1.purchase_chargeback_balance_id.inspect}"
  puts "PURCHASE_REFUND stripe_refunded=#{p1.stripe_refunded.inspect} amount_refunded_cents=#{(p1.respond_to?(:amount_refunded_cents) ? p1.amount_refunded_cents : nil).inspect} purchase_refund_balance_id=#{(p1.respond_to?(:purchase_refund_balance_id) ? p1.purchase_refund_balance_id.inspect : nil)} refunded=#{(p1.respond_to?(:refunded?) ? p1.refunded? : nil).inspect}"
  puts "PURCHASE_PREDS chargedback?=#{p1.chargedback?} chargedback_not_reversed?=#{p1.chargedback_not_reversed?} access_revoked=#{(p1.respond_to?(:is_access_revoked) ? p1.is_access_revoked : nil).inspect}"
  puts "PURCHASE_DISPUTES n=#{Dispute.unscoped.where(purchase_id: p1.id).count}"
  begin
    bal = p1.purchase_chargeback_balance
    puts "PURCHASE_CB_BALANCE #{bal ? "id=#{bal.id} amount_cents=#{bal.amount_cents} updated_at=#{bal.updated_at&.utc&.iso8601}" : 'nil'}"
  rescue => e
    puts "PURCHASE_CB_BALANCE_ERR #{e.class}"
  end
else
  puts "PURCHASE 38443819 NOT FOUND"
end

u = User.unscoped.find_by(id: 4279254)
if u
  puts "USER id=#{u.id} username=#{u.username.inspect} created_at=#{u.created_at&.utc&.iso8601} suspended=#{(u.respond_to?(:suspended?) ? u.suspended? : nil).inspect}"
  begin; puts "USER_DB sales_cents_total=#{u.sales_cents_total} revenue_as_seller=#{u.revenue_as_seller}"; rescue => e; puts "USER_DB_ERR #{e.class}: #{e.message.to_s[0,120]}"; end
  begin; puts "USER_ES gross_sales_cents_total_as_seller=#{u.gross_sales_cents_total_as_seller}"; rescue => e; puts "USER_ES_ERR #{e.class}: #{e.message.to_s[0,120]}"; end
  begin
    b = Balance.unscoped.find_by(id: 3355470)
    puts "BALANCE_3355470 #{b ? "user_id=#{b.user_id} amount_cents=#{b.amount_cents} updated_at=#{b.updated_at&.utc&.iso8601} created_at=#{b.created_at&.utc&.iso8601}" : 'nil'}"
  rescue => e
    puts "BALANCE_ERR #{e.class}"
  end
  begin
    bals = Balance.unscoped.where(user_id: u.id).order(:id).map { |b| "#{b.id}:#{b.amount_cents}:#{b.updated_at&.utc&.iso8601}" }
    puts "USER_BALANCES n=#{bals.size} #{bals.first(8).join(' ')}"
  rescue => e
    puts "USER_BALANCES_ERR #{e.class}"
  end
  begin
    puts "USER_CHARGEDBACK_SALES purchase_chargeback_balance_id_keys=#{Purchase.unscoped.where(seller_id: u.id).where.not(purchase_chargeback_balance_id: nil).count}"
  rescue => e
    puts "USER_CHARGEDBACK_ERR #{e.class}"
  end
else
  puts "USER 4279254 NOT FOUND"
end

begin
  lost = Dispute.unscoped.where(state: "lost").where.not(purchase_id: nil)
  unmarked = lost.joins("INNER JOIN purchases ON purchases.id = disputes.purchase_id").where("purchases.chargeback_date IS NULL").count
  marked = lost.joins("INNER JOIN purchases ON purchases.id = disputes.purchase_id").where("purchases.chargeback_date IS NOT NULL").count
  puts "COHORT lost_disputes_with_purchase=#{lost.count} purchase_unmarked=#{unmarked} purchase_marked=#{marked}"
rescue => e
  puts "COHORT_ERR #{e.class}: #{e.message.to_s[0,140]}"
end

puts "GP2915VEL_END"