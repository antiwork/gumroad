require "digest"
PRE  = "88da8f1dee66c89f644dc337bdcb39327c745c8aed041526e466c6fc21d26f27"
POST = "d9d282f9b8a27a326e7a49aba584c7b338d0c852b980c0ad2a23e2cbe041e2c0"

u = User.find_by(email: "wyloramusic@gmail.com")
raise "no user" unless u
raise "suspended" if u.suspended?
pg = u.page
raise "no page" unless pg

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

pg.with_lock do
  cur = pg.custom_html.to_s
  raise "BASE_MOVED cur=#{Digest::SHA256.hexdigest(cur)[0,16]}" unless Digest::SHA256.hexdigest(cur) == PRE
  raise "marker already present" if cur.include?("data-wyl1a0fc163")
  raise "anchor x#{cur.scan(ANCHOR).size}" unless cur.scan(ANCHOR).size == 1
  out = cur.sub(ANCHOR) { BLOCK + "\n\n</main>" }
  raise "POST mismatch" unless Digest::SHA256.hexdigest(out) == POST
  r = Ai::PageSanitizer.sanitize_with_report(out)
  raise "sanitizer shifted removed=#{r.report[:total_removed]}" unless r.html == out
  raise "too long" if out.length > Page::MAX_CUSTOM_HTML_LENGTH
  pg.custom_html = out
  pg.save!
end

pg.reload
wrote = Digest::SHA256.hexdigest(pg.custom_html.to_s)
puts "WROTE=#{wrote} MATCH=#{wrote == POST} LEN=#{pg.custom_html.length} MARKER=#{pg.custom_html.include?('data-wyl1a0fc163')} PAGES=#{Page.where(pageable_type: 'User', pageable_id: u.id).count}"
puts "DONE"
