# Product-page storefront setup for the product published since the last round on this ticket:
# 15795180 "ChatGPT & AI Tools for Beginners – Master AI Skills from Scratch" (permalink qlzsa).
#
# Its page renders the per-product SellerProfileProductsSection rows listed in the Link's own
# `sections`; empty means the page falls back to EVERY on-profile group. The seller created the
# "AI guides" group themselves this round (group 4731718, 3 members incl. this product) and it has
# NO per-product rows yet, so we create this product's own row (header "AI guides", list = group
# minus itself) and append nothing (there are no other AI guides rows, and cross-group appends are
# banned).
#
# The other new record 15795152 ("...from Scratch!") was deleted by the seller at 12:30:36 and is
# a dead draft; it is not touched.
def qz(t); puts("### #{t} " + yield.inspect); end

u = User.find_by(email: "akil012206@gmail.com")
raise "seller not found" unless u
raise "wrong seller #{u.id}" unless u.id == 28168652

AI = 15795180
made = nil

u.with_profile_sections_lock do
  cg = SellerProfileProductsSection.where(seller_id: u.id, product_id: nil).find_by(header: "AI guides")
  raise "no AI guides group" unless cg
  cids = (cg.json_data["shown_products"] || []).map(&:to_i)
  raise "new AI product is not in the AI guides group: #{cids.inspect}" unless cids.include?(AI)

  sec = SellerProfileProductsSection.where(seller_id: u.id, product_id: AI).first
  if sec.nil?
    sec = SellerProfileProductsSection.new(seller_id: u.id, product_id: AI, header: "AI guides")
    sec.show_filters = false
    sec.shown_products = cids - [AI]
    sec.add_new_products = false
    sec.default_product_sort = "newest"
    sec.save!
  end
  raise "row header mismatch #{sec.header.inspect}" unless sec.header == "AI guides"

  l = Link.find(AI)
  raise "product does not belong to this seller" unless l.user_id == u.id
  l.sections = [sec.id]
  l.save!

  made = [AI, sec.id, sec.header, (sec.json_data["shown_products"] || []).length]
  qz("made") { made }
  qz("ai_group_ids") { cids }
  peers = SellerProfileProductsSection.where(seller_id: u.id, header: "AI guides").where.not(product_id: nil)
  qz("ai_rows_after") { peers.pluck(:id) }
end

l = Link.find(AI)
qz("verify_link_sections") { l.reload.sections }
empty = []
Link.where(user_id: u.id).find_each do |x|
  s = (x.sections rescue nil)
  empty << [x.id, x.name] if (s.nil? || s.empty?) && (x.alive? rescue true)
end
qz("empty_sections_alive_after") { empty }
puts "GP2502 GLITTERING AI DONE"
