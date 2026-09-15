M = "KBA25X"
u = User.unscoped.find_by(email: "icytigress69@gmail.com")
puts "#{M} found=#{u.present?}"
if u
  puts "#{M} pk=#{u.id} email=#{u.email} unconfirmed=#{u.unconfirmed_email.inspect} deleted=#{u.deleted_at.inspect} suspended=#{u.suspended?.inspect}"
  puts "#{M} created=#{u.created_at} 2fa=#{u.two_factor_authentication_enabled?} google_uid=#{u.google_uid.inspect} provider=#{u.provider.inspect} sign_in_count=#{u.sign_in_count} current_sign_in_at=#{u.current_sign_in_at.inspect}"
  begin
    c = u.alive_user_compliance_info
    if c
      puts "#{M} uci_present=true first=#{c.first_name.inspect} last=#{c.last_name.inspect} phone=#{c.telephone_number.inspect} dob=#{c.birthday.inspect}"
      puts "#{M} uci street=#{c.street_address.inspect} city=#{c.city.inspect} state=#{c.state.inspect} zip=#{c.zip_code.inspect} country=#{c.country.inspect}"
    else
      puts "#{M} uci_present=false"
    end
    puts "#{M} uci_rows_all=#{UserComplianceInfo.unscoped.where(user_id: u.id).count} uci_rows_alive=#{UserComplianceInfo.where(user_id: u.id).count}"
  rescue => e
    puts "#{M} uci_err=#{e.class}"
  end
  begin
    dec = nil
    c2 = u.alive_user_compliance_info
    dec = c2.individual_tax_id&.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")) if c2
    puts "#{M} taxid_present=#{dec.present?} taxid_digits=#{dec.to_s.gsub(/\D/, '').length}"
  rescue => e
    puts "#{M} taxid_err=#{e.class}"
  end
  puts "#{M} balance_cents=#{u.unpaid_balance_cents.inspect} links=#{Link.unscoped.where(user_id: u.id).count} sales=#{Purchase.where(seller_id: u.id).count}"
  puts "#{M} gmail_twin=#{User.unscoped.find_by(email: 'darkleopardess69@gmail.com').inspect}"
  rows = Purchase.where(purchaser_id: u.id).order(:created_at)
  byemail = Purchase.where(email: "icytigress69@gmail.com")
  puts "#{M} purch_by_pid=#{rows.count} purch_by_email=#{byemail.count}"
  puts "#{M} cards=#{Purchase.where(purchaser_id: u.id).distinct.pluck(:card_visual).compact.inspect}"
  puts "#{M} zips=#{Purchase.where(purchaser_id: u.id).distinct.pluck(:zip_code).compact.first(6).inspect}"
  puts "#{M} cardzips=#{Purchase.where(purchaser_id: u.id).distinct.pluck(:credit_card_zipcode).compact.first(6).inspect}"
  puts "#{M} names=#{Purchase.where(purchaser_id: u.id).distinct.pluck(:full_name).compact.first(6).inspect}"
  puts "#{M} first_rows=#{rows.limit(4).map { |p| [p.created_at.strftime('%Y-%m-%d'), p.link_id] }.inspect}"
end
puts "#{M} DONE"
