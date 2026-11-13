package downloads

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// purchaseProps is what download_page_layout_props' purchase hash reads beyond pageData.
type purchaseProps struct {
	// receiptID is receipt_purchase's id, and hasInvoice its has_invoice?.
	receiptID    int64
	hasInvoice   bool
	review       any
	membership   any
	customFields []any
	call         any
}

func (h *handler) loadPurchaseProps(ctx context.Context, p *page, d *pageData) (*purchaseProps, error) {
	pu, s := p.purchase, p.subscription
	if pu.subscriptionID != nil && s == nil {
		// true_original_purchase reads through the missing subscription and raises.
		return nil, fallback("missing subscription")
	}
	out := &purchaseProps{receiptID: pu.id, hasInvoice: !d.freePurchase(), customFields: []any{}}
	var err error
	if pu.flags&purchaseIsBundleProduct != 0 {
		if s != nil {
			// receipt_purchase reads the bundle purchase first, and its own membership after.
			return nil, fallback("bundle member membership")
		}
		if err = h.loadBundleReceipt(ctx, out, pu, d); err != nil {
			return nil, err
		}
	}
	if s != nil {
		if err = h.loadReceipt(ctx, out, pu, s, d); err != nil {
			return nil, err
		}
		if out.membership, err = h.membershipProps(ctx, s, p.Req.Now); err != nil {
			return nil, err
		}
	}
	// A membership's review is on its true original purchase.
	if s != nil || d.ownReview {
		if out.review, err = h.reviewProps(ctx, pu, s); err != nil {
			return nil, err
		}
	}
	if d.postPurchaseFields {
		if out.customFields, err = h.customFieldProps(ctx, pu.id); err != nil {
			return nil, err
		}
	}
	if d.call {
		if out.call, err = h.callProps(ctx, pu.id); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// loadReceipt is Purchase#receipt_purchase and its has_invoice? for a membership purchase: the
// subscription's last successful charge that isn't refunded or charged back, unless that's a
// gift or was bought under another email.
func (h *handler) loadReceipt(ctx context.Context, out *purchaseProps, pu *purchase, s *subscription, d *pageData) error {
	state := "successful"
	if s.flags&subscriptionIsTest != 0 {
		state = "test_successful"
	}
	var id, flags int64
	var email sql.NullString
	var price, shipping sql.NullInt64
	err := h.c.DB.QueryRowContext(ctx, `SELECT id, flags, email, price_cents, shipping_cents FROM purchases
		WHERE subscription_id = ? AND purchase_state = ? AND (stripe_refunded IS NULL OR stripe_refunded = 0)
		AND (chargeback_date IS NULL OR (chargeback_date IS NOT NULL AND flags & ? != 0))
		ORDER BY succeeded_at DESC LIMIT 1`, s.id, state, purchaseChargebackBack).Scan(&id, &flags, &email, &price, &shipping)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		id, flags, price, shipping = pu.id, pu.flags, d.priceCents, d.shippingCents
	case err != nil:
		return err
	case id == pu.id || flags&purchaseIsGiftSender != 0 || email != d.email:
		id, flags, price, shipping = pu.id, pu.flags, d.priceCents, d.shippingCents
	}
	out.receiptID = id
	// has_invoice? with a subscription: !is_free_trial_purchase? && !free_membership_purchase?.
	freeTrial := flags&purchaseIsFreeTrial != 0
	if !freeTrial && price.Valid && price.Int64 == 0 && shipping.Valid && shipping.Int64 == 0 {
		// free_membership_purchase? goes on to renews_free?, which prices the next charge.
		return fallback("free membership charge")
	}
	out.hasInvoice = !freeTrial
	return nil
}

// membershipProps is the purchase's membership hash.
func (h *handler) membershipProps(ctx context.Context, s *subscription, now time.Time) (any, error) {
	installmentPlan := s.flags&subscriptionInstallmentPlan != 0
	completed := false
	if installmentPlan && s.chargeOccurrenceCount != nil {
		// charges_completed?: successful_purchases.count == charge_occurrence_count.
		state := "successful"
		if s.flags&subscriptionIsTest != 0 {
			state = "test_successful"
		}
		var count int64
		if err := h.c.DB.QueryRowContext(ctx, "SELECT COUNT(*) FROM purchases WHERE subscription_id = ? AND purchase_state = ?",
			s.id, state).Scan(&count); err != nil {
			return nil, err
		}
		completed = count == *s.chargeOccurrenceCount
	}
	// alive?(include_pending_cancellation: false).
	active := s.failedAt == nil && s.endedAt == nil && s.cancelledAt == nil
	cancelledBySeller := !active && s.cancelledAt != nil && s.flags&subscriptionCancelledByBuyer == 0
	return rails.NewRHash().
		Sym("has_active_subscription", active).
		Sym("subscription_id", h.c.IDs.Encrypt(s.id)).
		Sym("is_subscription_ended", s.endedAt != nil).
		Sym("is_installment_plan_completed", completed).
		Sym("is_subscription_cancelled_or_failed", s.cancelledAt != nil || s.failedAt != nil).
		Sym("is_alive_or_restartable", s.endedAt == nil && !cancelledBySeller).
		Sym("in_free_trial", s.freeTrialEndsAt != nil && s.freeTrialEndsAt.After(now)).
		Sym("is_installment_plan", installmentPlan), nil
}

// reviewProps is ProductReviewPresenter#review_form_props for original_product_review: the
// review on true_original_purchase, which is the purchase itself without a subscription. A
// gift sender's review is the giftee's, but gift senders are left to Rails before this.
func (h *handler) reviewProps(ctx context.Context, pu *purchase, s *subscription) (any, error) {
	conn := h.c.DB
	purchaseID := pu.id
	if s != nil {
		err := conn.QueryRowContext(ctx, "SELECT id FROM purchases WHERE subscription_id = ? AND flags & ? != 0 ORDER BY id LIMIT 1",
			s.id, purchaseIsOriginalSubscription).Scan(&purchaseID)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		if err != nil {
			return nil, err
		}
	}
	var id int64
	var anonymous sql.NullBool
	var rating sql.NullInt64
	var message sql.NullString
	err := conn.QueryRowContext(ctx, "SELECT id, anonymous, rating, message FROM product_reviews WHERE purchase_id = ? LIMIT 1", purchaseID).
		Scan(&id, &anonymous, &rating, &message)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var video bool
	if err := conn.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM product_review_videos WHERE product_review_id = ?
		AND deleted_at IS NULL AND approval_status IN ('pending_review', 'approved'))`, id).Scan(&video); err != nil {
		return nil, err
	}
	if video {
		// The editable video's thumbnail URL is an Active Storage variant.
		return nil, fallback("review video")
	}
	return rails.NewRHash().
		Sym("anonymous", anonymous.Bool).
		Sym("rating", nullableInt(rating)).
		Sym("message", nullableString(message)).
		Sym("video", nil), nil
}

// customFieldNodeTypes is CustomField::FIELD_TYPE_TO_NODE_TYPE_MAPPING.
var customFieldNodeTypes = map[string]string{"text": "shortAnswer", "long_text": "longAnswer", "file": "fileUpload"}

const customFieldIsPostPurchase = 1 << 0 // PurchaseCustomField 1 => :is_post_purchase

// customFieldProps is purchase_custom_fields: the purchase's post-purchase fields with a
// custom field, each with its files or its value.
func (h *handler) customFieldProps(ctx context.Context, purchaseID int64) ([]any, error) {
	rows, err := h.c.DB.QueryContext(ctx, `SELECT id, field_type, value, custom_field_id FROM purchase_custom_fields
		WHERE purchase_id = ? AND flags & ? != 0 AND custom_field_id IS NOT NULL ORDER BY id`, purchaseID, customFieldIsPostPurchase)
	if err != nil {
		return nil, err
	}
	type field struct {
		id, customFieldID int64
		fieldType         string
		value             sql.NullString
	}
	var fields []field
	for rows.Next() {
		var f field
		if err := rows.Scan(&f.id, &f.fieldType, &f.value, &f.customFieldID); err != nil {
			rows.Close()
			return nil, err
		}
		fields = append(fields, f)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	out := []any{}
	for _, f := range fields {
		var nodeType any
		if t, ok := customFieldNodeTypes[f.fieldType]; ok {
			nodeType = t
		}
		data := rails.NewRHash().Sym("custom_field_id", h.c.IDs.Encrypt(f.customFieldID)).Sym("type", nodeType)
		switch f.fieldType {
		case "file":
			files, err := h.customFieldFiles(ctx, f.id)
			if err != nil {
				return nil, err
			}
			data.Sym("files", files)
		case "terms", "checkbox":
			// PurchaseCustomField#value casts CustomField::BOOLEAN_TYPES' strings.
			var v any
			if f.value.Valid {
				if b := rails.BooleanCast(f.value.String); b != nil {
					v = *b
				}
			}
			data.Sym("value", v)
		default:
			data.Sym("value", f.value.String)
		}
		out = append(out, data)
	}
	return out, nil
}

// customFieldFiles is a file field's Active Storage files, in the order the attachments'
// unique index lists them.
func (h *handler) customFieldFiles(ctx context.Context, fieldID int64) ([]any, error) {
	rows, err := h.c.DB.QueryContext(ctx, `SELECT active_storage_blobs.filename, active_storage_blobs.byte_size
		FROM active_storage_attachments JOIN active_storage_blobs ON active_storage_blobs.id = active_storage_attachments.blob_id
		WHERE active_storage_attachments.record_type = 'PurchaseCustomField' AND active_storage_attachments.record_id = ?
		AND active_storage_attachments.name = 'files' ORDER BY active_storage_attachments.blob_id`, fieldID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	files := []any{}
	for rows.Next() {
		var filename string
		var size int64
		if err := rows.Scan(&filename, &size); err != nil {
			return nil, err
		}
		name, ok := storageFilename(filename)
		if !ok {
			return nil, fallback("custom field file name")
		}
		ext := rails.FileExtname(name)
		files = append(files, rails.NewRHash().
			Sym("name", strings.TrimSuffix(name, ext)).
			Sym("size", size).
			Sym("extension", strings.ToUpper(strings.ReplaceAll(ext, ".", ""))))
	}
	return files, rows.Err()
}

// storageFilename is ActiveStorage::Filename#to_s, the sanitized name, for a name it reads the
// same as Ruby would: valid UTF-8 whose extension upcases in ASCII.
func storageFilename(raw string) (string, bool) {
	if !utf8.ValidString(raw) {
		return "", false
	}
	name := strings.Map(func(r rune) rune {
		if strings.ContainsRune("‮%$|:;/<>?*\"\t\r\n\\", r) {
			return '-'
		}
		return r
	}, rails.Strip(raw))
	for _, r := range rails.FileExtname(name) {
		if r >= utf8.RuneSelf {
			return "", false
		}
	}
	return name, true
}

// callProps is the purchase's call: has_one :call, without an order.
func (h *handler) callProps(ctx context.Context, purchaseID int64) (any, error) {
	var start, end *time.Time
	var url sql.NullString
	err := h.c.DB.QueryRowContext(ctx, "SELECT start_time, end_time, call_url FROM calls WHERE purchase_id = ? LIMIT 1", purchaseID).
		Scan(db.Time(&start), db.Time(&end), &url)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var startTime, endTime, callURL any
	if start != nil {
		startTime = *start
	}
	if end != nil {
		endTime = *end
	}
	if rails.Present(url.String) {
		callURL = url.String
	}
	return rails.NewRHash().Sym("start_time", startTime).Sym("end_time", endTime).Sym("url", callURL), nil
}
