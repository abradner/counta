# Walk-away-clean: deletes every server row tied to this device's push
# endpoint, no account needed. Stub tonight — push subscriptions and
# registrations aren't created yet, so there is nothing to delete
# (docs/data-privacy.md "First-run & device hygiene"; stated, not enforced —
# real deletion lands with the pen-registry push work).
class DeviceFlushesController < ApplicationController
  def create
    head :no_content
  end
end
