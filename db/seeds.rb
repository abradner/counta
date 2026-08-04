# Product reference data, ported from assets/counta-prototype.html PRESETS.
# Idempotent — safe to run repeatedly in every environment.
# counter_style per docs/design-notes.md: Wegovy's window is binary (progress);
# insulin FlexTouch windows show real numbers (numeric).
# Click ratios say "verify per product" in the design notes — these are the
# prototype's working values.
[
  {
    id: "wegovy24", name: "Wegovy", strength: "2.4 mg", unit: "mg", decimals: 2,
    counter_style: "progress",
    capacity_label: "4 doses · 9.6 mg · 3 mL", capacity_units: 9.6, capacity_ml: 3, total_clicks: 296,
    max_dial_clicks: 74, common_doses: [ 0.25, 0.5, 1, 1.7, 2.4 ], default_freq_days: 7,
    theme: { "--c-body": "#F2F1EE", "--c-body-dark": "#D9D8D4", "--c-accent": "#7FD1C8",
             "--c-label": "#FFFFFF", "--c-text": "#123B6D", "--c-liquid": "#F2FAF9",
             "--c-button": "#C9C8C4", "--c-button-detail": "#8F8E8A" }
  },
  {
    id: "fiasp", name: "Fiasp", strength: "100 U/mL", unit: "U", decimals: 0,
    counter_style: "numeric",
    capacity_label: "3 mL · 300 U", capacity_units: 300, capacity_ml: 3, total_clicks: 300,
    max_dial_clicks: 80, common_doses: [ 2, 4, 6, 8, 10 ], default_freq_days: 1,
    theme: { "--c-body": "#E65300", "--c-body-dark": "#C24400", "--c-accent": "#F7C948",
             "--c-label": "#FFFDF5", "--c-text": "#1B3A6B", "--c-liquid": "#EAF4FB",
             "--c-button": "#E65300", "--c-button-detail": "#B03A12" }
  },
  {
    id: "novorapid", name: "NovoRapid", strength: "100 U/mL", unit: "U", decimals: 0,
    counter_style: "numeric",
    capacity_label: "3 mL · 300 U", capacity_units: 300, capacity_ml: 3, total_clicks: 300,
    max_dial_clicks: 80, common_doses: [ 2, 4, 6, 8, 10 ], default_freq_days: 1,
    theme: { "--c-body": "#E8E5DF", "--c-body-dark": "#C9C5BD", "--c-accent": "#F08A24",
             "--c-label": "#FFFFFF", "--c-text": "#1B3A6B", "--c-liquid": "#EAF4FB",
             "--c-button": "#F08A24", "--c-button-detail": "#B85F0D" }
  },
  {
    id: "tresiba", name: "Tresiba", strength: "200 U/mL", unit: "U", decimals: 0,
    counter_style: "numeric",
    capacity_label: "3 mL · 600 U", capacity_units: 600, capacity_ml: 3, total_clicks: 300,
    max_dial_clicks: 80, common_doses: [ 10, 20, 30, 40 ], default_freq_days: 1,
    theme: { "--c-body": "#2E5E4E", "--c-body-dark": "#204437", "--c-accent": "#9CD5C5",
             "--c-label": "#FBFFFD", "--c-text": "#123B2E", "--c-liquid": "#EAF4FB",
             "--c-button": "#2E5E4E", "--c-button-detail": "#16332A" }
  }
].each do |attrs|
  product = Product.find_or_initialize_by(id: attrs[:id])
  product.update!(attrs.except(:id))
end
