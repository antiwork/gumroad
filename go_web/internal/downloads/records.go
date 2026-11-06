package downloads

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/db"
	"github.com/antiwork/gumroad/go_web/internal/delivery"
)

// Flag bits from each model's has_flags.
const (
	urlRedirectHasBeenSeen = 1 << 0 // UrlRedirect 1 => :has_been_seen
	urlRedirectIsRental    = 1 << 2 // UrlRedirect 3 => :is_rental

	purchaseIsGiftReceiver         = 1 << 5  // Purchase 6 => :is_gift_receiver_purchase
	purchaseIsGiftSender           = 1 << 6  // Purchase 7 => :is_gift_sender_purchase
	purchaseChargebackBack         = 1 << 9  // Purchase 10 => :chargeback_reversed
	purchaseIsArchived             = 1 << 16 // Purchase 17 => :is_archived
	purchaseIsFreeTrial            = 1 << 18 // Purchase 19 => :is_free_trial_purchase
	purchaseExcludesProductReview  = 1 << 22 // Purchase 23 => :should_exclude_product_review
	purchaseAccessRevoked          = 1 << 24 // Purchase 25 => :is_access_revoked
	purchaseIsBundle               = 1 << 25 // Purchase 26 => :is_bundle_purchase
	purchaseIsBundleProduct        = 1 << 26 // Purchase 27 => :is_bundle_product_purchase
	purchaseIsCommissionDeposit    = 1 << 28 // Purchase 29 => :is_commission_deposit_purchase
	purchaseIsCommissionCompletion = 1 << 29 // Purchase 30 => :is_commission_completion_purchase

	subscriptionInstallmentPlan = 1 << 6 // Subscription 7 => :is_installment_plan

	productIsLicensed                   = 1 << 6  // Link 7 => :is_licensed
	productBlockAccessAfterCancellation = 1 << 9  // Link 10 => :block_access_after_membership_cancellation
	productCommunityChatEnabled         = 1 << 29 // Link 30 => :community_chat_enabled

	userDisablesReviewsAfterYear = 1 << 5 // User 6 => :disable_reviews_after_year

	coffeeNativeType = "coffee"
)

// urlRedirect is the url_redirects row a token names.
type urlRedirect struct {
	id                                                       int64
	token                                                    string
	purchaseID, productID, installmentID, importedCustomerID *int64
	flags                                                    int64
}

func (u *urlRedirect) hasBeenSeen() bool { return u.flags&urlRedirectHasBeenSeen != 0 }

func (u *urlRedirect) delivery() *delivery.Redirect {
	return &delivery.Redirect{ID: u.id, PurchaseID: u.purchaseID, ProductID: u.productID, InstallmentID: u.installmentID, ImportedCustomerID: u.importedCustomerID}
}

// findURLRedirect is UrlRedirect.find_by(token:), under the column's case-insensitive collation.
func findURLRedirect(ctx context.Context, conn *sql.DB, token string) (*urlRedirect, error) {
	u := &urlRedirect{}
	err := conn.QueryRowContext(ctx, `SELECT id, token, purchase_id, link_id, installment_id, imported_customer_id, flags
		FROM url_redirects WHERE token = ? LIMIT 1`, token).
		Scan(&u.id, &u.token, &u.purchaseID, &u.productID, &u.installmentID, &u.importedCustomerID, &u.flags)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return u, nil
}

// purchase is the purchases columns check_permissions reads, with the purchaser and the
// product's seller as the associations load them: nil when the row is missing.
type purchase struct {
	id int64
	// productMissing is purchase.link being nil, which only raises where Rails reads it.
	productMissing    bool
	purchaserID       *int64 // the purchaser row, when it exists
	sellerID          *int64 // link.user, when it exists
	subscriptionID    *int64
	ipAddress         *string
	stripeRefunded    bool
	chargebackDate    *time.Time
	rentalExpired     bool
	flags             int64
	productNativeType *string
}

func (p *purchase) refundedOrChargedBack() bool {
	return p.stripeRefunded || (p.chargebackDate != nil && p.flags&purchaseChargebackBack == 0)
}

func (p *purchase) accessRevoked() bool       { return p.flags&purchaseAccessRevoked != 0 }
func (p *purchase) bundle() bool              { return p.flags&purchaseIsBundle != 0 }
func (p *purchase) giftReceiver() bool        { return p.flags&purchaseIsGiftReceiver != 0 }
func (p *purchase) purchaserIs(id int64) bool { return p.purchaserID != nil && *p.purchaserID == id }

var errNoProduct = errors.New("purchase has no product")

