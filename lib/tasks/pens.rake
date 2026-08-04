namespace :pens do
  desc "Delete pen rows whose client-set retention TTL (purge_after) has passed"
  task purge: :environment do
    PenPurgeJob.perform_now
  end
end
