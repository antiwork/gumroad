package downloads

import (
	"context"
	"database/sql"
	"slices"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/delivery"
	"github.com/antiwork/gumroad/go_web/internal/sidekiq"
)

// transcodeVideoJob and stampPDFJob are TranscodeVideoForStreamingWorker's and
// StampPdfForPurchaseJob's sidekiq_options. The stamp job's lock_args is args.first, which is
// all of the one-arg push the download page makes.
var (
	transcodeVideoJob = sidekiq.Options{Class: "TranscodeVideoForStreamingWorker", Queue: "default", Retry: 13}
	stampPDFJob       = sidekiq.Options{Class: "StampPdfForPurchaseJob", Queue: "long", Retry: 5, UniqueAcrossQueues: true}
)

const (
	// UrlRedirect's transcoded video methods read the ids each_slice(1_000).
	transcodeSlice = 1000
	// enqueue_job_to_regenerate_deleted_transcoded_videos spaces the jobs 5.minutes apart.
	transcodeSpacing = 5 * time.Minute
)

// lifecycle is what trigger_files_lifecycle_events writes, decided before anything is.
type lifecycle struct {
	// videos get last_accessed_at, and transcodes are the files whose transcodes are
	// regenerated, in enqueue order.
	videos, transcodes []int64
	// stampPurchase is the purchase_id whose deleted stamped PDFs are stamped again.
	stampPurchase *int64
}

// planLifecycle reads what trigger_files_lifecycle_events would write for the page's files.
func (h *handler) planLifecycle(ctx context.Context, content *delivery.Page, u *urlRedirect) (*lifecycle, error) {
	videos, stampable, err := content.LifecycleFiles()
	if err != nil {
		return nil, err
	}
	lc := &lifecycle{videos: videos}
	if lc.transcodes, err = h.deletedTranscodes(ctx, videos); err != nil {
		return nil, err
	}
	// enqueue_job_to_regenerate_deleted_stamped_pdfs returns without a purchase.
	if len(stampable) > 0 && u.purchaseID != nil {
		regenerate, err := h.stampedPDFsDeleted(ctx, u.id, stampable)
		if err != nil {
			return nil, err
		}
		if regenerate {
			lc.stampPurchase = u.purchaseID
		}
	}
	if (len(lc.transcodes) > 0 || lc.stampPurchase != nil) && h.c.Pages.Sidekiq == nil {
		return nil, fallback("jobs")
	}
	return lc, nil
}

// deletedTranscodes is the files enqueue_job_to_regenerate_deleted_transcoded_videos enqueues.
func (h *handler) deletedTranscodes(ctx context.Context, videos []int64) ([]int64, error) {
	if len(videos) == 0 {
		return nil, nil
	}
	alive := map[int64]bool{}
	for chunk := range slices.Chunk(videos, transcodeSlice) {
		ids, err := h.int64s(ctx, "SELECT streamable_id FROM transcoded_videos WHERE deleted_at IS NULL"+
			" AND streamable_type = 'ProductFile' AND streamable_id IN ("+placeholders(len(chunk))+")", int64Args(chunk)...)
		if err != nil {
			return nil, err
		}
		for _, id := range ids {
			alive[id] = true
		}
	}
	var missing []int64
	for _, id := range videos {
		if !alive[id] && !slices.Contains(missing, id) {
			missing = append(missing, id)
		}
	}
	if len(missing) == 0 {
		return nil, nil
	}
	return h.transcodableWithDeletedTranscodes(ctx, missing)
}

// stampedPDFsDeleted is whether enqueue_job_to_regenerate_deleted_stamped_pdfs would enqueue:
// a stampable file whose only stamped PDFs for this url redirect were deleted.
func (h *handler) stampedPDFsDeleted(ctx context.Context, redirectID int64, stampable []int64) (bool, error) {
	alive, err := delivery.StampedFileIDs(ctx, h.c.DB, redirectID, false)
	if err != nil {
		return false, err
	}
	var deleted map[int64]bool
	for _, id := range stampable {
		if alive[id] {
			continue
		}
		if deleted == nil {
			if deleted, err = delivery.StampedFileIDs(ctx, h.c.DB, redirectID, true); err != nil {
				return false, err
			}
		}
		if deleted[id] {
			return true, nil
		}
	}
	return false, nil
}

