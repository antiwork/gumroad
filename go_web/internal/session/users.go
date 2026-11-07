package session

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/db"
)

// isTeamMemberFlag is User's has_flags 28 => :is_team_member.
const isTeamMemberFlag = 1 << 27

// disableThirdPartyAnalyticsFlag is User's has_flags 12 => :disable_third_party_analytics.
const disableThirdPartyAnalyticsFlag = 1 << 11

// User holds the users columns the ported before_actions read.
type User struct {
	ID                              int64
	Flags                           int64
	DeletedAt                       *time.Time
	UserRiskState                   string
	LastActiveSessionsInvalidatedAt *time.Time
	Username                        string
	// ExternalID is the users.external_id column, which User#external_id reads.
	ExternalID string
}

// IsTeamMember is a Gumroad admin, not a member of a seller's team.
func (u *User) IsTeamMember() bool { return u.Flags&isTeamMemberFlag != 0 }

func (u *User) DisableThirdPartyAnalytics() bool { return u.Flags&disableThirdPartyAnalyticsFlag != 0 }

func (u *User) Alive() bool { return u.DeletedAt == nil }

// Suspended is User::Risk#suspended?.
func (u *User) Suspended() bool { return SuspendedRiskState(u.UserRiskState) }

// SuspendedRiskState is whether a user_risk_state is one of User::Risk::SUSPENDED_STATES.
func SuspendedRiskState(state string) bool {
	return state == "suspended_for_tos_violation" || state == "suspended_for_fraud"
}

var userColumnNames = []string{"id", "flags", "deleted_at", "user_risk_state", "last_active_sessions_invalidated_at", "username", "external_id"}

// UserColumns lists the columns UserScan reads, qualified by a table alias, for a query
// that joins users.
func UserColumns(alias string) string {
	cols := make([]string, len(userColumnNames))
	for i, c := range userColumnNames {
		cols[i] = alias + "." + c
	}
	return strings.Join(cols, ", ")
}

// UserScan reads UserColumns from a row where the joined user may be missing.
type UserScan struct {
	id, flags   sql.NullInt64
	deletedAt   *time.Time
	riskState   sql.NullString
	invalidated *time.Time
	username    sql.NullString
	externalID  sql.NullString
}

func (s *UserScan) Targets() []any {
	return []any{&s.id, &s.flags, db.Time(&s.deletedAt), &s.riskState, db.Time(&s.invalidated), &s.username, &s.externalID}
}

// User is the scanned user, or nil when the join found none.
func (s *UserScan) User() *User {
	if !s.id.Valid {
		return nil
	}
	return &User{ID: s.id.Int64, Flags: s.flags.Int64, DeletedAt: s.deletedAt, UserRiskState: s.riskState.String,
		LastActiveSessionsInvalidatedAt: s.invalidated, Username: s.username.String, ExternalID: s.externalID.String}
}

// Users reads users and team_memberships from the primary.
type Users struct {
	DB *sql.DB
}

// Find is User.find_by(id:); alive restricts it to User.alive.
func (s *Users) Find(ctx context.Context, id int64, alive bool) (*User, error) {
	query := `SELECT ` + UserColumns("users") + ` FROM users WHERE id = ?`
	if alive {
		query += ` AND deleted_at IS NULL`
	}
	var scan UserScan
	err := s.DB.QueryRowContext(ctx, query+` LIMIT 1`, id).Scan(scan.Targets()...)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return scan.User(), err
}

// MemberOf is User#member_of?: the seller is the user, or a switchable (not deleted, seller
// alive) membership of any role links them.
func (s *Users) MemberOf(ctx context.Context, user, seller *User) (bool, error) {
	if user.ID == seller.ID {
		return true, nil
	}
	var one int
	err := s.DB.QueryRowContext(ctx, `SELECT 1 FROM team_memberships
		INNER JOIN users ON users.id = team_memberships.seller_id
		WHERE team_memberships.user_id = ? AND team_memberships.seller_id = ?
		AND team_memberships.deleted_at IS NULL AND users.deleted_at IS NULL LIMIT 1`, user.ID, seller.ID).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}
