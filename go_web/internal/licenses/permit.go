package licenses

import (
	"context"
	"database/sql"
)

// LicenseKeyPermitted is Purchase#variant_content_permits_license_key? for purchase purchaseID
// of licensed product productID, whose links.flags are productFlags.
func LicenseKeyPermitted(ctx context.Context, conn *sql.DB, productID, productFlags, purchaseID int64) (bool, error) {
	link := &product{id: productID, flags: productFlags}
	if link.is(linkIsPhysical) {
		return true, nil
	}
	var hasAliveVariants bool
	if err := conn.QueryRowContext(ctx, "SELECT EXISTS ("+aliveVariantsOfLink+"?)", productID).Scan(&hasAliveVariants); err != nil || !hasAliveVariants {
		return true, err
	}
	s := &store{db: conn}
	variants, err := s.variantAttributes(ctx, purchaseID)
	if err != nil {
		return false, err
	}
	return s.variantContentPermitsLicenseKey(ctx, link, hasAliveVariants, variants)
}