// transcodableWithDeletedTranscodes is ProductFile.where(id: missing).joins(:transcoded_videos)
// .merge(TranscodedVideo.deleted.completed).distinct.select(&:transcodable?), in the order
// MySQL returns that statement's rows, which sets each job's delay.
func (h *handler) transcodableWithDeletedTranscodes(ctx context.Context, missing []int64) ([]int64, error) {
	rows, err := h.c.DB.QueryContext(ctx, "SELECT DISTINCT `product_files`.* FROM `product_files` INNER JOIN `transcoded_videos`"+
		" ON `transcoded_videos`.`streamable_type` = 'ProductFile' AND `transcoded_videos`.`streamable_id` = `product_files`.`id`"+
		" WHERE `product_files`.`id` IN ("+placeholders(len(missing))+") AND `transcoded_videos`.`deleted_at` IS NOT NULL"+
		" AND `transcoded_videos`.`state` = 'completed'", int64Args(missing)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	columns, err := rows.Columns()
	if err != nil {
		return nil, err
	}
	var ids []int64
	for rows.Next() {
		var id int64
		var filegroup sql.NullString
		var width, height sql.NullInt64
		fields := map[string]any{"id": &id, "filegroup": &filegroup, "width": &width, "height": &height}
		dest := make([]any, len(columns))
		for i, c := range columns {
			if dest[i] = fields[c]; dest[i] == nil {
				dest[i] = new(sql.RawBytes)
			}
		}
		if err := rows.Scan(dest...); err != nil {
			return nil, err
		}
		// transcodable?: streamable? && height.present? && width.present?
		if filegroup.String == "video" && filegroup.Valid && width.Valid && height.Valid {
			ids = append(ids, id)
		}
	}
	return ids, rows.Err()
}

// runLifecycle is trigger_files_lifecycle_events' writes: last_accessed_at on the videos' alive
// transcodes, a transcode job for each file whose transcodes were deleted, then the stamp job.
func (h *handler) runLifecycle(ctx context.Context, lc *lifecycle) error {
	if len(lc.videos) > 0 {
		// update_all quotes Time.current at the column's microsecond precision.
		now := h.c.Now().UTC().Truncate(time.Microsecond)
		for chunk := range slices.Chunk(lc.videos, transcodeSlice) {
			if _, err := h.c.DB.ExecContext(ctx, "UPDATE transcoded_videos SET last_accessed_at = ? WHERE deleted_at IS NULL"+
				" AND streamable_type = 'ProductFile' AND streamable_id IN ("+placeholders(len(chunk))+")",
				append([]any{now}, int64Args(chunk)...)...); err != nil {
				return err
			}
		}
	}
	for i, id := range lc.transcodes {
		if _, err := h.c.Pages.Sidekiq.PushIn(ctx, transcodeVideoJob, time.Duration(i)*transcodeSpacing, id, "ProductFile"); err != nil {
			return err
		}
	}
	if lc.stampPurchase != nil {
		// A job already holding the lock means the stamp is on its way, as it does for Rails.
		if _, _, err := h.c.Pages.Sidekiq.PushUntilExecuted(ctx, stampPDFJob, *lc.stampPurchase); err != nil {
			return err
		}
	}
	return nil
}

func (h *handler) int64s(ctx context.Context, query string, args ...any) ([]int64, error) {
	rows, err := h.c.DB.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id sql.NullInt64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		if id.Valid {
			out = append(out, id.Int64)
		}
	}
	return out, rows.Err()
}

func placeholders(n int) string { return strings.TrimSuffix(strings.Repeat("?, ", n), ", ") }

func int64Args(ids []int64) []any {
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	return args
}
