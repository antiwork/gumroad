package products

import (
	"context"
	"database/sql"
	"regexp"

	"github.com/antiwork/gumroad/go_web/internal/description"
	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// productMeta is the meta tags in the order the before_actions and the action set them:
// ApplicationController's, then prepare_product_page's, then set_favicon_meta_tags.
func (h *handler) productMeta(p *page, prod *product, v *view) (*inertia.MetaTags, error) {
	pc, seller := h.c.Page, p.seller
	meta := h.ctl.MetaTags(p.Visit)
	set := func(tagName, headKey, typ string, attrs ...inertia.Attr) {
		meta.Set(inertia.NewMetaTag(tagName, headKey, typ, attrs...))
	}

	// set_analytics_meta_tags with the product's seller.
	enabled := "false"
	if h.analyticsEnabled(seller) {
		enabled = "true"
	}
	for _, property := range []string{"gr:google_analytics:enabled", "gr:fb_pixel:enabled", "gr:tiktok_pixel:enabled"} {
		set("", "", "", inertia.Pairs("property", property, "content", enabled)...)
	}
	var viewerID string
	if p.viewer != nil {
		viewerID = p.viewer.externalID.String
	}
	set("", "", "", inertia.Pairs("property", "gr:logged_in_user:id", "content", viewerID)...)
	set("", "", "", inertia.Pairs("property", "gr:page:type", "content", "")...)
	set("", "", "", inertia.Pairs("title", prod.name)...)

	// set_product_page_meta.
	productDescription := "Available on Gumroad"
	if v.descriptionPresent {
		productDescription = v.plaintextDescription
	}
	productDescription = description.Snippet(productDescription)
	canonical := h.canonicalURL(p, prod)
	set("", "", "", inertia.Pairs("name", "description", "content", productDescription)...)
	set("", "", "", inertia.Pairs("property", "gr:page:type", "content", "product")...)
	set("", "", "", inertia.Pairs("property", "product:retailer_item_id", "content", prod.uniquePermalink.String)...)
	if v.priceCents != nil && rails.Present(prod.priceCurrencyType.String) {
		amount := rails.RoundFloat(float64(*v.priceCents)/float64(unitScalingFactor(prod.priceCurrencyType.String)), 2)
		content, ok := numberAttr(amount)
		if !ok {
			return nil, fallback("price amount")
		}
		set("", "", "", inertia.Attr{Key: "property", Value: "product:price:amount"}, content)
		up, ok := asciiUpcase(prod.priceCurrencyType.String)
		if !ok {
			return nil, fallback("currency")
		}
		set("", "", "", inertia.Pairs("property", "product:price:currency", "content", up)...)
	}

	shareImage, err := socialShareImage(v)
	if err != nil {
		return nil, err
	}
	var main *cover
	if len(v.covers) > 0 {
		main = v.covers[0]
	}
	set("", "", "", inertia.Pairs("property", "og:title", "content", prod.name)...)
	set("", "", "", inertia.Pairs("property", "og:description", "content", productDescription)...)
	set("", "", "", inertia.Pairs("property", "og:url", "content", canonical)...)
	if rails.Present(shareImage) {
		set("", "", "", inertia.Pairs("property", "og:image", "content", shareImage)...)
		set("", "", "", inertia.Pairs("property", "og:image:alt", "content", "")...)
	}
	set("", "", "", inertia.Pairs("property", "og:type", "content", pc.OGNamespace+":product")...)

	set("", "", "", inertia.Pairs("property", "twitter:title", "content", prod.name)...)
	var demo string
	if rails.Present(shareImage) {
		if demo, err = h.demoPlayerURL(p, prod, v); err != nil {
			return nil, err
		}
	}
	switch {
	case demo != "":
		width, _ := numberAttr(int64(demoPlayerWidth))
		height, _ := numberAttr(int64(demoPlayerHeight))
		set("", "", "", inertia.Pairs("property", "twitter:card", "content", "player")...)
		set("", "", "", inertia.Pairs("property", "twitter:image", "content", shareImage)...)
		set("", "", "", inertia.Pairs("property", "twitter:player", "content", demo)...)
		set("", "", "", inertia.Attr{Key: "property", Value: "twitter:player:width"}, width)
		set("", "", "", inertia.Attr{Key: "property", Value: "twitter:player:height"}, height)
	case main != nil && main.previewImagePath():
		set("", "", "", inertia.Pairs("property", "twitter:card", "content", "summary_large_image")...)
		set("", "", "", inertia.Pairs("property", "twitter:image", "content", main.url)...)
		set("", "", "", inertia.Pairs("property", "twitter:image:alt", "content", "")...)
	case main != nil && main.oembed != nil:
		width, _ := numberAttr(main.width.toI())
		height, _ := numberAttr(main.height.toI())
		set("", "", "", inertia.Pairs("property", "twitter:card", "content", "player")...)
		// A nil thumbnail's tag has no content, which Rails' tag helper and compact_blank! both drop.
		image := inertia.Pairs("property", "twitter:image")
		if main.thumbnail != "" {
			image = inertia.Pairs("property", "twitter:image", "content", main.thumbnail)
		}
		set("", "", "", image...)
		set("", "", "", inertia.Pairs("property", "twitter:player", "content", main.url)...)
		set("", "", "", inertia.Attr{Key: "property", Value: "twitter:player:width"}, width)
		set("", "", "", inertia.Attr{Key: "property", Value: "twitter:player:height"}, height)
	case main != nil && main.isVideo:
		// A nil display size's tag has no content, as for the oembed thumbnail above.
		width := []inertia.Attr{{Key: "property", Value: "twitter:player:width"}}
		if dw, ok := main.displayWidth(); ok {
			attr, ok := numberAttr(dw.value())
			if !ok {
				return nil, fallback("video cover size")
			}
			width = append(width, attr)
		}
		height := []inertia.Attr{{Key: "property", Value: "twitter:player:height"}}
		if dh, ok := main.displayHeight(); ok {
			attr, _ := numberAttr(dh)
			height = append(height, attr)
		}
		set("", "", "", inertia.Pairs("property", "twitter:card", "content", "player")...)
		set("", "", "", inertia.Pairs("property", "twitter:image", "content", "https://gumroad.com/assets/icon.png")...)
		set("", "", "", inertia.Pairs("property", "twitter:player", "content", main.url)...)
		set("", "", "", width...)
		set("", "", "", height...)
	default:
		set("", "", "", inertia.Pairs("property", "twitter:card", "content", "summary")...)
	}
	set("", "", "", inertia.Pairs("property", "twitter:domain", "content", "Gumroad")...)
	set("", "", "", inertia.Pairs("property", "twitter:description", "content", description.TwitterDescription(productDescription))...)
	if rails.Present(seller.twitterHandle.String) {
		set("", "", "", inertia.Pairs("property", "twitter:creator", "content", "@"+seller.twitterHandle.String)...)
	}
	for _, c := range v.covers {
		if c.isImage {
			set("link", "", "", inertia.Pairs("rel", "preload", "as", "image", "href", c.url)...)
		}
	}
	if prod.nativeType == "call" {
		set("link", "call-calendar", "", inertia.Pairs("rel", "modulepreload", "crossorigin", "anonymous", "href", h.c.Page.CalendarHref)...)
	}
	set("link", "canonical", "", inertia.Pairs("rel", "canonical", "href", canonical)...)

	data, err := h.structuredData(p, prod, v, canonical, shareImage)
	if err != nil {
		return nil, err
	}
	set("script", "structured-data", "application/ld+json", inertia.Attr{Key: "inner_content", JSON: data})

	set("style", "custom_styles", "", inertia.Attr{Key: "inner_content", Value: v.customStyles, Raw: true})
	if v.fontPreload {
		set("link", "default_font_preload", "font/woff2", inertia.Pairs("rel", "preload",
			"href", h.c.Env.AssetHost()+"/fonts/ABCFavorit-Regular.woff2", "as", "font", "crossorigin", "anonymous")...)
	}

	// set_favicon_meta_tags: avatar_url is always present.
	set("link", "shortcut-icon", "", inertia.Pairs("rel", "shortcut icon", "href", v.avatarURL)...)
	set("link", "apple-touch-icon", "", inertia.Pairs("rel", "apple-touch-icon", "href", v.avatarURL)...)
	return meta, nil
}

// analyticsEnabled is analytics_enabled?(seller:) on a page that hasn't disabled them.
func (h *handler) analyticsEnabled(seller *user) bool {
	return h.c.Meta.AnalyticsByEnvironment && !seller.is(userDisableThirdPartyAnalytics)
}

// socialShareImage is social_share_image: an image cover's URL, else a player's escaped
// thumbnail or a video's poster; "" is nil.
func socialShareImage(v *view) (string, error) {
	if len(v.covers) == 0 {
		return "", nil
	}
	main := v.covers[0]
	switch {
	case main.previewImagePath():
		return main.url, nil
	case main.oembed != nil && main.thumbnail != "" && !addressableUnchanged.MatchString(main.thumbnail):
		return "", fallback("oembed thumbnail escape")
	}
	return main.thumbnail, nil
}

// structuredData is Link#structured_data at url, the canonical URL.
func (h *handler) structuredData(p *page, prod *product, v *view, url, image string) (*rails.Hash, error) {
	seller := p.seller
	d := rails.NewHash()
	d.Set("@context", "https://schema.org")
	ebook := prod.nativeType == "ebook"
	if ebook {
		d.Set("@type", "Book")
	} else {
		d.Set("@type", "Product")
	}
	d.Set("name", prod.name)
	if ebook {
		author := rails.NewHash()
		author.Set("@type", "Person")
		author.Set("name", nullString(seller.name))
		d.Set("author", author)
	}
	if v.structuredDescription != nil {
		d.Set("description", *v.structuredDescription)
	}
	d.Set("url", url)
	if rails.Present(image) {
		d.Set("image", image)
	}
	d.Set("sku", prod.uniquePermalink.String)
	if !ebook && rails.Present(seller.name.String) {
		brand := rails.NewHash()
		brand.Set("@type", "Brand")
		brand.Set("name", seller.name.String)
		d.Set("brand", brand)
	}
	if ebook {
		var examples []any
		for _, f := range v.files {
			switch f.filetype.String {
			case "epub", "pdf", "mobi":
			default:
				continue
			}
			up, _ := asciiUpcase(f.filetype.String)
			e := rails.NewHash()
			e.Set("@type", "Book")
			e.Set("bookFormat", "EBook")
			e.Set("name", prod.name+" ("+up+")")
			if rails.Present(f.isbn.String) {
				e.Set("isbn", f.isbn.String)
			}
			examples = append(examples, e)
		}
		if len(examples) > 0 {
			d.Set("workExample", examples)
		}
	}
	offer, err := h.offerData(p, prod, v, url)
	if err != nil {
		return nil, err
	}
	d.Set("offers", offer)
	if prod.is(productDisplayReviews) && v.reviewStat != nil && v.reviewStat.reviewsCount > 0 {
		r := rails.NewHash()
		r.Set("@type", "AggregateRating")
		r.Set("ratingValue", rails.RoundFloat(v.reviewStat.averageRating, 1))
		r.Set("reviewCount", v.reviewStat.reviewsCount)
		r.Set("bestRating", int64(5))
		r.Set("worstRating", int64(1))
		d.Set("aggregateRating", r)
	}
	return d, nil
}

// lowestVariantDifference is lowest_variant_price_difference_cents, over every alive category.
func (h *handler) lowestVariantDifference(ctx context.Context, prod *product, vs *variants) (sql.NullInt64, error) {
	var diff sql.NullInt64
	in, args := "NULL", []any{prod.id}
	if cats := vs.categories; len(cats) > 0 {
		in, args = placeholders(len(cats)), append(args, int64Args(cats)...)
	}
	err := h.c.DB.QueryRowContext(ctx, "SELECT MIN(`base_variants`.`price_difference_cents`) FROM `base_variants`"+
		" WHERE `base_variants`.`deleted_at` IS NULL AND (link_id = ? OR variant_category_id IN ("+in+"))", args...).Scan(&diff)
	return diff, err
}

// offerData is build_offer_data: the offer in USD, through the cached rate when the product's
// currency isn't, else in that currency.
func (h *handler) offerData(p *page, prod *product, v *view, url string) (*rails.Hash, error) {
	// lowest_base_price_cents: a tiered membership's lowest tier price, without a variant
	// difference; else the lowest of the buy and rental prices the product offers and, for a
	// legacy subscription, of every alive buy price.
	var cents *int64
	if prod.is(productIsTieredMembership) {
		c := lowestTierPriceCents(offeredTiers(v.variants.tiers), nil)
		cents = &c
	} else {
		cents = lowerOf(v.prices.buy, v.prices.rental)
		if prod.is(productIsRecurringBilling) {
			for i, r := range v.prices.rows {
				if !r.isRental() {
					cents = lowerOf(cents, &v.prices.rows[i].cents)
				}
			}
		}
	}
	if !prod.is(productIsTieredMembership) && cents != nil {
		diff, err := h.lowestVariantDifference(p.Ctx, prod, v.variants)
		if err != nil {
			return nil, err
		}
		c := *cents + diff.Int64
		cents = &c
	}
	currency := "USD"
	if code := prod.priceCurrencyType.String; code != "usd" {
		usd, ok, err := h.usdOfferCents(p, code, cents)
		if err != nil {
			return nil, err
		}
		if ok {
			cents = &usd
		} else if currency, ok = asciiUpcase(code); !ok || rails.Blank(currency) {
			// Rails drops a blank currency, and the price with it.
			return nil, fallback("offer currency")
		}
	}
	offer := rails.NewHash()
	offer.Set("@type", "Offer")
	offer.Set("priceCurrency", currency)
	availability := "https://schema.org/InStock"
	if v.variants.closedToNewBuyers(prod) {
		availability = "https://schema.org/SoldOut"
	} else if prod.maxPurchaseCount.Valid && prod.maxPurchaseCount.Int64 != 0 {
		availability = "https://schema.org/LimitedAvailability"
		if n, ok := v.quantityRemaining.(int64); ok && n == 0 {
			availability = "https://schema.org/SoldOut"
		}
	}
	offer.Set("availability", availability)
	offer.Set("url", url)
	if cents != nil {
		offer.Set("price", float64(*cents)/float64(unitScalingFactor(currency)))
	}
	return offer, nil
}

// usdOfferCents is usd_offer_price_cents for a non-USD product: ok is false when Rails
// finds no usable rate in $redis (currencies:<CODE>) and shows the product's own currency.
func (h *handler) usdOfferCents(p *page, code string, cents *int64) (int64, bool, error) {
	if cents == nil {
		return 0, false, nil
	}
	raw, found, err := h.currencyRate(p, code)
	if err != nil || !found {
		return 0, false, err
	}
	rate, exact := rails.StringToF(raw)
	if !exact {
		return 0, false, fallback("currency rate")
	}
	if rate <= 0 {
		return 0, false, nil
	}
	usd, ok := usdCents(*cents, rate, currencyFor(code).singleUnit)
	if !ok {
		return 0, false, fallback("usd offer price")
	}
	return usd, true, nil
}

// numberAttr is a content attribute holding a Ruby number: to_s in the tag, as the tag helper
// writes it, and the number in the page's meta.
func numberAttr(n any) (inertia.Attr, bool) {
	s, ok := rails.String(n)
	return inertia.Attr{Key: "content", Value: s, JSON: n}, ok
}

// addressableUnchanged is a URL Addressable::URI.escape returns as it is.
var addressableUnchanged = regexp.MustCompile(`\Ahttps?://[a-z0-9.-]+(?:/[A-Za-z0-9\-._~/]*)?(?:\?[A-Za-z0-9\-._~=&]*)?\z`)
