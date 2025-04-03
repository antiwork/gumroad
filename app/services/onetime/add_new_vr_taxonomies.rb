# frozen_string_literal: true

class Onetime::AddNewVrTaxonomies
  def self.process
    move_vr_chat_to_3d
    old_taxonomy_count = Taxonomy.count
    taxonomy_names.each do |taxonomy_name|
      ancestor_slugs = taxonomy_name.split(",")
      parent = Taxonomy.find_by!(slug: ancestor_slugs.second_to_last)
      Taxonomy.find_or_create_by!(slug: ancestor_slugs.last, parent:)
    end
    puts "Added #{Taxonomy.count - old_taxonomy_count}/#{taxonomy_names.length} new taxonomies"
    Rails.cache.clear
    true
  end

  private
    def self.move_vr_chat_to_3d
      gaming = Taxonomy.find_by(slug: "gaming")
      vrchat = Taxonomy.find_by(slug: "vrchat", parent: gaming)
      return unless vrchat
      vrchat.update!(parent: Taxonomy.find_by!(slug: "3d"))
    end

    def self.taxonomy_names
      %w(
        3d,avatars,
        3d,avatars,female,
        3d,avatars,male,
        3d,avatars,non-binary,
        3d,avatars,optimized,
        3d,avatars,quest,
        3d,avatars,species,
        3d,3d-assets,avatar-components,
        3d,3d-assets,avatar-components,bases
        3d,3d-assets,avatar-components,ears
        3d,3d-assets,avatar-components,feet
        3d,3d-assets,avatar-components,hair
        3d,3d-assets,avatar-components,heads
        3d,3d-assets,avatar-components,horns
        3d,3d-assets,avatar-components,tails
        3d,3d-assets,accessories,
        3d,3d-assets,accessories,bags
        3d,3d-assets,accessories,belts
        3d,3d-assets,accessories,chokers
        3d,3d-assets,accessories,gloves
        3d,3d-assets,accessories,harnesses
        3d,3d-assets,accessories,jewelry
        3d,3d-assets,accessories,masks
        3d,3d-assets,accessories,wings
        3d,3d-assets,clothing,
        3d,3d-assets,clothing,bodysuits
        3d,3d-assets,clothing,bottoms
        3d,3d-assets,clothing,bras
        3d,3d-assets,clothing,dresses
        3d,3d-assets,clothing,jackets
        3d,3d-assets,clothing,lingerie
        3d,3d-assets,clothing,outfits
        3d,3d-assets,clothing,pants
        3d,3d-assets,clothing,shirts
        3d,3d-assets,clothing,shorts
        3d,3d-assets,clothing,skirts
        3d,3d-assets,clothing,sweaters
        3d,3d-assets,clothing,swimsuits
        3d,3d-assets,clothing,tops
        3d,3d-assets,clothing,underwear
        3d,3d-assets,footwear,
        3d,3d-assets,footwear,boots
        3d,3d-assets,footwear,leggings
        3d,3d-assets,footwear,shoes
        3d,3d-assets,footwear,socks
        3d,3d-assets,footwear,stockings
        3d,3d-assets,headwear,
        3d,3d-assets,headwear,hats
        3d,3d-assets,props,
        3d,3d-assets,props,companions
        3d,3d-assets,props,handheld
        3d,3d-assets,props,plushies
        3d,3d-assets,props,prefabs
        3d,3d-assets,props,weapons
        3d,3d-assets,unity,animations
        3d,3d-assets,unity,particle-systems
        3d,3d-assets,unity,shaders
        3d,vrchat,avatar-systems,
        3d,vrchat,followers,
        3d,vrchat,osc,
        3d,vrchat,setup-scripts,
        3d,vrchat,spring-joints,
        3d,vrchat,tools,
        3d,vrchat,world-constraints,
        3d,vrchat,worlds,
        3d,vrchat,worlds,assets
        3d,vrchat,worlds,midi
        3d,vrchat,worlds,quest
        3d,vrchat,worlds,tools
        3d,vrchat,worlds,udon
        3d,vrchat,worlds,udon-system
        3d,vrchat,worlds,udon2
        3d,vrchat,tutorials-guides,
        3d,textures,
        3d,textures,base,
        3d,textures,eyes,
        3d,textures,face,
        3d,textures,icons,
        3d,textures,matcap,
        3d,textures,pbr,
        3d,textures,tattoos,
      )
    end
end
