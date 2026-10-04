require "digest"
u = User.find_by(email: "wyloramusic@gmail.com")
raise "no user" unless u
raise "suspended" if u.suspended?
pg = u.page
raise "no page" unless pg
h = pg.custom_html.to_s
PRE = Digest::SHA256.hexdigest(h)

BLOCK = [
  '<style data-wyl1a0fc163="1">',
  '  /* wyl 1a0fc163: wider shell, full-square bundle art, 3-across only while descriptors fit one line */',
  '  main { max-width: 1360px !important; }',
  '  @media (min-width: 781px) {',
  '    .multiplex:not(.single) .multiplex-card { grid-template-columns: minmax(280px, 52%) 1fr !important; }',
  '    .multiplex:not(.single) .multiplex-card .art { aspect-ratio: 1 !important; height: 100% !important; width: auto !important; max-width: 100% !important; align-self: stretch !important; justify-self: start !important; }',
  '    .multiplex:not(.single) .multiplex-card .art img { height: 100% !important; width: 100% !important; object-fit: contain !important; }',
  '  }',
  '  @media (max-width: 1220px) { .grid { grid-template-columns: repeat(2, 1fr) !important; } }',
  '  @media (max-width: 560px) { .grid { grid-template-columns: 1fr !important; } }',
  '</style>',
].join("\n")

ANCHOR = "</style>\n\n</main>"
raise "marker already present" if h.include?("data-wyl1a0fc163")
raise "anchor x#{h.scan(ANCHOR).size}" unless h.scan(ANCHOR).size == 1
raise "no tail" unless h.end_with?(ANCHOR)
out = h.sub(ANCHOR) { BLOCK + "\n\n</main>" }
raise "tail lost" unless out.end_with?("</style>\n\n</main>")
r = Ai::PageSanitizer.sanitize_with_report(out)
puts "PRE=#{PRE}"
puts "PRE_LEN=#{h.length} POST_LEN=#{out.length} DELTA=#{out.length - h.length}"
puts "POST=#{Digest::SHA256.hexdigest(out)}"
puts "SAN_SHA=#{Digest::SHA256.hexdigest(r.html)}"
puts "SAN_EQ=#{r.html == out} REMOVED=#{r.report[:total_removed]} TAGS=#{r.report[:removed_tags].inspect}"
puts "STYLE_#{h.scan('<style').size}_TO_#{out.scan('<style').size} MAIN_#{out.scan('</main>').size} MARKER=#{out.include?('data-wyl1a0fc163')}"
puts "TAIL=#{out[-150..].inspect}"
puts "DONE"
