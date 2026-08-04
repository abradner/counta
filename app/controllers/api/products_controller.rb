module Api
  # Public reference data (no auth): powers the setup presets.
  class ProductsController < ApplicationController
    def index
      render json: Product.order(:name).map { |p|
        {
          id: p.id, name: p.name, strength: p.strength, unit: p.unit,
          decimals: p.decimals, counter_style: p.counter_style,
          capacity_label: p.capacity_label,
          capacity_units: p.capacity_units&.to_f, capacity_ml: p.capacity_ml&.to_f,
          total_clicks: p.total_clicks, max_dial_clicks: p.max_dial_clicks,
          common_doses: p.common_doses, default_freq_days: p.default_freq_days&.to_f,
          theme: p.theme
        }
      }
    end
  end
end
