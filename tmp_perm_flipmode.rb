l = Link.where(unique_permalink: "qkicyh").first
puts "custom_permalink=#{l.custom_permalink.inspect} permalink_col=#{(l.respond_to?(:permalink) ? l.permalink : 'NO_METHOD').inspect}"
puts "COLUMNS=#{Link.column_names.grep(/permalink|url|slug/).inspect}"
if defined?(ProductUrlRedirect)
  puts "REDIRECTS=#{ProductUrlRedirect.where(link_id: l.id).pluck(:id, :old_permalink, :permalink).inspect}"
end
puts "USERNAME=#{l.user.username}"
puts "DRAFT=#{l.draft? rescue 'n/a'} PUBLISHED=#{l.alive?}"
puts "CUSTOM_URL_FEATURE=#{Feature.active?(:custom_domain || :custom_permalink, l.user) rescue 'n/a'}"