// testPurchase is Purchase#is_test_purchase?: link.user == purchaser, which also holds when
// both are missing. With no link Rails raises.
func (p *purchase) testPurchase() (bool, error) {
	if p.productMissing {
		return false, errNoProduct
	}
	if p.purchaserID == nil || p.sellerID == nil {
		return p.purchaserID == nil && p.sellerID == nil, nil
	}
	return *p.purchaserID == *p.sellerID, nil
}

// findPurchase is url_redirect.purchase.
func findPurchase(ctx context.Context, conn *sql.DB, id int64) (*purchase, error) {
	p := &purchase{}
	var refunded, rentalExpired sql.NullBool
	var productID sql.NullInt64
	err := conn.QueryRowContext(ctx, `SELECT purchases.id, purchaser.id, seller.id, purchases.subscription_id,
		purchases.ip_address, purchases.stripe_refunded, purchases.chargeback_date, purchases.rental_expired, purchases.flags,
		links.id, links.native_type
		FROM purchases
		LEFT JOIN users purchaser ON purchaser.id = purchases.purchaser_id
		LEFT JOIN links ON links.id = purchases.link_id
		LEFT JOIN users seller ON seller.id = links.user_id
		WHERE purchases.id = ? LIMIT 1`, id).
		Scan(&p.id, &p.purchaserID, &p.sellerID, &p.subscriptionID, &p.ipAddress, &refunded, db.Time(&p.chargebackDate),
			&rentalExpired, &p.flags, &productID, &p.productNativeType)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	p.productMissing = !productID.Valid
	p.stripeRefunded, p.rentalExpired = refunded.Bool, rentalExpired.Bool
	return p, nil
}

// subscription is purchase.subscription with the subscriber and the product's access flag.
type subscription struct {
	userID                         *int64 // the user row, when it exists
	flags                          int64
	cancelledAt, failedAt, endedAt *time.Time
	productMissing                 bool
	blockAccessAfterCancellation   bool
}

func findSubscription(ctx context.Context, conn *sql.DB, id int64) (*subscription, error) {
	s := &subscription{}
	var productFlags sql.NullInt64
	err := conn.QueryRowContext(ctx, `SELECT users.id, subscriptions.flags, subscriptions.cancelled_at, subscriptions.failed_at,
		subscriptions.ended_at, links.flags
		FROM subscriptions
		LEFT JOIN users ON users.id = subscriptions.user_id
		LEFT JOIN links ON links.id = subscriptions.link_id
		WHERE subscriptions.id = ? LIMIT 1`, id).
		Scan(&s.userID, &s.flags, db.Time(&s.cancelledAt), db.Time(&s.failedAt), db.Time(&s.endedAt), &productFlags)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	s.productMissing = !productFlags.Valid
	s.blockAccessAfterCancellation = productFlags.Int64&productBlockAccessAfterCancellation != 0
	return s, nil
}

// grantAccessToProduct is Subscription#grant_access_to_product?, which reads the link only
// for a subscription that isn't alive, and raises there when it is missing.
func (s *subscription) grantAccessToProduct(now time.Time) (bool, error) {
	if s.flags&subscriptionInstallmentPlan != 0 {
		return s.cancelledAt == nil && s.failedAt == nil, nil
	}
	if s.failedAt == nil && s.endedAt == nil && (s.cancelledAt == nil || s.cancelledAt.After(now)) {
		return true, nil
	}
	if s.productMissing {
		return false, errors.New("subscription has no product")
	}
	return !s.blockAccessAfterCancellation, nil
}

// importedCustomer is url_redirect.imported_customer: whether the row exists, and its
// product's native_type.
func importedCustomer(ctx context.Context, conn *sql.DB, u *urlRedirect) (present bool, nativeType *string, err error) {
	if u.importedCustomerID == nil {
		return false, nil, nil
	}
	err = conn.QueryRowContext(ctx, `SELECT links.native_type FROM imported_customers
		LEFT JOIN links ON links.id = imported_customers.link_id WHERE imported_customers.id = ? LIMIT 1`, *u.importedCustomerID).Scan(&nativeType)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil, nil
	}
	return err == nil, nativeType, err
}

// referencedProductNativeType is url_redirect.referenced_link&.native_type for a redirect with
// no purchase and no installment: the imported customer's product when there is an imported
// customer, else the redirect's own.
func referencedProductNativeType(ctx context.Context, conn *sql.DB, u *urlRedirect, importedPresent bool, importedType *string) (*string, error) {
	if importedPresent {
		return importedType, nil
	}
	if u.productID == nil {
		return nil, nil
	}
	var nativeType *string
	err := conn.QueryRowContext(ctx, `SELECT native_type FROM links WHERE id = ? LIMIT 1`, *u.productID).Scan(&nativeType)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return nativeType, err
}
