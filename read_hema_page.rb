u = User.find_by(external_id: "1727934812723")
Page.where(pageable_type: "User", pageable_id: u.id).each do |p|
  puts "PAGE #{p.id} slug=#{p.slug.inspect} title=#{p.title.inspect} custom_len=#{p.custom_html.to_s.length} content_len=#{p.content.to_s.length} created=#{p.created_at} updated=#{p.updated_at}"
  begin
    if p.class.respond_to?(:versioned?) || p.respond_to?(:versions)
      vs = p.versions.last(5)
      puts "  versions=#{vs.size}"
      vs.each { |v| puts "   v#{v.index} event=#{v.event} at=#{v.created_at} whodunnit=#{v.whodunnit.inspect} changes_keys=#{(v.changeset || {}).keys.inspect}" }
    else
      puts "  no-papertrail"
    end
  rescue => e
    puts "  papertrail-err #{e.class}: #{e.message}"
  end
end
puts "--- grep ledger for seller ---"
