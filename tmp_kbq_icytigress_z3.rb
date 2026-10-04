M = "KBQ25X"
u = User.unscoped.find_by(email: "icytigress69@gmail.com")
puts "#{M} found=#{u.present?}"
if u
  puts "#{M} pk=#{u.id} email=#{u.email} unconfirmed=#{u.unconfirmed_email.inspect} deleted=#{u.deleted_at.inspect}"
  puts "#{M} created=#{u.created_at} 2fa=#{u.two_factor_authentication_enabled?} google_uid=#{u.google_uid.inspect} provider=#{u.provider.inspect}"
  begin
    c = UserComplianceInfo.where(user_id: u.id).order(:id).last
    if c
      puts "#{M} uci first=#{c.first_name.inspect} last=#{c.last_name.inspect} phone=#{c.telephone_number.inspect} dob=#{c.birthday.inspect}"
      puts "#{M} uci street=#{c.street_address.inspect} city=#{c.city.inspect} state=#{c.state.inspect} zip=#{c.zip_code.inspect} country=#{c.country.inspect}"
    else
      puts "#{M} uci=none"
    end
  rescue => e
    puts "#{M} uci_err=#{e.class}"
  end
  puts "#{M} balance_cents=#{u.unpaid_balance_cents.inspect}"
  puts "#{M} twin_dark=#{User.unscoped.find_by(email: 'darkleopardess69@gmail.com').inspect}"
end
puts "#{M} DONE"
