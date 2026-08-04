namespace :pens do
  desc "Delete pens archived longer ago than Pen::ARCHIVE_RETENTION"
  task purge: :environment do
    PenPurgeJob.perform_now
  end
end
