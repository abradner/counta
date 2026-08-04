# Public reference data (preset dropdowns + future recall matching).
class Product < ApplicationRecord
  COUNTER_STYLES = %w[numeric progress].freeze

  has_many :pen_registrations

  validates :counter_style, inclusion: { in: COUNTER_STYLES }
end
